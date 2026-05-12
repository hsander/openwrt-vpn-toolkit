#!/usr/bin/env bash
# bin/remove-proxy.sh — remove a mixed inbound (and its route rule) from
# /etc/sing-box/config.json on the router.
#
# Reverses bin/add-proxy.sh:
#   * removes the inbound whose listen_port == <port>
#   * removes any route rule that references that inbound's tag
#
# Idempotent: if no inbound on that port — exit 0 silently.
#
# Usage:
#   bin/remove-proxy.sh --router <alias> --port <port> [--no-backup]
#
# Exit codes:
#   0   ok (also when port has no inbound)
#   2   router not found / SSH unreachable
#  13   validation
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
Usage: bin/remove-proxy.sh --router <alias> --port <port> [--no-backup]

Удаляет mixed-inbound (и связанное route rule) на указанном порту.

Options:
  --router <alias>     alias из memory/routers.yaml (обяз.)
  --port <port>        порт mixed-inbound'а (обяз.)
  --no-backup          (только для тестов) пропустить pre-backup.
EOF
  exit 64
}

router=""
port=""
no_backup=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --no-backup) no_backup=1; shift ;;
    -h|--help) usage ;;
    *) echo "remove-proxy: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "remove-proxy: --router обязателен" >&2; usage; }
[ -z "$port" ]   && { echo "remove-proxy: --port обязателен" >&2; usage; }

if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
  echo "remove-proxy: --port должен быть число" >&2; exit 13
fi

resolve_router_config "$router"

if ! ssh_check_alive 5; then
  echo "remove-proxy: SSH недоступен для '$ROUTER_ALIAS' ($ROUTER_HOST)" >&2
  exit 2
fi

remote_cfg="/etc/sing-box/config.json"
local_cfg="$(mktemp -t openwrt-skill-cfg.XXXXXX)"
local_new_cfg="$(mktemp -t openwrt-skill-cfgnew.XXXXXX)"
trap 'rm -f "$local_cfg" "$local_new_cfg"' EXIT INT TERM

if ! scp_from "$remote_cfg" "$local_cfg" >/dev/null 2>&1; then
  echo "remove-proxy: не смог получить $remote_cfg" >&2
  exit 2
fi

# Find inbound tag(s) by port.
inbound_tags="$(jq -r --arg p "$port" '.inbounds[]? | select(.listen_port == ($p|tonumber)) | .tag // empty' "$local_cfg")"

if [ -z "$inbound_tags" ]; then
  echo "remove-proxy: на порту $port inbound'ов не нашёл (и так нет)" >&2
  exit 0
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
    echo "remove-proxy: backup-now.sh не найден в $OPENWRT_SKILL_HOME/bin/ — починить перед использованием add/remove-vpn/proxy" >&2
    exit 2
  fi
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" --label "before remove-proxy :$port" --quiet)"; then
    echo "remove-proxy: backup-now.sh failed — отказываюсь продолжать без снапшота" >&2
    exit 2
  fi
fi

rollback_inline() {
  [ -z "$snapshot_id" ] && return 0
  [ "$snapshot_id" = "(no-backup)" ] && {
    echo "remove-proxy: rollback не возможен — запуск был с --no-backup" >&2
    return 0
  }
  if [ -x "$OPENWRT_SKILL_HOME/bin/restore.sh" ]; then
    "$OPENWRT_SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" --snapshot "$snapshot_id" >/dev/null 2>&1 || true
  else
    echo "remove-proxy: restore.sh отсутствует — ручной откат необходим" >&2
  fi
}

# ---------------------------------------------------------------------------
# Build new config: drop inbound by port, drop matching route rules.
# ---------------------------------------------------------------------------
jq_failed=0
jq --argjson port "$port" '
  ( [.inbounds[]? | select(.listen_port == $port) | .tag // empty] ) as $drop
  | .inbounds = ((.inbounds // []) | map(select(.listen_port != $port)))
  | (.route.rules = ((.route.rules // []) | map(
       select(
         ((.inbound // []) | map(. as $t | ($drop | index($t)) | not) | all)
       )
     )))
' "$local_cfg" > "$local_new_cfg" || jq_failed=1

if [ "$jq_failed" = "1" ] || ! jq -e '.outbounds' "$local_new_cfg" >/dev/null 2>&1; then
  echo "remove-proxy: jq не смог собрать новый config.json" >&2
  exit 13
fi

remote_new="/tmp/openwrt-skill-config-new.$$.json"
if ! scp_to "$local_new_cfg" "$remote_new" >/dev/null 2>&1; then
  echo "remove-proxy: scp не удался" >&2; exit 2
fi
if ! ssh_run "sing-box check -c $remote_new" >/dev/null 2>&1; then
  echo "remove-proxy: 'sing-box check' зафейлился" >&2
  ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
  exit 13
fi
if ! ssh_run "chmod 600 $remote_new && mv -f $remote_new $remote_cfg" >/dev/null 2>&1; then
  echo "remove-proxy: не смог mv $remote_new → $remote_cfg" >&2
  ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
  exit 2
fi

# ---------------------------------------------------------------------------
# Staged-apply restart
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
  echo "remove-proxy: restart/reachability fail — катываем" >&2
  rollback_inline
  exit 20
fi
if ! ssh_run "/etc/init.d/sing-box-tproxy status >/dev/null 2>&1 || pgrep -f sing-box >/dev/null" >/dev/null 2>&1; then
  echo "remove-proxy: sing-box не запустился — катываем" >&2
  rollback_inline
  exit 20
fi

# ---------------------------------------------------------------------------
# Update memory + journal
# ---------------------------------------------------------------------------
proxies_md="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/proxies.md"

journal_args=("port=$port")
[ -n "$snapshot_id" ] && journal_args+=("snapshot_before=$snapshot_id")
memory_journal_append "$ROUTER_ALIAS" "remove_proxy" "${journal_args[@]}" || \
  echo "remove-proxy: WARN — не смог записать journal" >&2

mem_lock="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/.lock"
mkdir -p "$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"
touch "$mem_lock"
{
  flock -x -w 5 9 || { echo "remove-proxy: не могу взять lock на memory" >&2; exit 12; }

  if [ -f "$proxies_md" ]; then
    tmp="$(mktemp)"
    awk -v port="$port" '
      BEGIN { pat = "^\\| " port " \\|" }
      $0 ~ pat { next }
      { print }
    ' "$proxies_md" > "$tmp" && mv "$tmp" "$proxies_md"
  fi
} 9>"$mem_lock"

cat >&2 <<EOF

remove-proxy: успех — порт :$port снят с config.json.
EOF
exit 0
