#!/usr/bin/env bash
# Read-only, secret-safe inventory before removing 192.168.1.0/24 compatibility.

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
    *) echo "audit-lan99-cleanup: unknown arg: $1" >&2; exit 13 ;;
  esac
done

resolve_router_config "$router"

ssh_run_remote <<'SH'
set -eu

echo '[lan-addresses]'
ip -4 address show dev br-lan | sed -n '/inet /p' || true
echo '[lan-routes]'
ip -4 route show | grep -E '(^default|192\.168\.(1|99)\.0/24)' || true
echo '[lan-neighbors]'
ip -4 neigh show dev br-lan | grep -E '^192\.168\.(1|99)\.' | sort || true
echo '[dhcp-leases]'
awk '$3 ~ /^192\.168\.(1|99)\./ {print $2, $3, $4}' /tmp/dhcp.leases 2>/dev/null | sort || true

echo '[wifi-clients]'
for object in $(ubus list 'hostapd.*' 2>/dev/null); do
  ubus call "$object" get_clients 2>/dev/null \
    | jq -c --arg object "$object" '.clients | to_entries[]? | {radio:$object,mac:.key,signal:(.value.signal // null),authorized:(.value.authorized // null)}' \
    || true
done

echo '[uci-legacy-references]'
for cfg in network dhcp firewall; do
  uci -q show "$cfg" | grep '192\.168\.1\.' || true
done

echo '[sing-box-legacy-inbounds]'
jq -c '[.inbounds[] | select(.listen == "192.168.1.1") | {tag,type,listen,listen_port}]' \
  /etc/sing-box/config.json
echo '[sing-box-legacy-source-rules]'
jq -c '[.route.rules[] | select(((.source_ip // []) + (.source_ip_cidr // [])) | any(startswith("192.168.1."))) | {source_ip,source_ip_cidr,outbound}]' \
  /etc/sing-box/config.json

echo '[tproxy-legacy-lines]'
grep -n '192\.168\.1\.' /etc/init.d/sing-box-tproxy 2>/dev/null || true
echo '[runtime-nft-legacy-lines]'
nft -a list ruleset 2>/dev/null | grep '192\.168\.1\.' || true

echo '[other-known-legacy-files]'
for path in \
  /etc/dnsmasq.conf \
  /etc/vpn-kit/dnsmasq-additions.conf \
  /etc/vpn-kit/install-state.json \
  /etc/crontabs/root \
  /etc/router-watchdog.conf; do
  [ -f "$path" ] || continue
  if grep -q '192\.168\.1\.' "$path" 2>/dev/null; then
    printf 'file=%s\n' "$path"
  fi
done

echo '[install-state-legacy-values]'
if [ -f /etc/vpn-kit/install-state.json ]; then
  jq -c '[paths(scalars) as $path
    | (getpath($path) | tostring) as $value
    | select($value | contains("192.168.1."))
    | {path:$path,value:$value}]' /etc/vpn-kit/install-state.json
  jq -c '{proxy_ports:[(.proxy_ports // [])[] | {port,listen,outbound}],
    lan_dynamic_additions:[(.dynamic_additions // [])[]
      | select((.value // "") | startswith("192.168.1.") or startswith("192.168.99."))
      | {kind,value,tag,comment}]}' /etc/vpn-kit/install-state.json
fi
for path in /usr/bin/*watchdog* /usr/sbin/*watchdog*; do
  [ -f "$path" ] || continue
  if grep -q '192\.168\.1\.' "$path" 2>/dev/null; then
    printf 'file=%s\n' "$path"
  fi
done
SH
