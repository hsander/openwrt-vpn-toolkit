#!/bin/sh
# preflight-minimal.sh — aggregate system, LAN, conflict and safety gates for minimal profile.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LIB_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/vpn-kit-common.sh
. "$LIB_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

system="$("$SCRIPT_DIR/detect-system.sh")"
lan="$("$SCRIPT_DIR/detect-lan.sh")"
conflicts="$("$SCRIPT_DIR/check-conflicts.sh")"
safety="$("$LIB_DIR/preflight-safety.sh" 2>/dev/null || true)"
[ -n "$safety" ] || safety='{"status":"failed"}'

reasons='[]'
openwrt_major="$(printf '%s' "$system" | jq -r '.openwrt_major')"
ram_mb="$(printf '%s' "$system" | jq -r '.ram_mb')"
flash_free_mb="$(printf '%s' "$system" | jq -r '.flash_free_mb')"
pkg_mgr="$(printf '%s' "$system" | jq -r '.package_manager')"
conflict_status="$(printf '%s' "$conflicts" | jq -r '.status')"
safety_status="$(printf '%s' "$safety" | jq -r '.status // "failed"')"

add_reason() {
  reasons="$(printf '%s' "$reasons" | jq --arg id "$1" --arg message "$2" '. + [{id:$id, message:$message}]')"
}

[ "$openwrt_major" -ge 24 ] || add_reason openwrt-version "OpenWrt 24+ is required"
[ "$ram_mb" -ge 128 ] || add_reason ram "minimal profile requires at least 128 MB RAM"
[ "$flash_free_mb" -ge 8 ] || add_reason flash "minimal profile requires at least 8 MB free flash on /"
[ "$pkg_mgr" = "apk" ] || add_reason package-manager "v1 expects apk-based OpenWrt"
[ "$conflict_status" != "blocked" ] || add_reason conflicts "blocking service/package conflicts detected"
[ "$safety_status" = "ok" ] || add_reason safety "safety preflight failed"

status="ok"
if [ "$(printf '%s' "$reasons" | jq 'length')" -gt 0 ]; then
  status="blocked"
elif [ "$conflict_status" = "warnings" ]; then
  status="warnings"
fi

jq -n \
  --arg status "$status" \
  --arg profile "minimal" \
  --argjson system "$system" \
  --argjson lan "$lan" \
  --argjson conflicts "$conflicts" \
  --argjson safety "$safety" \
  --argjson blockers "$reasons" \
  '{status:$status, profile:$profile, system:$system, lan:$lan, conflicts:$conflicts, safety:$safety, blockers:$blockers}'
