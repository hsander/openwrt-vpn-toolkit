#!/usr/bin/env bash
# Configure a dual-band private AP, uncommon LAN subnet, Travelmate, and the
# client-side route to the home LAN. A router-local rollback guard restores the
# previous UCI files if the SSH session dies or validation does not complete.

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
Usage: bin/configure-travel-router.sh --password-stdin \
  --router <alias> --ssh-alias <alias> --ssid <ssid> \
  --lan-cidr <x.x.x.1/24> --home-lan <cidr> \
  [--uplink-ssid <ssid>] [--peer-section home_peer_awg2]
EOF
  exit 64
}

router=""
ssh_alias=""
ssid=""
lan_cidr=""
home_lan=""
uplink_ssid="iPhoneSander"
peer_section="home_peer_awg2"
password_stdin=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --ssid) ssid="${2:-}"; shift 2 ;;
    --lan-cidr) lan_cidr="${2:-}"; shift 2 ;;
    --home-lan) home_lan="${2:-}"; shift 2 ;;
    --uplink-ssid) uplink_ssid="${2:-}"; shift 2 ;;
    --peer-section) peer_section="${2:-}"; shift 2 ;;
    --password-stdin) password_stdin=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$router" ] && [ -n "$ssh_alias" ] && [ -n "$ssid" ] && [ -n "$lan_cidr" ] && [ -n "$home_lan" ] || usage
[ "$password_stdin" = 1 ] || { echo "configure-travel-router: use --password-stdin" >&2; exit 13; }
[[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
[[ "$peer_section" =~ ^[A-Za-z0-9_]{1,64}$ ]] || exit 13
[[ "$lan_cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/24$ ]] || exit 13
[[ "$home_lan" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/24$ ]] || exit 13
[ "${#ssid}" -ge 1 ] && [ "${#ssid}" -le 32 ] || exit 13
[ "${#uplink_ssid}" -ge 1 ] && [ "${#uplink_ssid}" -le 32 ] || exit 13
if printf '%s%s' "$ssid" "$uplink_ssid" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  exit 13
fi

printf 'Private AP password: ' >&2
IFS= read -r -s password
printf '\n' >&2
[ "${#password}" -ge 12 ] && [ "${#password}" -le 63 ] || {
  echo "configure-travel-router: password must be 12..63 characters" >&2
  exit 13
}
if printf '%s' "$password" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  exit 13
fi

resolve_router_config "$router"
snapshot_id="$($SCRIPT_DIR/backup-now.sh --router "$router" --ssh-alias "$ssh_alias" --label "before travel router profile" --quiet)"

hex_encode() {
  LC_ALL=C od -An -tx1 | tr -d ' \n'
}
ssid_hex="$(printf '%s' "$ssid" | hex_encode)"
password_hex="$(printf '%s' "$password" | hex_encode)"
uplink_hex="$(printf '%s' "$uplink_ssid" | hex_encode)"
unset password

set +e
result="$(
  {
    # The reversible password encoding travels only in the encrypted stdin
    # stream. It must not appear in the local or remote SSH command line.
    printf "password_hex='%s'\n" "$password_hex"
    cat <<'REMOTE_SH'
set -eu

hex_decode() {
  hex="$1"
  while [ -n "$hex" ]; do
    byte="$(printf '%.2s' "$hex")"
    hex="${hex#??}"
    printf "\\x$byte"
  done
}

ssid="$(hex_decode "$1")"
password="$(hex_decode "$password_hex")"
lan_cidr="$2"
home_lan="$3"
peer_section="$4"
uplink_ssid="$(hex_decode "$5")"
lan_ip="${lan_cidr%/*}"

for cmd in uci ubus jsonfilter iwinfo curl fw4; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing_command=$cmd" >&2
    exit 13
  }
done
[ -x /etc/init.d/travelmate ] || exit 13
apk info -e travelmate >/dev/null 2>&1 || exit 13
apk info -e luci-app-travelmate >/dev/null 2>&1 || exit 13
uci -q get network."$peer_section" >/dev/null
uci -q get network.awg1 >/dev/null
uci -q get network.wwan >/dev/null
uci -q get wireless.radio0 >/dev/null
uci -q get wireless.radio1 >/dev/null

guard="$(mktemp -d /tmp/travel-profile-guard.XXXXXX)"
chmod 700 "$guard"
for cfg in network firewall wireless dhcp travelmate; do
  cp "/etc/config/$cfg" "$guard/$cfg"
  chmod 600 "$guard/$cfg"
done
/etc/init.d/travelmate enabled >/dev/null 2>&1 && touch "$guard/service_was_enabled" || true
/etc/init.d/travelmate running >/dev/null 2>&1 && touch "$guard/service_was_running" || true

cat >"$guard/rollback.sh" <<'ROLLBACK_SH'
#!/bin/sh
set -u
guard="$1"
interface="$2"
peer_section="$3"
sleep 240
[ -e "$guard/committed" ] && { rm -rf "$guard"; exit 0; }
for cfg in network firewall wireless dhcp travelmate; do
  [ -f "$guard/$cfg" ] && cp "$guard/$cfg" "/etc/config/$cfg"
done
/etc/init.d/travelmate stop >/dev/null 2>&1 || true
ubus call network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
wifi reload >/dev/null 2>&1 || true
/etc/init.d/firewall restart >/dev/null 2>&1 || true
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
sleep 5
if [ -e "$guard/service_was_enabled" ]; then
  /etc/init.d/travelmate enable >/dev/null 2>&1 || true
else
  /etc/init.d/travelmate disable >/dev/null 2>&1 || true
fi
if [ -e "$guard/service_was_running" ]; then
  /etc/init.d/travelmate restart >/dev/null 2>&1 || true
else
  /etc/init.d/travelmate stop >/dev/null 2>&1 || true
fi
peer_public_key="$(uci -q get network."$peer_section".public_key || true)"
old_allowed_csv="$(uci -q get network."$peer_section".allowed_ips 2>/dev/null | tr ' ' ',' || true)"
[ -n "$peer_public_key" ] && [ -n "$old_allowed_csv" ] && \
  awg set "$interface" peer "$peer_public_key" allowed-ips "$old_allowed_csv" >/dev/null 2>&1 || true
rm -rf "$guard"
ROLLBACK_SH
chmod 700 "$guard/rollback.sh"
nohup sh "$guard/rollback.sh" "$guard" awg1 "$peer_section" >"$guard/rollback.log" 2>&1 </dev/null &
guard_pid=$!
success=0

restore_now() {
  kill "$guard_pid" >/dev/null 2>&1 || true
  wait "$guard_pid" 2>/dev/null || true
  for cfg in network firewall wireless dhcp travelmate; do
    [ -f "$guard/$cfg" ] && cp "$guard/$cfg" "/etc/config/$cfg"
  done
  /etc/init.d/travelmate stop >/dev/null 2>&1 || true
  ubus call network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
  wifi reload >/dev/null 2>&1 || true
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  sleep 5
  if [ -e "$guard/service_was_enabled" ]; then
    /etc/init.d/travelmate enable >/dev/null 2>&1 || true
  else
    /etc/init.d/travelmate disable >/dev/null 2>&1 || true
  fi
  if [ -e "$guard/service_was_running" ]; then
    /etc/init.d/travelmate restart >/dev/null 2>&1 || true
  else
    /etc/init.d/travelmate stop >/dev/null 2>&1 || true
  fi
  restored_peer_public_key="$(uci -q get network."$peer_section".public_key || true)"
  restored_allowed_csv="$(uci -q get network."$peer_section".allowed_ips 2>/dev/null | tr ' ' ',' || true)"
  [ -n "$restored_peer_public_key" ] && [ -n "$restored_allowed_csv" ] && \
    awg set awg1 peer "$restored_peer_public_key" allowed-ips "$restored_allowed_csv" >/dev/null 2>&1 || true
  rm -rf "$guard"
}

on_exit() {
  [ "$success" = 1 ] || restore_now
}
on_signal() {
  restore_now
  success=1
  exit 130
}
trap on_exit EXIT
trap on_signal INT TERM HUP

wan_zone="$(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='wan'$/\1/p" | head -n 1)"
awg_zone="$(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='awg2_home'$/\1/p" | head -n 1)"
[ -n "$wan_zone" ] && [ -n "$awg_zone" ]

uci set network.lan.ipaddr="$lan_cidr"
uci -q delete network.home_lan_via_awg || true
uci set network.home_lan_via_awg='route'
uci set network.home_lan_via_awg.interface='awg1'
uci set network.home_lan_via_awg.target="$home_lan"
uci -q del_list network."$peer_section".allowed_ips="$home_lan" || true
uci add_list network."$peer_section".allowed_ips="$home_lan"
uci set network."$peer_section".route_allowed_ips='0'

uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='100'
uci set dhcp.lan.leasetime='12h'
uci set dhcp.lan.ignore='0'

for old in default_radio0 default_radio1; do
  uci -q set wireless."$old".disabled='1' || true
done
for radio in radio0 radio1; do
  uci set wireless."$radio".disabled='0'
done

uci -q delete wireless.travel_ap_24 || true
uci set wireless.travel_ap_24='wifi-iface'
uci set wireless.travel_ap_24.device='radio0'
uci set wireless.travel_ap_24.mode='ap'
uci set wireless.travel_ap_24.network='lan'
uci set wireless.travel_ap_24.ssid="$ssid"
uci set wireless.travel_ap_24.encryption='psk2'
uci set wireless.travel_ap_24.key="$password"
uci set wireless.travel_ap_24.disabled='0'
uci set wireless.travel_ap_24.hidden='0'
uci set wireless.travel_ap_24.isolate='0'

uci -q delete wireless.travel_ap_5 || true
uci set wireless.travel_ap_5='wifi-iface'
uci set wireless.travel_ap_5.device='radio1'
uci set wireless.travel_ap_5.mode='ap'
uci set wireless.travel_ap_5.network='lan'
uci set wireless.travel_ap_5.ssid="$ssid"
uci set wireless.travel_ap_5.encryption='psk2'
uci set wireless.travel_ap_5.key="$password"
uci set wireless.travel_ap_5.disabled='0'
uci set wireless.travel_ap_5.hidden='0'
uci set wireless.travel_ap_5.isolate='0'

# Preserve the known-good fallback uplink and let Travelmate manage it. The
# password remains only in /etc/config/wireless on the router.
uci set wireless.awg2_uplink.disabled='0'
uci set wireless.awg2_uplink.network='wwan'

uci set travelmate.global.trm_enabled='1'
uci set travelmate.global.trm_iface='wwan'
uci set travelmate.global.trm_laniface='lan'
uci -q delete travelmate.global.trm_radio || true
uci set travelmate.global.trm_captive='1'
uci set travelmate.global.trm_netcheck='0'
uci set travelmate.global.trm_proactive='0'
uci set travelmate.global.trm_autoadd='0'
uci set travelmate.global.trm_randomize='0'
uci set travelmate.global.trm_eviltwin='0'
uci set travelmate.global.trm_maxretry='0'
uci set travelmate.global.trm_minquality='25'
uci set travelmate.global.trm_maxwait='60'
uci set travelmate.global.trm_timeout='180'
uci set travelmate.global.trm_vpn='0'
uci -q delete travelmate.saved_iphone || true
uci set travelmate.saved_iphone='uplink'
uci set travelmate.saved_iphone.enabled='1'
uci set travelmate.saved_iphone.device="$(uci -q get wireless.awg2_uplink.device)"
uci set travelmate.saved_iphone.ssid="$uplink_ssid"

uci -q delete firewall.lan_to_awg2_home || true
uci set firewall.lan_to_awg2_home='forwarding'
uci set firewall.lan_to_awg2_home.src='lan'
uci set firewall.lan_to_awg2_home.dest='awg2_home'
uci -q delete firewall.awg2_home_to_lan || true
uci set firewall.awg2_home_to_lan='forwarding'
uci set firewall.awg2_home_to_lan.src='awg2_home'
uci set firewall.awg2_home_to_lan.dest='lan'
uci -q del_list firewall."$wan_zone".network='wwan' || true
uci add_list firewall."$wan_zone".network='wwan'

uci commit network
uci commit dhcp
uci commit wireless
uci commit travelmate
uci commit firewall
fw4 check >/dev/null

/etc/init.d/travelmate enable
ubus call network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1
sleep 3
wifi reload >/dev/null 2>&1 || true
/etc/init.d/firewall restart >/dev/null 2>&1
/etc/init.d/dnsmasq restart >/dev/null 2>&1
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/travelmate restart >/dev/null 2>&1 || true

peer_public_key="$(uci -q get network."$peer_section".public_key)"
new_allowed_csv="$(uci -q get network."$peer_section".allowed_ips | tr ' ' ',')"
live_allowed_ok=0
live_attempt=0
while [ "$live_attempt" -lt 30 ]; do
  live_attempt=$((live_attempt + 1))
  if awg show interfaces 2>/dev/null | tr ' ' '\n' | grep -qx awg1 && \
     awg set awg1 peer "$peer_public_key" allowed-ips "$new_allowed_csv" >/dev/null 2>&1 && \
     awg show awg1 allowed-ips 2>/dev/null | grep -Fq "$home_lan"; then
    live_allowed_ok=1
    break
  fi
  sleep 2
done
[ "$live_allowed_ok" = 1 ]

ok=0
attempt=0
while [ "$attempt" -lt 75 ]; do
  attempt=$((attempt + 1))
  lan_up="$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || echo false)"
  lan_runtime="$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null || true)"
  wwan_up="$(ubus call network.interface.wwan status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || echo false)"
  awg_up="$(ubus call network.interface.awg1 status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || echo false)"
  route_home="$(ip -4 route get "${home_lan%/*}" 2>/dev/null || true)"
  ap_count="$(iwinfo 2>/dev/null | grep -F -c "ESSID: \"$ssid\"" || true)"
  if [ "$lan_up" = true ] && [ "$lan_runtime" = "$lan_ip" ] && \
     [ "$wwan_up" = true ] && [ "$awg_up" = true ] && \
     [ "$ap_count" -ge 2 ] && printf '%s' "$route_home" | grep -q 'awg1' && \
     awg show awg1 allowed-ips 2>/dev/null | grep -Fq "$home_lan" && \
     ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && \
     ping -c 1 -W 2 10.67.0.1 >/dev/null 2>&1 && \
     nslookup openwrt.org >/dev/null 2>&1 && \
     /etc/init.d/uhttpd running >/dev/null 2>&1 && \
     /etc/init.d/travelmate running >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 3
done

[ "$ok" = 1 ] || {
  echo "travel_profile_validation=failed" >&2
  /etc/init.d/travelmate status 2>/dev/null || true
  exit 1
}

touch "$guard/committed"
kill "$guard_pid" >/dev/null 2>&1 || true
wait "$guard_pid" 2>/dev/null || true
rm -rf "$guard"
success=1
trap - EXIT INT TERM HUP

echo "travel_profile=applied"
echo "lan_cidr=$lan_cidr"
echo "private_ap_ssid=$ssid"
echo "private_ap_radios=radio0,radio1"
echo "travelmate_enabled=true"
echo "travelmate_running=true"
echo "fallback_uplink=$uplink_ssid"
echo "home_lan_route=$home_lan"
echo "awg_management=ok"
echo "internet=ok"
REMOTE_SH
  } | ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=8 \
    -o ConnectionAttempts=1 \
    "$ssh_alias" \
    "sh -s -- '$ssid_hex' '$lan_cidr' '$home_lan' '$peer_section' '$uplink_hex'"
)"
rc=$?
set -e

unset password_hex ssid_hex uplink_hex
if [ "$rc" -ne 0 ]; then
  echo "configure-travel-router: apply failed; router-local rollback was requested (snapshot=$snapshot_id)" >&2
  [ -n "$result" ] && printf '%s\n' "$result" >&2
  exit 20
fi

printf '%s\n' "$result"
echo "snapshot=$snapshot_id"
memory_journal_append "$router" "travel_router_profile_configured"
