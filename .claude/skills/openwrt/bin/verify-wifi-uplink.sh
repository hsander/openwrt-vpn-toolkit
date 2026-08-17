#!/usr/bin/env bash
# Verify a Wi-Fi WAN after boot without printing credentials.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"
. "$SKILL_HOME/lib/router-config.sh"
. "$SKILL_HOME/lib/ssh-runner.sh"

router=""
ssh_alias_override=""
expected_ssid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias_override="${2:-}"; shift 2 ;;
    --expected-ssid) expected_ssid="${2:-}"; shift 2 ;;
    *) echo "Usage: bin/verify-wifi-uplink.sh --router <alias> [--ssh-alias <alias>] --expected-ssid <ssid>" >&2; exit 64 ;;
  esac
done
[ -n "$router" ] && [ -n "$expected_ssid" ] || exit 64
[[ "$expected_ssid" =~ ^[A-Za-z0-9_.+-]{1,32}$ ]] || exit 13
if [ -n "$ssh_alias_override" ]; then
  [[ "$ssh_alias_override" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
fi

resolve_router_config "$router"
if [ -n "$ssh_alias_override" ]; then
  ROUTER_SSH_ALIAS="$ssh_alias_override"
  export ROUTER_SSH_ALIAS
fi
ssh_check_alive 5 || exit 2
ssh_run_remote_with_args /dev/stdin "$expected_ssid" <<'REMOTE_SH'
set -eu
expected_ssid="$1"

configured_ssid="$(uci -q get wireless.awg2_uplink.ssid || true)"
[ "$configured_ssid" = "$expected_ssid" ] || {
  echo "ssid_configured=false"
  exit 1
}
echo "ssid_configured=true"

status="$(ubus call network.interface.wwan status 2>/dev/null || true)"
printf '%s' "$status" | grep -q '"up": true' || {
  echo "wwan_up=false"
  exit 1
}
echo "wwan_up=true"

wwan_ip="$(printf '%s' "$status" | sed -n 's/.*"address": "\([0-9.]*\)".*/\1/p' | head -n 1)"
echo "wwan_ipv4=${wwan_ip:-unknown}"

route="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1)"
case "$route" in
  *phy*-sta*) echo "internet_route_via_wifi=true" ;;
  *)
    echo "internet_route_via_wifi=false"
    exit 1
    ;;
esac

if ping -c 3 -W 2 1.1.1.1 >/dev/null 2>&1; then
  echo "internet_ipv4=ok"
else
  echo "internet_ipv4=failed"
  exit 1
fi

if nslookup openwrt.org >/dev/null 2>&1; then
  echo "dns_resolution=ok"
else
  echo "dns_resolution=failed"
  exit 1
fi
REMOTE_SH
