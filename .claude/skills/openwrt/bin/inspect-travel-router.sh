#!/usr/bin/env bash
# Read-only, secret-free inventory for preparing a Travelmate travel router.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"

usage() {
  echo "Usage: bin/inspect-travel-router.sh --router <alias> [--ssh-alias <alias>]" >&2
  exit 64
}

router=""
ssh_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$router" ] || usage
resolve_router_config "$router"

if [ -n "$ssh_alias" ]; then
  [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || {
    echo "inspect-travel-router: invalid SSH alias" >&2
    exit 13
  }
  ssh_cmd=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 "$ssh_alias")
else
  ssh_check_alive 5 || exit 2
  ssh_cmd=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -i "$ROUTER_SSH_KEY" -o HostKeyAlias="${ROUTER_HOST_KEY_ALIAS:-$ROUTER_HOST}" "$ROUTER_USER@$ROUTER_HOST")
fi

"${ssh_cmd[@]}" 'sh -s' <<'REMOTE_SH'
set -u

echo "system_begin"
echo "board=$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name' 2>/dev/null || true)"
echo "release=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.version' 2>/dev/null || true)"
echo "free_kb=$(df -Pk /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
echo "system_end"

echo "packages_begin"
for pkg in travelmate luci-app-travelmate curl ca-bundle luci-ssl; do
  if apk info -e "$pkg" >/dev/null 2>&1; then
    version="$(apk info "$pkg" 2>/dev/null | sed -n '1s/^[^-]*-//p')"
    echo "package=$pkg installed=true version=$version"
  else
    echo "package=$pkg installed=false"
  fi
done
echo "packages_end"

echo "network_begin"
for iface in lan wan wan6 wwan trm_wwan awg1; do
  proto="$(uci -q get network."$iface".proto || true)"
  [ -n "$proto" ] || continue
  ipaddr="$(uci -q get network."$iface".ipaddr || true)"
  netmask="$(uci -q get network."$iface".netmask || true)"
  metric="$(uci -q get network."$iface".metric || true)"
  device="$(uci -q get network."$iface".device || true)"
  status="$(ubus call network.interface."$iface" status 2>/dev/null || true)"
  up="$(printf '%s' "$status" | jsonfilter -e '@.up' 2>/dev/null || true)"
  runtime_ip="$(printf '%s' "$status" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null || true)"
  echo "interface=$iface proto=$proto device=$device ipaddr=$ipaddr netmask=$netmask metric=$metric up=$up runtime_ip=$runtime_ip"
done
echo "routes_begin"
ip -4 route show 2>/dev/null | sed -n '1,30p'
echo "routes_end"
echo "network_end"

echo "wireless_begin"
for radio in $(uci -q show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-device$/\1/p"); do
  band="$(uci -q get wireless."$radio".band || true)"
  channel="$(uci -q get wireless."$radio".channel || true)"
  disabled="$(uci -q get wireless."$radio".disabled || echo 0)"
  echo "radio=$radio band=$band channel=$channel disabled=$disabled"
done
for wifi in $(uci -q show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
  mode="$(uci -q get wireless."$wifi".mode || true)"
  device="$(uci -q get wireless."$wifi".device || true)"
  network="$(uci -q get wireless."$wifi".network || true)"
  ssid="$(uci -q get wireless."$wifi".ssid || true)"
  encryption="$(uci -q get wireless."$wifi".encryption || true)"
  disabled="$(uci -q get wireless."$wifi".disabled || echo 0)"
  hidden="$(uci -q get wireless."$wifi".hidden || echo 0)"
  echo "wifi=$wifi mode=$mode device=$device network=$network ssid=$ssid encryption=$encryption disabled=$disabled hidden=$hidden"
done
echo "wireless_end"

echo "firewall_begin"
for zone in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=zone$/\1/p"); do
  name="$(uci -q get firewall."$zone".name || true)"
  input="$(uci -q get firewall."$zone".input || true)"
  output="$(uci -q get firewall."$zone".output || true)"
  forward="$(uci -q get firewall."$zone".forward || true)"
  masq="$(uci -q get firewall."$zone".masq || echo 0)"
  networks="$(uci -q get firewall."$zone".network || true)"
  echo "zone=$zone name=$name input=$input output=$output forward=$forward masq=$masq networks=$networks"
done
for fwd in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
  src="$(uci -q get firewall."$fwd".src || true)"
  dest="$(uci -q get firewall."$fwd".dest || true)"
  echo "forwarding=$fwd src=$src dest=$dest"
done
echo "firewall_end"

echo "services_begin"
for svc in uhttpd travelmate; do
  if [ -x /etc/init.d/"$svc" ]; then
    /etc/init.d/"$svc" enabled >/dev/null 2>&1 && enabled=true || enabled=false
    /etc/init.d/"$svc" running >/dev/null 2>&1 && running=true || running=false
    echo "service=$svc installed=true enabled=$enabled running=$running"
  else
    echo "service=$svc installed=false"
  fi
done
echo "services_end"

echo "travelmate_begin"
if [ -f /etc/config/travelmate ]; then
  for opt in trm_enabled trm_iface trm_laniface trm_radio trm_revradio trm_captive trm_netcheck trm_proactive trm_autoadd trm_randomize trm_eviltwin trm_maxretry; do
    val="$(uci -q get travelmate.global."$opt" || true)"
    echo "$opt=$val"
  done
  for up in $(uci -q show travelmate | sed -n "s/^travelmate\.\([^.=]*\)=uplink$/\1/p"); do
    device="$(uci -q get travelmate."$up".device || true)"
    ssid="$(uci -q get travelmate."$up".ssid || true)"
    enabled="$(uci -q get travelmate."$up".enabled || echo 1)"
    echo "uplink=$up device=$device ssid=$ssid enabled=$enabled"
  done
fi
echo "travelmate_end"
REMOTE_SH
