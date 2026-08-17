#!/usr/bin/env bash
# End-to-end, secret-free verification for one configured travel router.

set -euo pipefail

router=""
ssh_alias=""
expected_lan=""
expected_ssid=""
expected_uplink=""
home_lan_cidr=""
home_lan_ip=""
require_dhcp_client=0
expected_hidden=0
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --expected-lan) expected_lan="${2:-}"; shift 2 ;;
    --expected-ssid) expected_ssid="${2:-}"; shift 2 ;;
    --expected-uplink) expected_uplink="${2:-}"; shift 2 ;;
    --home-lan-cidr) home_lan_cidr="${2:-}"; shift 2 ;;
    --home-lan-ip) home_lan_ip="${2:-}"; shift 2 ;;
    --require-dhcp-client) require_dhcp_client=1; shift ;;
    --expected-hidden) expected_hidden="${2:-}"; shift 2 ;;
    *)
      echo "Usage: bin/verify-travel-router.sh --router <alias> --ssh-alias <alias> --expected-lan <cidr> --expected-ssid <ssid> --expected-uplink <ssid> --home-lan-cidr <cidr> --home-lan-ip <ip> [--require-dhcp-client]" >&2
      exit 64
      ;;
  esac
done

[ -n "$router" ] && [ -n "$ssh_alias" ] && [ -n "$expected_lan" ] && \
  [ -n "$expected_ssid" ] && [ -n "$expected_uplink" ] && \
  [ -n "$home_lan_cidr" ] && [ -n "$home_lan_ip" ] || exit 64
[[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
[[ "$expected_lan" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/24$ ]] || exit 13
[[ "$home_lan_cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/24$ ]] || exit 13
[[ "$home_lan_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || exit 13
[[ "$expected_hidden" =~ ^[01]$ ]] || exit 13

expected_ssid_hex="$(printf '%s' "$expected_ssid" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
expected_uplink_hex="$(printf '%s' "$expected_uplink" | LC_ALL=C od -An -tx1 | tr -d ' \n')"

ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 \
  "$ssh_alias" \
  "sh -s -- '$expected_lan' '$expected_ssid_hex' '$expected_uplink_hex' '$home_lan_cidr' '$home_lan_ip' '$require_dhcp_client' '$expected_hidden'" <<'REMOTE_SH'
set -eu
expected_lan="$1"
expected_ssid_hex="$2"
expected_uplink_hex="$3"
home_lan_cidr="$4"
home_lan_ip="$5"
require_dhcp_client="$6"
expected_hidden="$7"

hex_decode() {
  hex="$1"
  while [ -n "$hex" ]; do
    byte="$(printf '%.2s' "$hex")"
    hex="${hex#??}"
    printf "\\x$byte"
  done
}
expected_ssid="$(hex_decode "$expected_ssid_hex")"
expected_uplink="$(hex_decode "$expected_uplink_hex")"
lan_ip="${expected_lan%/*}"
lan_prefix="${lan_ip%.*}."

[ "$(uci -q get network.lan.ipaddr)" = "$expected_lan" ]
lan_runtime="$(ubus call network.interface.lan status | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null || true)"
[ "$lan_runtime" = "$lan_ip" ]
echo "lan_address=ok"

configured_ap_count=0
for ap in travel_ap_24 travel_ap_5; do
  [ "$(uci -q get wireless."$ap".mode)" = ap ]
  [ "$(uci -q get wireless."$ap".network)" = lan ]
  [ "$(uci -q get wireless."$ap".ssid)" = "$expected_ssid" ]
  [ "$(uci -q get wireless."$ap".encryption)" = psk2 ]
  [ "$(uci -q get wireless."$ap".disabled)" = 0 ]
  [ "$(uci -q get wireless."$ap".hidden)" = "$expected_hidden" ]
  configured_ap_count=$((configured_ap_count + 1))
done
[ "$configured_ap_count" = 2 ]
active_ap_count="$(iwinfo 2>/dev/null | grep -F -c "ESSID: \"$expected_ssid\"" || true)"
[ "$active_ap_count" -ge 2 ]
echo "private_ap_configured=ok"
echo "private_ap_active_radios=$active_ap_count"
echo "private_ap_hidden=$expected_hidden"

[ "$(uci -q get travelmate.global.trm_enabled)" = 1 ]
[ "$(uci -q get travelmate.global.trm_iface)" = wwan ]
[ "$(uci -q get travelmate.global.trm_laniface)" = lan ]
[ "$(uci -q get travelmate.global.trm_captive)" = 1 ]
[ "$(uci -q get travelmate.global.trm_netcheck)" = 0 ]
[ "$(uci -q get travelmate.global.trm_autoadd)" = 0 ]
[ "$(uci -q get travelmate.global.trm_maxretry)" = 0 ]
[ "$(uci -q get travelmate.global.trm_vpn)" = 0 ]
saved_uplink_ok=false
for uplink in $(uci -q show travelmate | sed -n "s/^travelmate\.\([^.=]*\)=uplink$/\1/p"); do
  [ "$(uci -q get travelmate."$uplink".ssid || true)" = "$expected_uplink" ] && saved_uplink_ok=true
done
[ "$saved_uplink_ok" = true ]
/etc/init.d/travelmate enabled >/dev/null 2>&1
/etc/init.d/travelmate running >/dev/null 2>&1
echo "travelmate=ok"
echo "travelmate_autoadd=false"

wwan_up="$(ubus call network.interface.wwan status | jsonfilter -e '@.up' 2>/dev/null || echo false)"
awg_up="$(ubus call network.interface.awg1 status | jsonfilter -e '@.up' 2>/dev/null || echo false)"
[ "$wwan_up" = true ] && [ "$awg_up" = true ]
default_route="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1)"
home_route="$(ip -4 route get "$home_lan_ip" 2>/dev/null | head -n 1)"
printf '%s' "$default_route" | grep -q 'phy.*-sta'
printf '%s' "$home_route" | grep -q 'awg1'
awg show awg1 allowed-ips 2>/dev/null | grep -Fq "$home_lan_cidr"
echo "split_routing=ok"

ping -c 2 -W 2 1.1.1.1 >/dev/null
nslookup openwrt.org >/dev/null 2>&1
echo "internet_ipv4=ok"
echo "dns_resolution=ok"

site_ping_ok=true
for size in 16 512 1200; do
  if ping -I "$lan_ip" -c 2 -W 2 -s "$size" "$home_lan_ip" >/dev/null 2>&1; then
    echo "home_lan_ping_${size}=ok"
  else
    echo "home_lan_ping_${size}=failed"
    site_ping_ok=false
  fi
done
[ "$site_ping_ok" = true ]

lan_to_awg=false
awg_to_lan=false
for fwd in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
  src="$(uci -q get firewall."$fwd".src || true)"
  dest="$(uci -q get firewall."$fwd".dest || true)"
  [ "$src:$dest" = lan:awg2_home ] && lan_to_awg=true
  [ "$src:$dest" = awg2_home:lan ] && awg_to_lan=true
done
[ "$lan_to_awg" = true ] && [ "$awg_to_lan" = true ]
wan_input="$(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='wan'$/\1/p" | head -n 1)"
[ "$(uci -q get firewall."$wan_input".input)" = REJECT ]
echo "firewall_site_to_site=ok"
echo "wan_management_blocked=ok"

http_code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "https://$lan_ip/cgi-bin/luci/" || true)"
case "$http_code" in 200|301|302|403) ;; *) echo "luci_http_code=$http_code"; exit 1 ;; esac
echo "luci_https=ok"

dhcp_client_count="$(awk -v p="$lan_prefix" 'index($3, p) == 1 {count++} END {print count+0}' /tmp/dhcp.leases 2>/dev/null || echo 0)"
echo "dhcp_client_count=$dhcp_client_count"
if [ "$require_dhcp_client" = 1 ]; then
  [ "$dhcp_client_count" -ge 1 ]
fi

echo "travel_router_verification=ok"
REMOTE_SH
