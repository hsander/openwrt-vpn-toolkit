#!/usr/bin/env bash
# Force currently associated 192.168.1.x DHCP clients to reconnect and renew.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPENWRT_SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
source "$OPENWRT_SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
source "$OPENWRT_SKILL_HOME/lib/ssh-runner.sh"

router=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: $0 --router <alias>"; exit 0 ;;
    *) echo "renew-legacy-lan-clients: unknown arg: $1" >&2; exit 13 ;;
  esac
done

resolve_router_config "$router"

snapshot="$($OPENWRT_SKILL_HOME/bin/backup-now.sh --router "$ROUTER_ALIAS" \
  --label 'before legacy DHCP client renew' --quiet)"
printf 'snapshot=%s\n' "$snapshot"

ssh_run_remote <<'SH'
set -eu

targets="$(awk '$3 ~ /^192\.168\.1\./ {print tolower($2)}' /tmp/dhcp.leases 2>/dev/null | sort -u)"
[ -n "$targets" ] || { echo 'legacy_clients=none'; exit 0; }

for mac in $targets; do
  disconnected=false
  for object in $(ubus list 'hostapd.*' 2>/dev/null); do
    if ubus call "$object" get_clients 2>/dev/null \
      | jq -e --arg mac "$mac" '.clients | has($mac)' >/dev/null; then
      ubus call "$object" del_client \
        "{\"addr\":\"$mac\",\"reason\":3,\"deauth\":true,\"ban_time\":1000}" \
        >/dev/null
      printf 'deauthenticated=%s radio=%s\n' "$mac" "$object"
      disconnected=true
    fi
  done
  [ "$disconnected" = true ] || printf 'not_associated=%s\n' "$mac"
done

sleep 15
echo '[leases-after-renew]'
awk '$3 ~ /^192\.168\.(1|99)\./ {print $2, $3, $4}' /tmp/dhcp.leases 2>/dev/null | sort
SH
