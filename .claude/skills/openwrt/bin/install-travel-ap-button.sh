#!/usr/bin/env bash
# Bind the physical WPS/Wireless Pairing button to a timed AP visibility toggle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  echo "Usage: bin/install-travel-ap-button.sh --router <alias> --ssh-alias <alias> --lan-ip <ip> --home-lan-ip <ip> [--visible-seconds 600]" >&2
  exit 64
}

router=""
ssh_alias=""
visible_seconds=600
lan_ip=""
home_lan_ip=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --visible-seconds) visible_seconds="${2:-}"; shift 2 ;;
    --lan-ip) lan_ip="${2:-}"; shift 2 ;;
    --home-lan-ip) home_lan_ip="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$router" ] && [ -n "$lan_ip" ] && [ -n "$home_lan_ip" ] && [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || usage
[[ "$visible_seconds" =~ ^[0-9]+$ ]] && (( visible_seconds >= 60 && visible_seconds <= 3600 )) || exit 13
[[ "$lan_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || exit 13
[[ "$home_lan_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || exit 13

handler_src="$SKILL_HOME/openwrt/travel-ap-button"
helper_src="$SKILL_HOME/openwrt/travel-ap-autohide"
[ -f "$handler_src" ] && [ -f "$helper_src" ] || exit 13
sh -n "$handler_src"
sh -n "$helper_src"

resolve_router_config "$router"
snapshot_id="$($SCRIPT_DIR/backup-now.sh --router "$router" --ssh-alias "$ssh_alias" --label "before travel ap button" --quiet)"

remote_handler_tmp="/tmp/openwrt-skill-travel-ap-button.$$"
remote_helper_tmp="/tmp/openwrt-skill-travel-ap-autohide.$$"
scp_opts=(-O -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8)
scp "${scp_opts[@]}" "$handler_src" "$ssh_alias:$remote_handler_tmp"
scp "${scp_opts[@]}" "$helper_src" "$ssh_alias:$remote_helper_tmp"

set +e
result="$(ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 \
  "$ssh_alias" \
  "sh -s -- '$visible_seconds' '$lan_ip' '$home_lan_ip' '$remote_handler_tmp' '$remote_helper_tmp'" <<'REMOTE_SH'
set -eu
visible_seconds="$1"
lan_ip="$2"
home_lan_ip="$3"
handler_src="$4"
helper_src="$5"
handler=/etc/rc.button/wps
helper=/usr/libexec/travel-ap-autohide
config=/etc/travel-ap-button.conf

cleanup_sources() { rm -f "$handler_src" "$helper_src"; }
trap cleanup_sources EXIT

button_found=0
for keydir in /sys/firmware/devicetree/base/keys/* /sys/firmware/devicetree/base/gpio-keys/*; do
  [ -d "$keydir" ] || continue
  label="$(tr -d '\000' <"$keydir/label" 2>/dev/null || true)"
  [ "$label" = wps ] && button_found=1
done
[ "$button_found" = 1 ]
[ -f "$handler" ]
sh -n "$handler_src"
sh -n "$helper_src"
for ap in travel_ap_24 travel_ap_5; do
  [ "$(uci -q get wireless."$ap".mode)" = ap ]
done

rollback_dir="$(mktemp -d /tmp/travel-button-rollback.XXXXXX)"
cp /etc/config/wireless "$rollback_dir/wireless"
cp "$handler" "$rollback_dir/wps"
[ ! -e "$helper" ] || cp "$helper" "$rollback_dir/helper"
[ ! -e "$config" ] || cp "$config" "$rollback_dir/config"
chmod 600 "$rollback_dir"/*
success=0

rollback() {
  [ "$success" = 1 ] && return 0
  cp "$rollback_dir/wireless" /etc/config/wireless
  cp "$rollback_dir/wps" "$handler"
  if [ -f "$rollback_dir/helper" ]; then cp "$rollback_dir/helper" "$helper"; else rm -f "$helper"; fi
  if [ -f "$rollback_dir/config" ]; then cp "$rollback_dir/config" "$config"; else rm -f "$config"; fi
  chmod 755 "$handler"
  [ ! -e "$helper" ] || chmod 755 "$helper"
  [ ! -e "$config" ] || chmod 600 "$config"
  rm -f /tmp/travel-ap-button/token
  wifi reload >/dev/null 2>&1 || true
}
cleanup() { rollback; rm -rf "$rollback_dir"; cleanup_sources; }
trap cleanup EXIT INT TERM HUP

mkdir -p /usr/libexec
cp "$helper_src" "$helper.tmp.$$"
chmod 755 "$helper.tmp.$$"
mv -f "$helper.tmp.$$" "$helper"
cp "$handler_src" "$handler.tmp.$$"
chmod 755 "$handler.tmp.$$"
mv -f "$handler.tmp.$$" "$handler"
printf 'VISIBLE_SECONDS=%s\n' "$visible_seconds" >"$config.tmp"
chmod 600 "$config.tmp"
mv -f "$config.tmp" "$config"
sh -n "$helper"
sh -n "$handler"

# Hidden is the persistent default.
rm -f /tmp/travel-ap-button/token
uci set wireless.travel_ap_24.hidden='1'
uci set wireless.travel_ap_5.hidden='1'
uci commit wireless
wifi reload >/dev/null 2>&1 || true
sleep 5

# Software event proof: hidden -> visible -> hidden.
ACTION=released SEEN=1 BUTTON=wps "$handler"
sleep 5
[ "$(uci -q get wireless.travel_ap_24.hidden)" = 0 ]
[ "$(uci -q get wireless.travel_ap_5.hidden)" = 0 ]
[ -s /tmp/travel-ap-button/token ]
ACTION=released SEEN=1 BUTTON=wps "$handler"
sleep 5
[ "$(uci -q get wireless.travel_ap_24.hidden)" = 1 ]
[ "$(uci -q get wireless.travel_ap_5.hidden)" = 1 ]
[ ! -e /tmp/travel-ap-button/token ]

wwan_up="$(ubus call network.interface.wwan status | jsonfilter -e '@.up' 2>/dev/null || echo false)"
awg_up="$(ubus call network.interface.awg1 status | jsonfilter -e '@.up' 2>/dev/null || echo false)"
[ "$wwan_up" = true ] && [ "$awg_up" = true ]
ping -c 2 -W 2 1.1.1.1 >/dev/null
ping -I "$lan_ip" -c 2 -W 2 "$home_lan_ip" >/dev/null
/etc/init.d/travelmate running >/dev/null 2>&1

success=1
echo "button_event=wps"
echo "short_press=toggle_visibility"
echo "visible_seconds=$visible_seconds"
echo "long_press=ignored"
echo "persistent_default=hidden"
echo "software_toggle_test=ok"
echo "internet_after_test=ok"
echo "home_route_after_test=ok"
REMOTE_SH
)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_alias" "rm -f '$remote_handler_tmp' '$remote_helper_tmp'" >/dev/null 2>&1 || true
  echo "install-travel-ap-button: failed and restored previous handler/wireless config (snapshot=$snapshot_id)" >&2
  exit 20
fi

printf '%s\n' "$result"
echo "snapshot=$snapshot_id"
memory_journal_append "$router" "travel_ap_button_installed"
