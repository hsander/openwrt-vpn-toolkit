#!/usr/bin/env bash
# Verify one AmneziaWG peer without exposing key material.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"

usage() {
  echo "Usage: bin/verify-awg2-link.sh --router <alias> [--ssh-alias <alias>] --interface <name> --local-ip <ip> --peer-ip <ip> --peer-allowed <cidr>" >&2
  exit 64
}

router=""
ssh_alias_override=""
interface=""
local_ip=""
peer_ip=""
peer_allowed=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias_override="${2:-}"; shift 2 ;;
    --interface) interface="${2:-}"; shift 2 ;;
    --local-ip) local_ip="${2:-}"; shift 2 ;;
    --peer-ip) peer_ip="${2:-}"; shift 2 ;;
    --peer-allowed) peer_allowed="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "verify-awg2-link: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$router" ] && [ -n "$interface" ] && [ -n "$local_ip" ] && \
  [ -n "$peer_ip" ] && [ -n "$peer_allowed" ] || usage
[[ "$interface" =~ ^[A-Za-z0-9_.-]+$ ]] || exit 13
for address in "$local_ip" "$peer_ip"; do
  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 13
done
[[ "$peer_allowed" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] || exit 13
if [ -n "$ssh_alias_override" ]; then
  [[ "$ssh_alias_override" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
fi

resolve_router_config "$router"
if [ -n "$ssh_alias_override" ]; then
  ROUTER_SSH_ALIAS="$ssh_alias_override"
  export ROUTER_SSH_ALIAS
fi
ssh_check_alive 5 || {
  echo "verify-awg2-link: SSH unavailable for $ROUTER_ALIAS" >&2
  exit 2
}

ssh_run_remote_with_args /dev/stdin "$interface" "$local_ip" "$peer_ip" "$peer_allowed" <<'REMOTE_SH'
set -eu
interface="$1"
local_ip="$2"
peer_ip="$3"
peer_allowed="$4"

command -v awg >/dev/null 2>&1 || {
  echo "awg_present=false"
  exit 1
}

if ! ip link show dev "$interface" >/dev/null 2>&1; then
  echo "interface_up=false"
  exit 1
fi
echo "interface_up=true"

if ip -4 address show dev "$interface" | grep -Fq "inet $local_ip/"; then
  echo "local_address_ok=true"
else
  echo "local_address_ok=false"
  exit 1
fi

peer_key="$(awg show "$interface" allowed-ips 2>/dev/null | awk -v target="$peer_allowed" '
  {
    key=$1
    for (i=2; i<=NF; i++) {
      count=split($i, allowed, ",")
      for (j=1; j<=count; j++) {
        if (allowed[j] == target) { print key; exit }
      }
    }
  }
')"
if [ -z "$peer_key" ]; then
  echo "peer_configured=false"
  exit 1
fi
echo "peer_configured=true"

handshake="$(awg show "$interface" latest-handshakes 2>/dev/null | awk -v key="$peer_key" '$1 == key { print $2; exit }')"
rx_bytes="$(awg show "$interface" transfer 2>/dev/null | awk -v key="$peer_key" '$1 == key { print $2; exit }')"
tx_bytes="$(awg show "$interface" transfer 2>/dev/null | awk -v key="$peer_key" '$1 == key { print $3; exit }')"
now="$(date +%s)"
case "$handshake" in
  ''|*[!0-9]*) handshake=0 ;;
esac
if [ "$handshake" -gt 0 ]; then
  handshake_age=$((now - handshake))
else
  handshake_age=-1
fi
echo "latest_handshake_epoch=$handshake"
echo "latest_handshake_age_seconds=$handshake_age"
echo "rx_bytes=${rx_bytes:-0}"
echo "tx_bytes=${tx_bytes:-0}"

ping_ok=true
for size in 16 512 1200; do
  if ping -I "$interface" -c 2 -W 2 -s "$size" "$peer_ip" >/dev/null 2>&1; then
    echo "ping_${size}=ok"
  else
    echo "ping_${size}=failed"
    ping_ok=false
  fi
done

ssh_banner="$(nc -w 3 "$peer_ip" 22 </dev/null 2>/dev/null | head -n 1 || true)"
if printf '%s' "$ssh_banner" | grep -q '^SSH-'; then
  echo "router_nc_ssh_banner=received"
else
  # Some BusyBox nc builds close before yielding the SSH banner. This probe is
  # informational; verify-ssh-endpoint.sh provides the authoritative login test.
  echo "router_nc_ssh_banner=not_received"
fi

if [ "$handshake_age" -lt 0 ] || [ "$handshake_age" -gt 180 ]; then
  echo "fresh_handshake=false"
  exit 1
fi
echo "fresh_handshake=true"
[ "$ping_ok" = true ]
REMOTE_SH
