#!/bin/sh
# detect-lan.sh — derive LAN listen interfaces, zones and subnets from UCI/ip.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LIB_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/vpn-kit-common.sh
. "$LIB_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

if ! command -v uci >/dev/null 2>&1; then
  jq -n '{zones:[], lan_ifaces:[], lan_subnets:[], listen_candidates:[], warnings:["uci not found"]}'
  exit 0
fi

zones_tmp="$(mktemp -t vpnkit-zones.XXXXXX)"
trap 'rm -f "$zones_tmp"' EXIT INT TERM

uci -q show firewall 2>/dev/null | awk -F'[.=]' '
  $3 == "name" {
    section=$2
    name=$4
    gsub(/\047/, "", name)
    zone[section]=name
  }
  $3 == "network" {
    section=$2
    value=$4
    gsub(/\047/, "", value)
    net[section]=value
  }
  END {
    for (s in zone) {
      printf "%s\t%s\n", zone[s], net[s]
    }
  }
' > "$zones_tmp"

zones_json='[]'
while IFS="$(printf '\t')" read -r zone networks; do
  [ -n "$zone" ] || continue
  networks_json="$(printf '%s\n' "$networks" | tr ' ' '\n' | jq -R -s 'split("\n") | map(select(length > 0))')"
  zones_json="$(printf '%s' "$zones_json" | jq --arg name "$zone" --argjson networks "$networks_json" '. + [{name:$name, networks:$networks}]')"
done < "$zones_tmp"

lan_ifaces='[]'
for net in lan; do
  ifname="$(uci -q get "network.$net.device" 2>/dev/null || uci -q get "network.$net.ifname" 2>/dev/null || true)"
  [ -n "$ifname" ] || ifname="$net"
  lan_ifaces="$(printf '%s' "$lan_ifaces" | jq --arg net "$net" --arg iface "$ifname" '. + [{network:$net, iface:$iface}]')"
done

lan_subnets='[]'
lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
lan_mask="$(uci -q get network.lan.netmask 2>/dev/null || true)"
if [ -n "$lan_ip" ]; then
  cidr="$lan_ip"
  case "$lan_mask" in
    255.255.255.0) cidr="$lan_ip/24" ;;
    255.255.0.0) cidr="$lan_ip/16" ;;
    255.0.0.0) cidr="$lan_ip/8" ;;
    255.255.255.128) cidr="$lan_ip/25" ;;
    255.255.255.192) cidr="$lan_ip/26" ;;
  esac
  lan_subnets="$(printf '%s' "$lan_subnets" | jq --arg cidr "$cidr" '. + [$cidr]')"
fi

listen_candidates='[]'
if command -v ip >/dev/null 2>&1; then
  for iface in $(printf '%s' "$lan_ifaces" | jq -r '.[].iface'); do
    addrs="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | jq -R -s 'split("\n") | map(select(length > 0))')"
    listen_candidates="$(printf '%s' "$listen_candidates" | jq --arg iface "$iface" --argjson addrs "$addrs" '. + [{iface:$iface, addresses:$addrs}]')"
  done
fi

jq -n \
  --argjson zones "$zones_json" \
  --argjson lan_ifaces "$lan_ifaces" \
  --argjson lan_subnets "$lan_subnets" \
  --argjson listen_candidates "$listen_candidates" \
  '{zones:$zones, lan_ifaces:$lan_ifaces, lan_subnets:$lan_subnets, listen_candidates:$listen_candidates, warnings:[]}'
