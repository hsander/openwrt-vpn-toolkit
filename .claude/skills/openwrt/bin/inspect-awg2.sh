#!/usr/bin/env bash
# AmneziaWG/OpenWrt inventory. Never prints private/public keys, preshared
# keys, Wi-Fi keys, or full UCI sections. --scan-wifi may create short-lived
# unmanaged station interfaces; they are deleted before the script exits.

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
  echo "Usage: bin/inspect-awg2.sh (--router <alias> | --ssh-alias <alias>) [--scan-wifi]" >&2
  exit 64
}

router=""
ssh_alias_override=""
scan_wifi=0
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias_override="${2:-}"; shift 2 ;;
    --scan-wifi) scan_wifi=1; shift ;;
    -h|--help) usage ;;
    *) echo "inspect-awg2: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$router" ] || [ -n "$ssh_alias_override" ] || usage
[ -z "$router" ] || [ -z "$ssh_alias_override" ] || usage
if [ -n "$ssh_alias_override" ]; then
  [[ "$ssh_alias_override" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
  ROUTER_ALIAS="$ssh_alias_override"
  ROUTER_SSH_ALIAS="$ssh_alias_override"
  ROUTER_HOST="$(ssh -G "$ssh_alias_override" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
  ROUTER_USER="$(ssh -G "$ssh_alias_override" 2>/dev/null | awk '$1 == "user" { print $2; exit }')"
  ROUTER_SSH_KEY=""
  [ -n "$ROUTER_HOST" ] && [ -n "$ROUTER_USER" ] || exit 13
  export ROUTER_ALIAS ROUTER_SSH_ALIAS ROUTER_HOST ROUTER_USER ROUTER_SSH_KEY
else
  resolve_router_config "$router"
fi
ssh_check_alive 5 || {
  echo "inspect-awg2: SSH unavailable for $ROUTER_ALIAS" >&2
  exit 2
}

ssh_run_remote_with_args /dev/stdin "$scan_wifi" <<'REMOTE_SH'
set -u
scan_wifi="$1"

value_or_unknown() {
  value="$1"
  [ -n "$value" ] && printf '%s\n' "$value" || printf 'unknown\n'
}

echo "section=system"
echo "release=$(sed -n \"s/^DISTRIB_RELEASE='\\(.*\\)'/\\1/p\" /etc/openwrt_release 2>/dev/null)"
echo "target=$(sed -n \"s/^DISTRIB_TARGET='\\(.*\\)'/\\1/p\" /etc/openwrt_release 2>/dev/null)"
echo "arch=$(uname -m 2>/dev/null || true)"
echo "kernel=$(uname -r 2>/dev/null || true)"
echo "uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null || true)"

echo "section=network"
echo "default_routes_begin"
ip -4 route show default 2>/dev/null || true
echo "default_routes_end"
echo "wan_status=$(ubus call network.interface.wan status 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/"dns-server":[^]]*]/"dns-server":[]/' || true)"

echo "section=amneziawg"
if command -v awg >/dev/null 2>&1; then
  echo "awg_path=$(command -v awg)"
  echo "awg_version=$(awg --version 2>&1 | head -1)"
  interfaces="$(awg show interfaces 2>/dev/null || true)"
  echo "awg_interfaces=$interfaces"
  for iface in $interfaces; do
    latest="$(awg show "$iface" latest-handshakes 2>/dev/null | awk 'BEGIN{m=0} $2>m{m=$2} END{print m+0}')"
    rx="$(awg show "$iface" transfer 2>/dev/null | awk '{r+=$2} END{print r+0}')"
    tx="$(awg show "$iface" transfer 2>/dev/null | awk '{t+=$3} END{print t+0}')"
    echo "awg_interface=$iface latest_handshake_epoch=$latest rx_bytes=$rx tx_bytes=$tx"
    echo "awg_parameters_begin=$iface"
    awg showconf "$iface" 2>/dev/null | grep -E '^(ListenPort|Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|Itime|J[1-3])[[:space:]]*=' || true
    echo "awg_parameters_end=$iface"
  done
else
  echo "awg_path=missing"
  echo "awg_version=missing"
  echo "awg_interfaces="
fi

if command -v modinfo >/dev/null 2>&1; then
  modinfo amneziawg 2>/dev/null | awk -F: '
    $1 ~ /^(filename|version|vermagic)$/ {
      key=$1; sub(/^[^:]*:[[:space:]]*/, "", $0); print "module_" key "=" $0
    }'
fi
[ -d /sys/module/amneziawg ] && echo "module_loaded=true" || echo "module_loaded=false"
for proto_file in /lib/netifd/proto/amneziawg.sh /lib/netifd/proto/awg.sh; do
  [ -f "$proto_file" ] || continue
  fields="$(grep -Eo 'awg_(s3|s4|i[1-5]|itime|j[1-3])' "$proto_file" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//' || true)"
  echo "netifd_proto=$proto_file awg2_fields=$fields"
done

if command -v apk >/dev/null 2>&1; then
  echo "packages_begin"
  apk list --installed 2>/dev/null | grep -Ei '(^|[-_])(amnezia|wireguard)|^kmod-amnezia' || true
  echo "packages_end"
elif command -v opkg >/dev/null 2>&1; then
  echo "packages_begin"
  opkg list-installed 2>/dev/null | grep -Ei 'amnezia|wireguard' || true
  echo "packages_end"
fi

echo "uci_awg_fields_begin"
uci -q show network 2>/dev/null | grep -E "=(interface|amneziawg_[A-Za-z0-9_-]+)$|\\.(proto|listen_port|addresses|mtu|awg_jc|awg_jmin|awg_jmax|awg_s[1-4]|awg_h[1-4]|awg_i[1-5]|awg_itime|awg_j[1-3]|allowed_ips|route_allowed_ips|endpoint_host|endpoint_port|persistent_keepalive)=" || true
echo "uci_awg_fields_end"
echo "awg_log_begin"
logread 2>/dev/null | grep -Ei 'amnezia|(^|[^a-z])awg[0-9_]|netifd.*awg' | tail -100 | \
  sed -E 's/((private|public|preshared)[_-]?key[=:])[A-Za-z0-9+\/=]+/\1<redacted>/Ig' || true
echo "awg_log_end"

echo "section=wireless"
echo "wireless_clients_begin"
for section in $(uci -q show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
  mode="$(uci -q get wireless."$section".mode || true)"
  ssid="$(uci -q get wireless."$section".ssid || true)"
  network="$(uci -q get wireless."$section".network || true)"
  disabled="$(uci -q get wireless."$section".disabled || echo 0)"
  echo "wifi_section=$section mode=$mode ssid=$ssid network=$network disabled=$disabled"
done
echo "wireless_clients_end"

if [ "$scan_wifi" = "1" ]; then
  echo "wifi_scan_begin"
  candidates="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')"
  created=""
  cleanup_scan_ifaces() {
    for tmp_dev in $created; do
      iw dev "$tmp_dev" del >/dev/null 2>&1 || true
    done
  }
  trap cleanup_scan_ifaces EXIT INT TERM
  if [ -z "$candidates" ]; then
    scan_index=0
    for phy_path in /sys/class/ieee80211/*; do
      [ -e "$phy_path" ] || continue
      phy="${phy_path##*/}"
      tmp_dev="skillscan${scan_index}"
      scan_index=$((scan_index + 1))
      if iw phy "$phy" interface add "$tmp_dev" type station >/dev/null 2>&1; then
        created="$created $tmp_dev"
        ip link set "$tmp_dev" up >/dev/null 2>&1 || true
        candidates="$candidates $tmp_dev"
      fi
    done
  fi
  seen=""
  for dev in $candidates; do
    scan="$(iwinfo "$dev" scan 2>/dev/null || true)"
    [ -n "$scan" ] || continue
    printf '%s\n' "$scan" | awk -v dev="$dev" '
      /ESSID:/ {ssid=$0; sub(/^.*ESSID: /,"",ssid); gsub(/^"|"$/,"",ssid)}
      /Channel:/ {channel=$0; sub(/^.*Channel: /,"",channel); sub(/ .*/,"",channel)}
      /Signal:/ {signal=$0; sub(/^.*Signal: /,"",signal); sub(/ .*/,"",signal)}
      /Encryption:/ {
        encryption=$0; sub(/^.*Encryption: /,"",encryption)
        if (ssid!="") print "device=" dev " channel=" channel " ssid=" ssid " signal_dbm=" signal " encryption=" encryption
        ssid=""; channel=""; signal=""; encryption=""
      }
    '
    seen=1
  done
  cleanup_scan_ifaces
  trap - EXIT INT TERM
  echo "wifi_scan_end"
  echo "wifi_log_begin"
  logread 2>/dev/null | grep -Ei 'netifd|wpa_supplicant|radio[01]|wwan' | tail -80 | \
    sed -E 's/((psk|key|password)=)[^ ]+/\1<redacted>/Ig' || true
  echo "wifi_log_end"
fi
REMOTE_SH
