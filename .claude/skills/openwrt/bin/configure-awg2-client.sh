#!/usr/bin/env bash
# Configure SmartBox as an AWG2 client of home.awg1. The private key is
# generated on the router and never leaves it. Prints only the public key.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"
. "$SKILL_HOME/lib/router-config.sh"
. "$SKILL_HOME/lib/ssh-runner.sh"
. "$SKILL_HOME/lib/memory-journal.sh"

router=""; endpoint=""; server_public_key=""; tunnel_ip="10.67.0.3"
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --endpoint) endpoint="${2:-}"; shift 2 ;;
    --server-public-key) server_public_key="${2:-}"; shift 2 ;;
    --tunnel-ip) tunnel_ip="${2:-}"; shift 2 ;;
    *) echo "Usage: bin/configure-awg2-client.sh --router <alias> --endpoint <IPv4> --server-public-key <key> [--tunnel-ip 10.67.0.3]" >&2; exit 64 ;;
  esac
done
[[ "$endpoint" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 13
[[ "$tunnel_ip" =~ ^10\.67\.0\.([0-9]{1,3})$ ]] || exit 13
tunnel_octet="${BASH_REMATCH[1]}"
(( tunnel_octet >= 2 && tunnel_octet <= 254 )) || exit 13
[[ "$server_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || exit 13

resolve_router_config "$router"
ssh_check_alive 5 || exit 2
snapshot_id="$($SCRIPT_DIR/backup-now.sh --router "$router" --label "before awg2 client" --quiet)"

set +e
result="$(ssh_run_remote_with_args /dev/stdin "$endpoint" "$server_public_key" "$tunnel_ip" <<'REMOTE_SH'
set -eu
endpoint="$1"; server_public_key="$2"; tunnel_ip="$3"
backup_dir="$(mktemp -d /tmp/skill-awg2-client.XXXXXX)"
success=0
private_key=""
public_key=""

cp /etc/config/network "$backup_dir/network"
cp /etc/config/firewall "$backup_dir/firewall"
chmod 600 "$backup_dir"/*

rollback() {
  [ "$success" = 1 ] && return 0
  ifdown awg1 >/dev/null 2>&1 || true
  cp "$backup_dir/network" /etc/config/network
  cp "$backup_dir/firewall" /etc/config/firewall
  ubus call network reload >/dev/null 2>&1 || true
  fw4 reload >/dev/null 2>&1 || true
}
cleanup() { rollback; rm -rf "$backup_dir"; unset private_key public_key server_public_key; }
trap cleanup EXIT INT TERM

command -v awg >/dev/null
modprobe amneziawg
test -d /sys/module/amneziawg
proto=/lib/netifd/proto/amneziawg.sh
grep -q awg_s3 "$proto" && grep -q awg_s4 "$proto" && grep -q awg_i1 "$proto"
ubus call network.interface.wwan status | jsonfilter -e '@.up' | grep -qx true

private_key="$(awg genkey)"
public_key="$(printf '%s' "$private_key" | awg pubkey)"

uci -q delete network.home_peer_awg2 || true
uci -q delete network.awg1 || true
uci set network.awg1=interface
uci set network.awg1.proto='amneziawg'
uci set network.awg1.private_key="$private_key"
uci add_list network.awg1.addresses="$tunnel_ip/24"
uci set network.awg1.mtu='1360'
uci set network.awg1.awg_jc='4'
uci set network.awg1.awg_jmin='40'
uci set network.awg1.awg_jmax='70'
uci set network.awg1.awg_s1='42'
uci set network.awg1.awg_s2='16'
uci set network.awg1.awg_s3='40'
uci set network.awg1.awg_s4='100'
uci set network.awg1.awg_h1='65236728'
uci set network.awg1.awg_h2='2314199929'
uci set network.awg1.awg_h3='830645635'
uci set network.awg1.awg_h4='380976151'
uci set network.awg1.awg_i1='<b 0x1a2d0100000100000000000109696e666572656e6365><t><r 15>'

uci set network.home_peer_awg2=amneziawg_awg1
uci set network.home_peer_awg2.public_key="$server_public_key"
uci set network.home_peer_awg2.endpoint_host="$endpoint"
uci set network.home_peer_awg2.endpoint_port='51821'
uci add_list network.home_peer_awg2.allowed_ips='10.67.0.0/24'
uci set network.home_peer_awg2.route_allowed_ips='0'
uci set network.home_peer_awg2.persistent_keepalive='25'

zone="$(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='awg2_home'$/\1/p" | head -1)"
if [ -z "$zone" ]; then
  zone="$(uci add firewall zone)"
fi
uci set firewall."$zone".name='awg2_home'
uci set firewall."$zone".input='ACCEPT'
uci set firewall."$zone".output='ACCEPT'
uci set firewall."$zone".forward='REJECT'
uci set firewall."$zone".family='ipv4'
uci -q del_list firewall."$zone".network='awg1' || true
uci add_list firewall."$zone".network='awg1'

uci commit network
uci commit firewall
ubus call network reload >/dev/null
sleep 2
ifup awg1
fw4 reload

attempt=0
while [ "$attempt" -lt 30 ]; do
  attempt=$((attempt + 1))
  ip link show awg1 >/dev/null 2>&1 && break
  sleep 1
done
if ! ip link show awg1 >/dev/null 2>&1; then
  ubus call network.interface.awg1 status 2>/dev/null || true
  logread 2>/dev/null | grep -Ei 'amnezia|awg1|netifd' | tail -60 | \
    sed -E 's/((private|public|preshared)[_-]?key[=:])[A-Za-z0-9+\/=]+/\1<redacted>/Ig' || true
  exit 1
fi
ip -4 addr show dev awg1 | grep -F "$tunnel_ip/24" >/dev/null
params="$(awg showconf awg1 | grep -E '^(S3|S4|I1)[[:space:]]*=')"
printf '%s\n' "$params" | grep -q '^S3 = 40$'
printf '%s\n' "$params" | grep -q '^S4 = 100$'
printf '%s\n' "$params" | grep -q '^I1 = '

success=1
echo "client_public_key=$public_key"
echo "interface=awg1"
echo "tunnel_ip=$tunnel_ip"
echo "endpoint=$endpoint:51821"
unset private_key server_public_key
REMOTE_SH
)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$result" >&2
  echo "configure-awg2-client: failed and restored (snapshot=$snapshot_id)" >&2
  exit 20
fi

printf '%s\n' "$result"
memory_journal_append "$router" "awg2_client_configured"
