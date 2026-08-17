#!/usr/bin/env bash
# Add one travel LAN behind an existing AWG peer on the home router.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/configure-home-travel-route.sh --router home \
  [--ssh-alias <alias>] \
  --interface awg1 --peer-section <uci-section> \
  --travel-subnet <cidr> --route-section <uci-section> \
  --client-tunnel-ip <ip> --home-lan-ip <ip>
EOF
  exit 64
}

router=""
ssh_alias_override=""
interface=""
peer_section=""
travel_subnet=""
route_section=""
client_tunnel_ip=""
home_lan_ip=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias_override="${2:-}"; shift 2 ;;
    --interface) interface="${2:-}"; shift 2 ;;
    --peer-section) peer_section="${2:-}"; shift 2 ;;
    --travel-subnet) travel_subnet="${2:-}"; shift 2 ;;
    --route-section) route_section="${2:-}"; shift 2 ;;
    --client-tunnel-ip) client_tunnel_ip="${2:-}"; shift 2 ;;
    --home-lan-ip) home_lan_ip="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$router" ] && [ -n "$interface" ] && [ -n "$peer_section" ] && \
  [ -n "$travel_subnet" ] && [ -n "$route_section" ] && \
  [ -n "$client_tunnel_ip" ] && [ -n "$home_lan_ip" ] || usage
for name in "$interface" "$peer_section" "$route_section"; do
  [[ "$name" =~ ^[A-Za-z0-9_]{1,64}$ ]] || exit 13
done
[[ "$travel_subnet" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/24$ ]] || exit 13
[[ "$client_tunnel_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || exit 13
[[ "$home_lan_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || exit 13
if [ -n "$ssh_alias_override" ]; then
  [[ "$ssh_alias_override" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
fi

resolve_router_config "$router"
if [ -n "$ssh_alias_override" ]; then
  ROUTER_SSH_ALIAS="$ssh_alias_override"
  export ROUTER_SSH_ALIAS
fi
ssh_check_alive 5 || exit 2
backup_args=(--router "$router" --label "before home travel route" --quiet)
[ -z "$ssh_alias_override" ] || backup_args+=(--ssh-alias "$ssh_alias_override")
snapshot_id="$($SCRIPT_DIR/backup-now.sh "${backup_args[@]}")"

set +e
ssh_run_remote_with_args /dev/stdin \
  "$interface" "$peer_section" "$travel_subnet" "$route_section" \
  "$client_tunnel_ip" "$home_lan_ip" <<'REMOTE_SH'
set -eu
interface="$1"
peer_section="$2"
travel_subnet="$3"
route_section="$4"
client_tunnel_ip="$5"
home_lan_ip="$6"

uci -q get network."$interface" >/dev/null
uci -q get network."$peer_section" >/dev/null
command -v awg >/dev/null 2>&1
vpn_zone="$(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='vpn'$/\1/p" | head -n 1)"
[ -n "$vpn_zone" ]

before="$(mktemp -d /tmp/home-travel-route.XXXXXX)"
cp /etc/config/network "$before/network"
chmod 600 "$before/network"
peer_public_key="$(uci -q get network."$peer_section".public_key)"
old_allowed_csv="$(uci -q get network."$peer_section".allowed_ips | tr ' ' ',')"
[ -n "$peer_public_key" ] && [ -n "$old_allowed_csv" ]
old_route="$(ip -4 route show "$travel_subnet" 2>/dev/null || true)"
case "$old_route" in
  "") had_old_route=0 ;;
  *" dev $interface"*) had_old_route=1 ;;
  *) echo "unexpected_existing_route=$old_route" >&2; exit 13 ;;
esac
success=0
rollback() {
  [ "$success" = 1 ] && return 0
  cp "$before/network" /etc/config/network
  awg set "$interface" peer "$peer_public_key" allowed-ips "$old_allowed_csv" >/dev/null 2>&1 || true
  if [ "$had_old_route" = 1 ]; then
    ip -4 route replace "$travel_subnet" dev "$interface" >/dev/null 2>&1 || true
  else
    ip -4 route del "$travel_subnet" dev "$interface" >/dev/null 2>&1 || true
  fi
}
cleanup() { rollback; rm -rf "$before"; }
trap cleanup EXIT

uci -q del_list network."$peer_section".allowed_ips="$travel_subnet" || true
uci add_list network."$peer_section".allowed_ips="$travel_subnet"
uci set network."$peer_section".route_allowed_ips='0'
uci -q delete network."$route_section" || true
uci set network."$route_section"='route'
uci set network."$route_section".interface="$interface"
uci set network."$route_section".target="$travel_subnet"
uci commit network

new_allowed_csv="$(uci -q get network."$peer_section".allowed_ips | tr ' ' ',')"
awg set "$interface" peer "$peer_public_key" allowed-ips "$new_allowed_csv"
ip -4 route replace "$travel_subnet" dev "$interface"

ok=0
attempt=0
route_ok=false
allowed_ok=false
client_ping_ok=false
travel_ping_ok=false
while [ "$attempt" -lt 30 ]; do
  attempt=$((attempt + 1))
  route="$(ip -4 route get "${travel_subnet%/*}" 2>/dev/null || true)"
  printf '%s' "$route" | grep -q "dev $interface" && route_ok=true || route_ok=false
  awg show "$interface" allowed-ips 2>/dev/null | grep -Fq "$travel_subnet" && allowed_ok=true || allowed_ok=false
  ping -c 1 -W 2 "$client_tunnel_ip" >/dev/null 2>&1 && client_ping_ok=true || client_ping_ok=false
  ping -I "$home_lan_ip" -c 1 -W 2 "${travel_subnet%.*}.1" >/dev/null 2>&1 && travel_ping_ok=true || travel_ping_ok=false
  if [ "$route_ok" = true ] && [ "$allowed_ok" = true ] && \
     [ "$client_ping_ok" = true ] && [ "$travel_ping_ok" = true ]; then
    ok=1
    break
  fi
  sleep 2
done
[ "$ok" = 1 ] || {
  echo "route_ok=$route_ok" >&2
  echo "allowed_ok=$allowed_ok" >&2
  echo "client_tunnel_ping_ok=$client_ping_ok" >&2
  echo "home_lan_to_travel_router_ping_ok=$travel_ping_ok" >&2
  exit 1
}

wan_ip="$(ubus call network.interface.wan status | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null || true)"
[ -n "$wan_ip" ]
ping -c 1 -W 2 "$home_lan_ip" >/dev/null 2>&1

success=1
echo "home_travel_route=applied"
echo "interface=$interface"
echo "peer_section=$peer_section"
echo "travel_subnet=$travel_subnet"
echo "route_runtime=ok"
echo "client_tunnel_ping=ok"
echo "home_lan_to_travel_router_ping=ok"
echo "wan_ipv4=$wan_ip"
REMOTE_SH
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "configure-home-travel-route: apply failed and network config was restored (snapshot=$snapshot_id)" >&2
  exit 20
fi

echo "snapshot=$snapshot_id"
memory_journal_append "$router" "home_travel_route_configured"
