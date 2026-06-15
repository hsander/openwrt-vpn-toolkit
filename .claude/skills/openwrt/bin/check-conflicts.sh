#!/bin/sh
# check-conflicts.sh — detect services/packages that must be removed or handled manually.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LIB_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/vpn-kit-common.sh
. "$LIB_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

conflicts='[]'
warnings='[]'
etc_dir="${VPN_KIT_TEST_ETC:-/etc}"
opt_dir="${VPN_KIT_TEST_OPT:-/opt}"

add_conflict() {
  conflicts="$(printf '%s' "$conflicts" | jq --arg id "$1" --arg reason "$2" --arg action "$3" '. + [{id:$id, reason:$reason, action:$action}]')"
}

add_warning() {
  warnings="$(printf '%s' "$warnings" | jq --arg id "$1" --arg reason "$2" '. + [{id:$id, reason:$reason}]')"
}

if [ -x "$etc_dir/init.d/podkop" ] || command -v podkop >/dev/null 2>&1; then
  add_conflict podkop "podkop manages transparent proxy/firewall paths that overlap vpn-kit" "disable/remove podkop before install"
fi

if [ -x "$etc_dir/init.d/zapret" ] || [ -x "$etc_dir/init.d/zapret_custom" ] || [ -x "$etc_dir/init.d/zapret-custom" ] || [ -x "$etc_dir/init.d/zapret2" ] || [ -d "$opt_dir/zapret" ] || [ -d "$opt_dir/zapret2" ]; then
  add_conflict zapret "existing zapret/zapret2 installation may own hostlists/init scripts" "adopt or remove existing zapret before install"
fi

if [ -x "$etc_dir/init.d/mwan3" ] || command -v mwan3 >/dev/null 2>&1; then
  add_conflict mwan3 "mwan3 changes routing/firewall behavior and can race staged apply" "manual review required before install"
fi

if [ -x "$etc_dir/init.d/sing-box" ] || [ -x "$etc_dir/init.d/sing-box-tproxy" ] || command -v sing-box >/dev/null 2>&1; then
  add_warning sing-box "existing sing-box detected; install must adopt or refuse overwrite"
fi

if [ -x "$etc_dir/init.d/https-dns-proxy" ]; then
  add_warning https-dns-proxy "existing DoH service detected; minimal profile may reuse or conflict"
fi

status="ok"
if [ "$(printf '%s' "$conflicts" | jq 'length')" -gt 0 ]; then
  status="blocked"
elif [ "$(printf '%s' "$warnings" | jq 'length')" -gt 0 ]; then
  status="warnings"
fi

jq -n --arg status "$status" --argjson conflicts "$conflicts" --argjson warnings "$warnings" \
  '{status:$status, conflicts:$conflicts, warnings:$warnings}'
