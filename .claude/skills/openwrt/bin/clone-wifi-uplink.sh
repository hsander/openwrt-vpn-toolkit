#!/usr/bin/env bash
# Copy one Wi-Fi uplink credential between trusted router SSH aliases without
# printing or persisting the password on the controller.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source_alias=""
target_router=""
ssid=""
radio="radio0"
while [ $# -gt 0 ]; do
  case "$1" in
    --source-ssh-alias) source_alias="${2:-}"; shift 2 ;;
    --target-router) target_router="${2:-}"; shift 2 ;;
    --ssid) ssid="${2:-}"; shift 2 ;;
    --radio) radio="${2:-}"; shift 2 ;;
    *)
      echo "Usage: bin/clone-wifi-uplink.sh --source-ssh-alias <alias> --target-router <alias> --ssid <ssid> [--radio radio0]" >&2
      exit 64
      ;;
  esac
done

[[ "$source_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
[[ "$target_router" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || exit 13
[[ "$ssid" =~ ^[A-Za-z0-9_.+-]{1,32}$ ]] || exit 13
case "$radio" in radio0|radio1) ;; *) exit 13 ;; esac

ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o ConnectTimeout=8
  -o ConnectionAttempts=1
)

source_ssid="$(ssh "${ssh_opts[@]}" "$source_alias" 'uci -q get wireless.awg2_uplink.ssid')"
if [ "$source_ssid" != "$ssid" ]; then
  echo "clone-wifi-uplink: source alias does not contain the expected SSID" >&2
  exit 13
fi

wifi_password="$(ssh "${ssh_opts[@]}" "$source_alias" 'uci -q get wireless.awg2_uplink.key')"
cleanup() { unset wifi_password OPENWRT_WIFI_PASSWORD; }
trap cleanup EXIT INT TERM

[ "${#wifi_password}" -ge 8 ] && [ "${#wifi_password}" -le 63 ] || {
  echo "clone-wifi-uplink: source credential has an invalid length" >&2
  exit 13
}
if printf '%s' "$wifi_password" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  echo "clone-wifi-uplink: source credential contains control characters" >&2
  exit 13
fi

export OPENWRT_WIFI_PASSWORD="$wifi_password"
"$SCRIPT_DIR/setup-wifi-uplink.sh" \
  --router "$target_router" \
  --ssid "$ssid" \
  --radio "$radio"
