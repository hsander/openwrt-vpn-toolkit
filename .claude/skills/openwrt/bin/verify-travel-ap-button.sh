#!/usr/bin/env bash
# Read-only persistence check for the travel AP button handler.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

ssh_alias=""
visible_seconds=600
expected_hidden=1
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --visible-seconds) visible_seconds="${2:-}"; shift 2 ;;
    --expected-hidden) expected_hidden="${2:-}"; shift 2 ;;
    *) echo "Usage: bin/verify-travel-ap-button.sh --ssh-alias <alias> [--visible-seconds 600] [--expected-hidden 0|1]" >&2; exit 64 ;;
  esac
done
[[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
[[ "$visible_seconds" =~ ^[0-9]+$ ]] || exit 13
[[ "$expected_hidden" =~ ^[01]$ ]] || exit 13

local_handler_hash="$(shasum -a 256 "$SKILL_HOME/openwrt/travel-ap-button" | awk '{print $1}')"
local_helper_hash="$(shasum -a 256 "$SKILL_HOME/openwrt/travel-ap-autohide" | awk '{print $1}')"

ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 \
  "$ssh_alias" \
  "sh -s -- '$local_handler_hash' '$local_helper_hash' '$visible_seconds' '$expected_hidden'" <<'REMOTE_SH'
set -eu
expected_handler_hash="$1"
expected_helper_hash="$2"
visible_seconds="$3"
expected_hidden="$4"

button_found=0
for keydir in /sys/firmware/devicetree/base/keys/* /sys/firmware/devicetree/base/gpio-keys/*; do
  [ -d "$keydir" ] || continue
  [ "$(tr -d '\000' <"$keydir/label" 2>/dev/null || true)" = wps ] && button_found=1
done
[ "$button_found" = 1 ]
echo "physical_button_mapping=wps"

handler_hash="$(sha256sum /etc/rc.button/wps | awk '{print $1}')"
helper_hash="$(sha256sum /usr/libexec/travel-ap-autohide | awk '{print $1}')"
[ "$handler_hash" = "$expected_handler_hash" ]
[ "$helper_hash" = "$expected_helper_hash" ]
sh -n /etc/rc.button/wps
sh -n /usr/libexec/travel-ap-autohide
echo "button_handler=ok"
echo "autohide_helper=ok"

. /etc/travel-ap-button.conf
[ "$VISIBLE_SECONDS" = "$visible_seconds" ]
echo "visible_seconds=$VISIBLE_SECONDS"

[ "$(uci -q get wireless.travel_ap_24.hidden)" = "$expected_hidden" ]
[ "$(uci -q get wireless.travel_ap_5.hidden)" = "$expected_hidden" ]
echo "private_ap_hidden=$expected_hidden"

if [ "$expected_hidden" = 1 ]; then
  [ ! -e /tmp/travel-ap-button/token ]
  echo "visibility_timer=inactive"
fi

echo "travel_ap_button_verification=ok"
REMOTE_SH
