#!/bin/sh
# adopt-safety-state.sh — reconstruct install-state.json for an already installed safety runtime.
#
# Usage:
#   adopt-safety-state.sh [--root <target-root>] --writer <id>

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LIB_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/../lib" && pwd)"

target_root="${VPN_KIT_TARGET_ROOT:-}"
writer=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root) target_root="${2:-}"; shift 2 ;;
    --writer) writer="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "adopt-safety-state: unknown arg: $1" >&2; exit 13 ;;
  esac
done

export VPN_KIT_TARGET_ROOT="$target_root"
# shellcheck source=../lib/vpn-kit-common.sh
. "$LIB_DIR/vpn-kit-common.sh"

[ -n "$writer" ] || { echo "adopt-safety-state: --writer is required" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
vpn_kit_validate_writer_id "$writer" || { echo "adopt-safety-state: invalid writer" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }

lib_dir="$(vpn_kit_target_path /usr/lib/vpn-kit)"
init_file="$(vpn_kit_target_path /etc/init.d/vpn-kit-rollback)"
wrapper="$(vpn_kit_target_path /usr/sbin/vpn-kit-rollback)"
state_file="$(vpn_kit_target_path /etc/vpn-kit/install-state.json)"

[ -f "$lib_dir/vpn-kit-rollback.sh" ] || { echo "adopt-safety-state: rollback runtime not found" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
[ -f "$init_file" ] || { echo "adopt-safety-state: init.d wrapper not found" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
[ -f "$wrapper" ] || { echo "adopt-safety-state: /usr/sbin wrapper not found" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }

mkdir -p "$(dirname "$state_file")"

sha_runtime="$(vpn_kit_sha256 < "$lib_dir/vpn-kit-rollback.sh")"
sha_init="$(vpn_kit_sha256 < "$init_file")"
now="$(vpn_kit_now_iso8601)"

payload="$(jq -n \
  --arg now "$now" \
  --arg init "$init_file" \
  --arg wrapper "$wrapper" \
  --arg runtime "$lib_dir/vpn-kit-rollback.sh" \
  --arg sha_runtime "$sha_runtime" \
  --arg sha_init "$sha_init" \
  '{
    version: 1,
    installed_at: $now,
    skill_version: "0.1.0",
    profile: "minimal",
    router_identity: {name: "adopted-router", openwrt_version: "unknown", arch: "x86_64"},
    committed_steps: [{step_id:"adopt-safety-state", committed_at:$now, revision_at_commit:1}],
    components: {rollback_daemon: {version:"0.1.0", init:$init, binary:$wrapper, binary_sha256:$sha_runtime}},
    files_owned_by_skill: [$runtime, $init, $wrapper],
    owned_file_checksums: {($runtime):$sha_runtime, ($init):$sha_init}
  }')"

if [ -f "$state_file" ]; then
  echo "adopt-safety-state: state already exists: $state_file" >&2
  exit "$VPN_KIT_EXIT_STALE"
fi

printf '%s\n' "$payload" | env VPN_KIT_STATE_FILE="$state_file" "$lib_dir/state-write.sh" --expected-revision 0 --writer "$writer" >/dev/null
jq -n --arg status adopted --arg state "$state_file" '{status:$status, state:$state}'
