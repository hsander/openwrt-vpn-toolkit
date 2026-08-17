#!/usr/bin/env bash
# Persist and live-add one peer to an existing home AWG2 interface without
# restarting network or the interface.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"
. "$SKILL_HOME/lib/router-config.sh"
. "$SKILL_HOME/lib/ssh-runner.sh"
. "$SKILL_HOME/lib/memory-journal.sh"

router=""; peer_public_key=""; peer_ip=""; section=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --peer-public-key) peer_public_key="${2:-}"; shift 2 ;;
    --peer-ip) peer_ip="${2:-}"; shift 2 ;;
    --section) section="${2:-}"; shift 2 ;;
    *) echo "Usage: bin/add-awg2-home-peer.sh --router home --peer-public-key <key> --peer-ip 10.67.0.X --section <name>" >&2; exit 64 ;;
  esac
done
[[ "$peer_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || exit 13
[[ "$peer_ip" =~ ^10\.67\.0\.([0-9]{1,3})$ ]] || exit 13
peer_octet="${BASH_REMATCH[1]}"
(( peer_octet >= 2 && peer_octet <= 254 )) || exit 13
[[ "$section" =~ ^[a-zA-Z0-9_]{1,32}$ ]] || exit 13

resolve_router_config "$router"
ssh_check_alive 5 || exit 2
snapshot_id="$($SCRIPT_DIR/backup-now.sh --router "$router" --label "before awg2 peer" --quiet)"

set +e
result="$(ssh_run_remote_with_args /dev/stdin "$peer_public_key" "$peer_ip" "$section" <<'REMOTE_SH'
set -eu
peer_public_key="$1"; peer_ip="$2"; section="$3"
backup="$(mktemp /tmp/network.before-awg2-peer.XXXXXX)"
cp /etc/config/network "$backup"
chmod 600 "$backup"
success=0

rollback() {
  [ "$success" = 1 ] && return 0
  cp "$backup" /etc/config/network
  awg set awg1 peer "$peer_public_key" remove >/dev/null 2>&1 || true
}
cleanup() { rollback; rm -f "$backup"; unset peer_public_key; }
trap cleanup EXIT INT TERM

ip link show awg1 >/dev/null
awg showconf awg1 | grep -q '^S3 = 40$'
awg showconf awg1 | grep -q '^S4 = 100$'
awg showconf awg1 | grep -q '^I1 = '

uci -q show network | grep -F ".allowed_ips='$peer_ip/32'" >/dev/null 2>&1 && {
  echo "peer IP is already present" >&2; exit 13;
}
awg show awg1 peers | grep -Fx "$peer_public_key" >/dev/null 2>&1 && {
  echo "peer public key is already present" >&2; exit 13;
}

zone_ok=0
for z in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=zone$/\1/p"); do
  uci -q get firewall."$z".network | tr ' ' '\n' | grep -qx awg1 && zone_ok=1
done
[ "$zone_ok" = 1 ]
rule_ok=0
for r in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=rule$/\1/p"); do
  [ "$(uci -q get firewall."$r".dest_port || true)" = 51821 ] || continue
  [ "$(uci -q get firewall."$r".proto || true)" = udp ] || continue
  [ "$(uci -q get firewall."$r".target || true)" = ACCEPT ] || continue
  rule_ok=1
done
[ "$rule_ok" = 1 ]

uci -q delete network."$section" || true
uci set network."$section"=amneziawg_awg1
uci set network."$section".public_key="$peer_public_key"
uci add_list network."$section".allowed_ips="$peer_ip/32"
uci set network."$section".route_allowed_ips='0'
uci commit network

awg set awg1 peer "$peer_public_key" allowed-ips "$peer_ip/32"
awg show awg1 peers | grep -Fx "$peer_public_key" >/dev/null
awg show awg1 allowed-ips | grep -F "$peer_ip/32" >/dev/null

success=1
echo "home_peer=added"
echo "interface=awg1"
echo "peer_ip=$peer_ip"
unset peer_public_key
REMOTE_SH
)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$result" >&2
  echo "add-awg2-home-peer: failed and restored (snapshot=$snapshot_id)" >&2
  exit 20
fi

printf '%s\n' "$result"
memory_journal_append "$router" "awg2_home_peer_added"
