#!/usr/bin/env bash
# Secret-free health proof for an OpenWrt backup AWG link and route watchdog.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"
. "$SKILL_HOME/lib/router-config.sh"
. "$SKILL_HOME/lib/ssh-runner.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/verify-resilient-awg.sh --router <alias> [--ssh-alias <alias>]
  --interface <name> --local-ip <ip> --peer-ip <ip> --target-cidr <cidr>
  --expected-route-interface <name> [--require-watchdog]
EOF
  exit 64
}

router=""; ssh_alias=""; interface=""; local_ip=""; peer_ip=""
target_cidr=""; expected_route_interface=""; require_watchdog=0
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --interface) interface="${2:-}"; shift 2 ;;
    --local-ip) local_ip="${2:-}"; shift 2 ;;
    --peer-ip) peer_ip="${2:-}"; shift 2 ;;
    --target-cidr) target_cidr="${2:-}"; shift 2 ;;
    --expected-route-interface) expected_route_interface="${2:-}"; shift 2 ;;
    --require-watchdog) require_watchdog=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$router" ] && [ -n "$interface" ] && [ -n "$local_ip" ] && [ -n "$peer_ip" ] && \
  [ -n "$target_cidr" ] && [ -n "$expected_route_interface" ] || usage
for name in "$interface" "$expected_route_interface"; do [[ "$name" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || exit 13; done
for address in "$local_ip" "$peer_ip"; do [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 13; done
[[ "$target_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] || exit 13
if [ -n "$ssh_alias" ]; then [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13; fi

resolve_router_config "$router"
if [ -n "$ssh_alias" ]; then ROUTER_SSH_ALIAS="$ssh_alias"; export ROUTER_SSH_ALIAS; fi
ssh_check_alive 5 || exit 2

ssh_run_remote_with_args /dev/stdin "$interface" "$local_ip" "$peer_ip" "$target_cidr" \
  "$expected_route_interface" "$require_watchdog" <<'REMOTE_SH'
set -eu
interface="$1"; local_ip="$2"; peer_ip="$3"; target_cidr="$4"
expected_route_interface="$5"; require_watchdog="$6"
command -v awg >/dev/null
ip link show dev "$interface" >/dev/null
ip -4 address show dev "$interface" | grep -Fq "inet $local_ip/"

ping_ok=true
for size in 16 512 1200; do
  if ping -I "$interface" -c 2 -W 2 -s "$size" "$peer_ip" >/dev/null 2>&1; then
    echo "backup_ping_${size}=ok"
  else
    echo "backup_ping_${size}=failed"
    ping_ok=false
  fi
done

peer_key="$(awg show "$interface" latest-handshakes | awk '$2 > 0 { print $1; exit }')"
[ -n "$peer_key" ]
handshake="$(awg show "$interface" latest-handshakes | awk -v key="$peer_key" '$1 == key { print $2; exit }')"
now="$(date +%s)"
age=$((now - handshake))
echo "backup_handshake_age_seconds=$age"
[ "$age" -ge 0 ] && [ "$age" -le 180 ]
[ "$ping_ok" = true ]

route_interface="$(ip -4 route show "$target_cidr" | awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')"
echo "target_route_interface=$route_interface"
[ "$route_interface" = "$expected_route_interface" ]
if ip -4 route show default | grep -Fq "dev $interface"; then
  echo "default_route_uses_backup=true"
  exit 1
fi
echo "default_route_uses_backup=false"

if [ "$require_watchdog" = 1 ]; then
  /etc/init.d/resilient-awg-failover enabled
  /etc/init.d/resilient-awg-failover running
  grep -Fq "TARGET_CIDR='$target_cidr'" /etc/resilient-awg-failover.d/*.conf
  echo "watchdog=running"
fi

free_kb="$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo)"
echo "free_kb=$free_kb"
[ "${free_kb:-0}" -ge 20480 ]
ping -c 2 -W 2 1.1.1.1 >/dev/null
nslookup openwrt.org >/dev/null
echo "internet=ok"
echo "dns=ok"
echo "resilient_awg=ok"
REMOTE_SH
