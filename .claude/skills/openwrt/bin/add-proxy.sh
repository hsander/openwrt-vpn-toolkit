#!/usr/bin/env bash
# bin/add-proxy.sh — add a mixed inbound (LAN HTTP/SOCKS5 proxy) bound to an
# existing outbound tag.
#
# Mutates /etc/sing-box/config.json on the router:
#   * appends a "mixed" inbound on <listen>:<port> tagged "in-proxy-<port>"
#   * appends a route rule that maps that inbound to the chosen outbound
#     (placed BEFORE any auto-failover catch-all)
#
# Snapshot-before, sing-box check, atomic write, restart with reachability
# watch + auto-rollback.
#
# Usage:
#   bin/add-proxy.sh --router <alias> --port <port> --outbound <tag>
#                    [--listen 192.168.1.1] [--no-backup]
#
# Exit codes:
#   0   ok
#   2   router not found / SSH unreachable / config.json absent
#  13   validation (bad port / outbound missing / port taken)
#  20   rollback fired
#  64   bad CLI args

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/add-proxy.sh --router <alias> --port <port> --outbound <tag> [--listen <ip>] [--no-backup]

Добавляет mixed-inbound (HTTP/SOCKS5) на роутере, привязанный к outbound.

Options:
  --router <alias>     alias из memory/routers.yaml (обяз.)
  --port <port>        порт 4000-4099 (обяз.)
  --outbound <tag>     tag существующего outbound'а (обяз.). Должен быть в config.json.
  --listen <ip>        адрес для прослушки (по умолчанию 192.168.1.1)
  --no-backup          (только для тестов) пропустить pre-backup.
EOF
  exit 64
}

router=""
port=""
outbound=""
listen="192.168.1.1"
no_backup=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --outbound) outbound="${2:-}"; shift 2 ;;
    --listen) listen="${2:-}"; shift 2 ;;
    --no-backup) no_backup=1; shift ;;
    -h|--help) usage ;;
    *) echo "add-proxy: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ]   && { echo "add-proxy: --router обязателен" >&2; usage; }
[ -z "$port" ]     && { echo "add-proxy: --port обязателен" >&2; usage; }
[ -z "$outbound" ] && { echo "add-proxy: --outbound обязателен" >&2; usage; }

if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
  echo "add-proxy: --port должен быть число" >&2; exit 13
fi
if [ "$port" -lt 4000 ] || [ "$port" -gt 4099 ]; then
  echo "add-proxy: --port должен быть 4000..4099 (получено $port)" >&2; exit 13
fi
if ! printf '%s' "$outbound" | grep -qE '^[a-zA-Z0-9_-]+$'; then
  echo "add-proxy: невалидный --outbound" >&2; exit 13
fi
# Validate --listen shape (dotted-quad or hostname-safe chars only).
case "$listen" in
  *[!a-zA-Z0-9.:_-]*|'') echo "add-proxy: invalid --listen: '$listen'" >&2; exit 13 ;;
esac

resolve_router_config "$router"

if ! ssh_check_alive 5; then
  echo "add-proxy: SSH недоступен для '$ROUTER_ALIAS' ($ROUTER_HOST)" >&2
  exit 2
fi

remote_cfg="/etc/sing-box/config.json"
local_cfg="$(mktemp -t openwrt-skill-cfg.XXXXXX)"
local_new_cfg="$(mktemp -t openwrt-skill-cfgnew.XXXXXX)"
trap 'rm -f "$local_cfg" "$local_new_cfg"' EXIT INT TERM

if ! scp_from "$remote_cfg" "$local_cfg" >/dev/null 2>&1; then
  echo "add-proxy: не смог получить $remote_cfg" >&2
  exit 2
fi

# Verify outbound tag exists.
if ! jq -e --arg t "$outbound" '.outbounds[]? | select(.tag == $t)' "$local_cfg" >/dev/null 2>&1; then
  echo "add-proxy: outbound '$outbound' не найден в config.json" >&2
  exit 13
fi

# Verify port not already in use.
used="$(jq -r --arg p "$port" '.inbounds[]? | select(.listen_port == ($p|tonumber)) | .tag' "$local_cfg")"
if [ -n "$used" ]; then
  echo "add-proxy: порт $port уже занят inbound'ом '$used'" >&2
  exit 13
fi

# ---------------------------------------------------------------------------
# Pre-backup
# ---------------------------------------------------------------------------
# Hard-fail if backup-now.sh missing or non-zero. No inline tar fallback.
snapshot_id=""
if [ "$no_backup" = "1" ]; then
  snapshot_id="(no-backup)"
else
  if [ ! -x "$OPENWRT_SKILL_HOME/bin/backup-now.sh" ]; then
    echo "add-proxy: backup-now.sh не найден в $OPENWRT_SKILL_HOME/bin/ — починить перед использованием add/remove-vpn/proxy" >&2
    exit 2
  fi
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" --label "before add-proxy $port→$outbound" --quiet)"; then
    echo "add-proxy: backup-now.sh failed — отказываюсь продолжать без снапшота" >&2
    exit 2
  fi
fi

rollback_inline() {
  [ -z "$snapshot_id" ] && return 0
  [ "$snapshot_id" = "(no-backup)" ] && {
    echo "add-proxy: rollback не возможен — запуск был с --no-backup" >&2
    return 0
  }
  if [ -x "$OPENWRT_SKILL_HOME/bin/restore.sh" ]; then
    "$OPENWRT_SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" --snapshot "$snapshot_id" >/dev/null 2>&1 || true
  else
    echo "add-proxy: restore.sh отсутствует — ручной откат необходим" >&2
  fi
}

# ---------------------------------------------------------------------------
# Build new config: append mixed inbound + insert route rule before failover catch-all.
# ---------------------------------------------------------------------------
jq_failed=0
jq \
  --arg outbound "$outbound" \
  --arg listen "$listen" \
  --argjson port "$port" \
  --arg port_str "$port" \
  '
    .inbounds = ((.inbounds // []) + [{
        type: "mixed",
        tag: ("in-proxy-" + $port_str),
        listen: $listen,
        listen_port: $port,
        sniff: true
      }])
    | (.route = (.route // {}))
    | (.route.rules = (.route.rules // []))
    | (.route.rules =
        (
          (.route.rules
            | map(select(
                ((.outbound // "") != "auto-failover")
                or ((.inbound // null) != null)
                or ((.domain // null) != null)
                or ((.domain_suffix // null) != null)
                or ((.rule_set // null) != null)
                or ((.source_ip_cidr // null) != null)
              ))
          )
          + [{
              action: "route",
              inbound: [("in-proxy-" + $port_str)],
              outbound: $outbound
            }]
          +
          (.route.rules
            | map(select(
                ((.outbound // "") == "auto-failover")
                and ((.inbound // null) == null)
                and ((.domain // null) == null)
                and ((.domain_suffix // null) == null)
                and ((.rule_set // null) == null)
                and ((.source_ip_cidr // null) == null)
              ))
          )
        ))
  ' "$local_cfg" > "$local_new_cfg" || jq_failed=1

if [ "$jq_failed" = "1" ] || ! jq -e '.outbounds' "$local_new_cfg" >/dev/null 2>&1; then
  echo "add-proxy: jq не смог собрать новый config.json" >&2
  rollback_inline
  exit 13
fi

# Upload + check + atomic mv.
remote_new="/tmp/openwrt-skill-config-new.$$.json"
if ! scp_to "$local_new_cfg" "$remote_new" >/dev/null 2>&1; then
  echo "add-proxy: scp не удался" >&2
  rollback_inline
  exit 2
fi
if ! ssh_run "sing-box check -c $remote_new" >/dev/null 2>&1; then
  echo "add-proxy: 'sing-box check' зафейлился" >&2
  ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
  rollback_inline
  exit 13
fi
if ! ssh_run "chmod 600 $remote_new && mv -f $remote_new $remote_cfg" >/dev/null 2>&1; then
  echo "add-proxy: не смог mv $remote_new → $remote_cfg" >&2
  ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
  rollback_inline
  exit 2
fi

# ---------------------------------------------------------------------------
# Staged-apply restart + reachability watch
# ---------------------------------------------------------------------------
restart_failed=0
ssh_run "/etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1 || restart_failed=1

reachable=0
end=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$end" ]; do
  if ssh_check_alive 3; then reachable=1; break; fi
  sleep 2
done

if [ "$restart_failed" = "1" ] || [ "$reachable" != "1" ]; then
  echo "add-proxy: restart/reachability fail — катываем" >&2
  rollback_inline
  exit 20
fi
if ! ssh_run "/etc/init.d/sing-box-tproxy status >/dev/null 2>&1 || pgrep -f sing-box >/dev/null" >/dev/null 2>&1; then
  echo "add-proxy: sing-box не запустился — катываем" >&2
  rollback_inline
  exit 20
fi

# ---------------------------------------------------------------------------
# Update memory + journal
# ---------------------------------------------------------------------------
proxies_md="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/proxies.md"

journal_args=("port=$port" "outbound=$outbound" "listen=$listen")
[ -n "$snapshot_id" ] && journal_args+=("snapshot_before=$snapshot_id")
memory_journal_append "$ROUTER_ALIAS" "add_proxy" "${journal_args[@]}" || \
  echo "add-proxy: WARN — не смог записать journal" >&2

mem_lock="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/.lock"
mkdir -p "$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"
touch "$mem_lock"
{
  flock -x -w 5 9 || { echo "add-proxy: не могу взять lock на memory" >&2; exit 12; }

  if [ -f "$proxies_md" ]; then
    prow="| $port | $outbound | через $outbound | $listen |"
    if grep -q '{{PROXY_TABLE_ROWS}}' "$proxies_md"; then
      tmp="$(mktemp)"
      awk -v r="$prow" '{ if ($0 ~ /\{\{PROXY_TABLE_ROWS\}\}/) print r; else print }' "$proxies_md" > "$tmp" && mv "$tmp" "$proxies_md"
    elif grep -qE '_\(пока пусто' "$proxies_md" 2>/dev/null; then
      tmp="$(mktemp)"
      awk -v r="$prow" 'BEGIN{d=0} { if (!d && $0 ~ /_\(пока пусто/) { print r; d=1 } else { print } } END{ if (!d) print r }' "$proxies_md" > "$tmp" && mv "$tmp" "$proxies_md"
    else
      printf '%s\n' "$prow" >> "$proxies_md"
    fi
  fi
} 9>"$mem_lock"

cat >&2 <<EOF

add-proxy: успех — mixed inbound :$port → $outbound.
  Тест:  curl --proxy http://$listen:$port https://api.ipify.org
EOF
exit 0
