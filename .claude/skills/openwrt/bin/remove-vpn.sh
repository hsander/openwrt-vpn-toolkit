#!/usr/bin/env bash
# bin/remove-vpn.sh — remove a VLESS outbound from /etc/sing-box/config.json.
#
# Reverses bin/add-vpn.sh:
#   * deletes the outbound with the matching tag
#   * removes the tag from auto-failover.outbounds
#   * removes any mixed-inbound + route rule that pointed at this outbound
#   * removes the server IP from zapret-custom vpn_servers nft set
#
# Safety: refuses to remove the LAST VPN outbound (would orphan the router).
# Override with --force-orphan.
#
# Usage:
#   bin/remove-vpn.sh --router <alias> --tag <name> [--no-backup] [--force-orphan]
#
# Exit codes:
#   0   ok (also when tag already absent — idempotent)
#   2   router not found / SSH unreachable
#  13   safety refuse / validation
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
# shellcheck source=../lib/watchdog-sync.sh
. "$SKILL_HOME/lib/watchdog-sync.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/remove-vpn.sh --router <alias> --tag <name> [--no-backup] [--force-orphan]

Удаляет VLESS outbound из /etc/sing-box/config.json роутера.

Options:
  --router <alias>     alias из memory/routers.yaml (обяз.)
  --tag <name>         tag outbound'а для удаления (обяз.)
  --no-backup          (только для тестов) пропустить pre-backup.
  --force-orphan       разрешить удаление последнего VPN-outbound'а (опасно).
EOF
  exit 64
}

router=""
tag=""
no_backup=0
force_orphan=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --tag) tag="${2:-}"; shift 2 ;;
    --no-backup) no_backup=1; shift ;;
    --force-orphan) force_orphan=1; shift ;;
    -h|--help) usage ;;
    *) echo "remove-vpn: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "remove-vpn: --router обязателен" >&2; usage; }
[ -z "$tag" ]    && { echo "remove-vpn: --tag обязателен" >&2; usage; }

if ! printf '%s' "$tag" | grep -qE '^[a-zA-Z0-9_-]+$'; then
  echo "remove-vpn: невалидный --tag (a-zA-Z0-9_-)" >&2
  exit 13
fi
if [ "$tag" = "direct" ] || [ "$tag" = "auto-failover" ]; then
  echo "remove-vpn: tag '$tag' нельзя удалять" >&2
  exit 13
fi

resolve_router_config "$router"

if ! ssh_check_alive 5; then
  echo "remove-vpn: SSH недоступен для '$ROUTER_ALIAS' ($ROUTER_HOST)" >&2
  exit 2
fi

remote_cfg="/etc/sing-box/config.json"
local_cfg="$(mktemp -t openwrt-skill-cfg.XXXXXX)"
local_new_cfg="$(mktemp -t openwrt-skill-cfgnew.XXXXXX)"
trap 'rm -f "$local_cfg" "$local_new_cfg"' EXIT INT TERM

if ! scp_from "$remote_cfg" "$local_cfg" >/dev/null 2>&1; then
  echo "remove-vpn: не смог получить $remote_cfg с роутера" >&2
  exit 2
fi

# Idempotent: if tag not in outbounds — exit 0.
if ! jq -e --arg t "$tag" '.outbounds[]? | select(.tag == $t)' "$local_cfg" >/dev/null 2>&1; then
  echo "remove-vpn: tag '$tag' и так нет в config.json (уже нет)" >&2
  exit 0
fi

# Pull the server host before we delete the outbound (for zapret cleanup).
v_host="$(jq -r --arg t "$tag" '.outbounds[]? | select(.tag == $t) | .server // ""' "$local_cfg")"

# Validate shape (defence in depth — even though source is local JSON file).
if [ -n "$v_host" ]; then
  case "$v_host" in
    *[!a-zA-Z0-9.:_-]*) echo "remove-vpn: invalid host in config.json: '$v_host'" >&2; exit 13 ;;
  esac
fi

# Safety: count VPN-style outbounds (anything that isn't direct/dns/block/urltest/selector).
vpn_outbounds_count="$(jq -r '
  [.outbounds[]? | select(.type != "direct" and .type != "dns" and .type != "block" and .type != "urltest" and .type != "selector")] | length
' "$local_cfg")"
failover_outbounds="$(jq -r '
  .outbounds[]? | select(.type == "urltest" and .tag == "auto-failover") | .outbounds[]?
' "$local_cfg" 2>/dev/null || true)"

if [ "$vpn_outbounds_count" -le 1 ] && [ "$force_orphan" != "1" ]; then
  echo "remove-vpn: '$tag' — последний VPN-outbound; удаление оставит роутер без VPN" >&2
  echo "  Если ты уверен — повтори с --force-orphan." >&2
  exit 13
fi

# If auto-failover would become empty AND the user tries to remove the only entry,
# also refuse (unless --force-orphan).
if [ -n "$failover_outbounds" ] && [ "$force_orphan" != "1" ]; then
  remaining_in_fo="$(printf '%s\n' "$failover_outbounds" | grep -vFx "$tag" | grep -v '^$' || true)"
  if [ -z "$remaining_in_fo" ]; then
    echo "remove-vpn: после удаления '$tag' в auto-failover.outbounds не останется ни одного — отказ" >&2
    echo "  Сначала добавь другой outbound в failover или используй --force-orphan." >&2
    exit 13
  fi
fi

# Check that no country-pool urltest would become empty after removal (unless --force-orphan).
if [ "$force_orphan" != "1" ]; then
  empty_pool="$(jq -r --arg t "$tag" '
    .outbounds[]? |
    select(.type == "urltest" and .tag != "auto-failover") |
    select((.outbounds // []) | any(. == $t)) |
    select(((.outbounds // []) | map(select(. != $t)) | length) == 0) |
    .tag
  ' "$local_cfg" 2>/dev/null || true)"
  if [ -n "$empty_pool" ]; then
    echo "remove-vpn: удаление '$tag' опустошит pool '$empty_pool' — отказ" >&2
    echo "  Сначала добавь другую ноду в pool или используй --force-orphan." >&2
    exit 13
  fi
fi

# ---------------------------------------------------------------------------
# Pre-backup
# ---------------------------------------------------------------------------
# Hard-fail if backup-now.sh missing or non-zero. No inline tar fallback (used
# to write DIRECTORIES invisible to restore.sh / snapshot-list.sh).
snapshot_id=""
if [ "$no_backup" = "1" ]; then
  snapshot_id="(no-backup)"
else
  if [ ! -x "$OPENWRT_SKILL_HOME/bin/backup-now.sh" ]; then
    echo "remove-vpn: backup-now.sh не найден в $OPENWRT_SKILL_HOME/bin/ — починить перед использованием add/remove-vpn/proxy" >&2
    exit 2
  fi
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" --label "before remove-vpn $tag" --quiet)"; then
    echo "remove-vpn: backup-now.sh failed — отказываюсь продолжать без снапшота" >&2
    exit 2
  fi
fi

rollback_inline() {
  [ -z "$snapshot_id" ] && return 0
  [ "$snapshot_id" = "(no-backup)" ] && {
    echo "remove-vpn: rollback не возможен — запуск был с --no-backup" >&2
    return 0
  }
  if [ -x "$OPENWRT_SKILL_HOME/bin/restore.sh" ]; then
    "$OPENWRT_SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" --snapshot "$snapshot_id" >/dev/null 2>&1 || true
  else
    echo "remove-vpn: restore.sh отсутствует — ручной откат необходим" >&2
  fi
}

# ---------------------------------------------------------------------------
# Build new config: drop outbound, drop from auto-failover, drop matching inbounds/rules.
# ---------------------------------------------------------------------------
# Find inbound tags whose route rules pointed at this outbound — these are the
# in-proxy-<port> inbounds we should also remove.
removed_inbound_tags="$(jq -r --arg t "$tag" '
  [.route.rules[]? | select(.outbound == $t) | .inbound[]?] | unique | .[]?
' "$local_cfg" 2>/dev/null || true)"

# Also pick the port numbers (for memory cleanup + journal).
removed_proxy_ports=""
if [ -n "$removed_inbound_tags" ]; then
  while IFS= read -r itag; do
    [ -z "$itag" ] && continue
    p="$(jq -r --arg it "$itag" '.inbounds[]? | select(.tag == $it) | .listen_port' "$local_cfg" 2>/dev/null || true)"
    if [ -n "$p" ] && [ "$p" != "null" ]; then
      removed_proxy_ports="${removed_proxy_ports}${p} "
    fi
  done <<EOF
$removed_inbound_tags
EOF
fi

jq_failed=0
jq --arg t "$tag" --arg force_orphan "$force_orphan" '
  .outbounds = ((.outbounds // []) | map(select((.tag // "") != $t)))

  # Step A: remove tag from ALL urltest groups (not just auto-failover)
  | .outbounds = (.outbounds | map(
      if .type == "urltest" then
        .outbounds = ((.outbounds // []) | map(select(. != $t)))
      else . end
    ))

  # Step B: if --force-orphan, remove urltest outbounds whose .outbounds became empty
  | if $force_orphan == "1" then
      .outbounds = (.outbounds | map(select(
        if .type == "urltest" then (.outbounds // [] | length) > 0
        else true end
      )))
    else . end

  | (
      # collect inbound tags to drop (those used by route rules with outbound=$t)
      . as $root
      | ($root.route.rules // [] | map(select(.outbound == $t) | .inbound // [] | .[]) | unique) as $drop_inb
      | .inbounds = ((.inbounds // []) | map(select((.tag // "") as $tg | ($drop_inb | index($tg)) | not)))
      | .route.rules = ((.route.rules // []) | map(select(.outbound != $t)))
    )
' "$local_cfg" > "$local_new_cfg" || jq_failed=1

if [ "$jq_failed" = "1" ] || ! jq -e '.outbounds' "$local_new_cfg" >/dev/null 2>&1; then
  echo "remove-vpn: jq не смог собрать новый config.json" >&2
  exit 13
fi

# Upload + sing-box check + atomic mv.
remote_new="/tmp/openwrt-skill-config-new.$$.json"
if ! scp_to "$local_new_cfg" "$remote_new" >/dev/null 2>&1; then
  echo "remove-vpn: scp нового config.json не удался" >&2
  exit 2
fi
if ! ssh_run "sing-box check -c $remote_new" >/dev/null 2>&1; then
  echo "remove-vpn: 'sing-box check' зафейлился на новом config'е" >&2
  ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
  exit 13
fi
if ! ssh_run "chmod 600 $remote_new && mv -f $remote_new $remote_cfg" >/dev/null 2>&1; then
  echo "remove-vpn: не смог mv $remote_new → $remote_cfg" >&2
  ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
  exit 2
fi

# ---------------------------------------------------------------------------
# zapret cleanup
# ---------------------------------------------------------------------------
zapret_path="/etc/init.d/zapret-custom"
zapret_ip=""
case "$v_host" in
  *[!0-9.]*)
    # Defense in depth: escape v_host even though we've already shape-validated.
    v_host_q="$(printf '%q' "$v_host")"
    zapret_ip="$(ssh_run "nslookup $v_host_q 2>/dev/null | awk '/^Address[ :]/{ip=\$NF} END{if(ip)print ip}'" 2>/dev/null || true)"
    # Validate the looked-up address.
    case "$zapret_ip" in
      ''|*[!0-9.]*)
        echo "remove-vpn: zapret IP lookup failed or invalid: '$zapret_ip' — пропускаю zapret cleanup" >&2
        zapret_ip=""
        ;;
    esac
    if [ -n "$zapret_ip" ] && ! printf '%s' "$zapret_ip" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      echo "remove-vpn: zapret IP malformed: '$zapret_ip' — пропускаю zapret cleanup" >&2
      zapret_ip=""
    fi
    ;;
  *)
    zapret_ip="$v_host"
    ;;
esac

if [ -n "$zapret_ip" ] && ssh_run "[ -f $zapret_path ]" >/dev/null 2>&1; then
  # zapret_ip is regex-validated above (v4-only) so direct interpolation is safe.
  ssh_run "
    set -eu
    ip='$zapret_ip'
    f='$zapret_path'
    # Idempotent removal from any 'nft add element ... vpn_servers { ... }' line.
    sed -i \"s/, *\$ip\\b//g; s/{ *\$ip *,/{/g; s/{ *\$ip *}/{ }/g\" \"\$f\" || true
    nft delete element inet zapret_custom vpn_servers { \$ip } 2>/dev/null || true
  " >/dev/null 2>&1 || echo "remove-vpn: WARN — zapret-custom cleanup частично не удался" >&2
fi

# ---------------------------------------------------------------------------
# Staged-apply restart with reachability watch + auto-rollback
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
  echo "remove-vpn: restart/reachability fail — катываем" >&2
  rollback_inline
  exit 20
fi

if ! ssh_run "/etc/init.d/sing-box-tproxy status >/dev/null 2>&1 || pgrep -f sing-box >/dev/null" >/dev/null 2>&1; then
  echo "remove-vpn: sing-box не запустился после restart — катываем" >&2
  rollback_inline
  exit 20
fi

# ---------------------------------------------------------------------------
# Sync vpn-nodes-watchdog NODES= list on router
# ---------------------------------------------------------------------------
sync_vpn_nodes_watchdog "$ROUTER_ALIAS"

# ---------------------------------------------------------------------------
# Update memory (drop row from vpns.md + any matching proxies.md row)
# ---------------------------------------------------------------------------
mem_dir="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"
vpns_md="$mem_dir/vpns.md"
proxies_md="$mem_dir/proxies.md"

# ---------------------------------------------------------------------------
# Journal first (atomic single-file append), then per-router flock on MD edits.
# ---------------------------------------------------------------------------
journal_args=("tag=$tag")
[ -n "$snapshot_id" ] && journal_args+=("snapshot_before=$snapshot_id")
ports_csv="$(printf '%s' "$removed_proxy_ports" | tr ' ' ',' | sed 's/,$//; s/^,//')"
[ -n "$ports_csv" ] && journal_args+=("removed_proxy_ports=$ports_csv")

memory_journal_append "$ROUTER_ALIAS" "remove_vpn" "${journal_args[@]}" || \
  echo "remove-vpn: WARN — не смог записать journal" >&2

mem_lock="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/.lock"
mkdir -p "$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"
touch "$mem_lock"
{
  flock -x -w 5 9 || { echo "remove-vpn: не могу взять lock на memory" >&2; exit 12; }

  if [ -f "$vpns_md" ]; then
    tmp="$(mktemp)"
    awk -v t="$tag" '
      BEGIN { pat = "^\\| " t " \\|" }
      $0 ~ pat { next }
      { print }
    ' "$vpns_md" > "$tmp" && mv "$tmp" "$vpns_md"
  fi

  if [ -f "$proxies_md" ] && [ -n "$removed_proxy_ports" ]; then
    for p in $removed_proxy_ports; do
      tmp="$(mktemp)"
      awk -v port="$p" '
        BEGIN { pat = "^\\| " port " \\|" }
        $0 ~ pat { next }
        { print }
      ' "$proxies_md" > "$tmp" && mv "$tmp" "$proxies_md"
    done
  fi
} 9>"$mem_lock"

cat >&2 <<EOF

remove-vpn: успех — удалён outbound '$tag'.
  proxy ports снесено:   ${ports_csv:-—}
  sing-box перезапущен:  да
EOF
exit 0
