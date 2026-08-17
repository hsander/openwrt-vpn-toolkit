#!/usr/bin/env bash
# Configure a WPA2 Wi-Fi station as a DHCP WAN uplink with rollback on failure.
# The Wi-Fi password is accepted only through OPENWRT_WIFI_PASSWORD and is never
# printed or written to skill memory/journal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  cat >&2 <<'EOF'
Usage: OPENWRT_WIFI_PASSWORD='...' bin/setup-wifi-uplink.sh \
  --router <alias> --ssid <ssid> [--radio radio1]

Or provide the password through hidden stdin:
  bin/setup-wifi-uplink.sh --password-stdin \
    --router <alias> --ssid <ssid> [--radio radio1]
EOF
  exit 64
}

router=""
ssid=""
radio="radio1"
password_stdin=0
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssid) ssid="${2:-}"; shift 2 ;;
    --radio) radio="${2:-}"; shift 2 ;;
    --password-stdin) password_stdin=1; shift ;;
    -h|--help) usage ;;
    *) echo "setup-wifi-uplink: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$router" ] && [ -n "$ssid" ] || usage
if [ "$password_stdin" = 1 ]; then
  printf 'Wi-Fi password: ' >&2
  IFS= read -r -s password
  printf '\n' >&2
else
  password="${OPENWRT_WIFI_PASSWORD:-}"
fi
[ -n "$password" ] || { echo "setup-wifi-uplink: Wi-Fi password is required" >&2; exit 13; }

case "$radio" in radio0|radio1) ;; *) echo "setup-wifi-uplink: invalid radio" >&2; exit 13 ;; esac
[ "${#ssid}" -le 32 ] || { echo "setup-wifi-uplink: SSID is too long" >&2; exit 13; }
[ "${#password}" -ge 8 ] && [ "${#password}" -le 63 ] || {
  echo "setup-wifi-uplink: WPA2 password must be 8..63 characters" >&2
  exit 13
}
if printf '%s%s' "$ssid" "$password" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  echo "setup-wifi-uplink: control characters are not allowed" >&2
  exit 13
fi

resolve_router_config "$router"
ssh_check_alive 5 || { echo "setup-wifi-uplink: router is unreachable" >&2; exit 2; }

snapshot_id="$($SCRIPT_DIR/backup-now.sh --router "$router" --label "before wifi uplink" --quiet)"

set +e
result="$(ssh_run_remote_with_args /dev/stdin "$ssid" "$password" "$radio" <<'REMOTE_SH'
set -eu
ssid="$1"
password="$2"
radio="$3"
backup_dir="$(mktemp -d /tmp/skill-wifi-uplink.XXXXXX)"
success=0

cp /etc/config/network "$backup_dir/network"
cp /etc/config/firewall "$backup_dir/firewall"
cp /etc/config/wireless "$backup_dir/wireless"
chmod 600 "$backup_dir"/*

rollback() {
  [ "$success" = 1 ] && return 0
  cp "$backup_dir/network" /etc/config/network
  cp "$backup_dir/firewall" /etc/config/firewall
  cp "$backup_dir/wireless" /etc/config/wireless
  ubus call network reload >/dev/null 2>&1 || true
  wifi reload >/dev/null 2>&1 || true
}
cleanup() { rollback; rm -rf "$backup_dir"; }
trap cleanup EXIT INT TERM

uci -q get wireless."$radio" >/dev/null
wan_zone="$(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='wan'$/\1/p" | head -1)"
[ -n "$wan_zone" ]

uci set network.wwan=interface
uci set network.wwan.proto='dhcp'
uci set network.wwan.metric='50'
uci set network.wwan.peerdns='1'

uci -q delete wireless.awg2_uplink || true
uci set wireless.awg2_uplink=wifi-iface
uci set wireless.awg2_uplink.device="$radio"
uci set wireless.awg2_uplink.mode='sta'
uci set wireless.awg2_uplink.network='wwan'
uci set wireless.awg2_uplink.ssid="$ssid"
uci set wireless.awg2_uplink.encryption='psk2'
uci set wireless.awg2_uplink.key="$password"
uci set wireless.awg2_uplink.disabled='0'
uci set wireless."$radio".disabled='0'

uci -q del_list firewall."$wan_zone".network='wwan' || true
uci add_list firewall."$wan_zone".network='wwan'

uci commit network
uci commit wireless
uci commit firewall

wifi reload >/dev/null 2>&1 || wifi up "$radio" >/dev/null 2>&1 || true
ifup wwan >/dev/null 2>&1 || true

up=false
attempt=0
while [ "$attempt" -lt 18 ]; do
  attempt=$((attempt + 1))
  up="$(ubus call network.interface.wwan status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || echo false)"
  [ "$up" = true ] && break
  sleep 3
done
[ "$up" = true ]

ipv4="$(ubus call network.interface.wwan status | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null || true)"
[ -n "$ipv4" ]
ping -c 2 -W 3 1.1.1.1 >/dev/null

success=1
echo "wifi_uplink=up"
echo "ssid=$ssid"
echo "radio=$radio"
echo "ipv4=$ipv4"
ip -4 route show default 2>/dev/null || true
REMOTE_SH
)"
rc=$?
set -e

unset password OPENWRT_WIFI_PASSWORD

if [ "$rc" -ne 0 ]; then
  echo "setup-wifi-uplink: apply failed and router files were restored (snapshot=$snapshot_id)" >&2
  exit 20
fi

printf '%s\n' "$result"
memory_journal_append "$router" "wifi_uplink_configured"
