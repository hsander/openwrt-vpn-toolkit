#!/bin/sh
# preflight-safety.sh — hard gate for Stage 0 safety primitives.
#
# Usage:
#   preflight-safety.sh
#
# Fails before any network-changing operation if the target does not provide the
# primitives required by the rollback contract.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

missing=""
for cmd in jq procd start-stop-daemon; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing="$missing $cmd"
  fi
done

if [ -n "$missing" ]; then
  echo "preflight-safety: missing required command(s):$missing" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

lock_mode="mkdir-fallback"
if command -v flock >/dev/null 2>&1 && flock --help 2>&1 | grep -q -- '-w'; then
  lock_mode="flock-timeout"
elif command -v flock >/dev/null 2>&1; then
  lock_mode="busybox-flock-unsupported-timeout-using-mkdir-fallback"
fi

jq -n \
  --arg status "ok" \
  --arg lock_mode "$lock_mode" \
  --arg rollback_dir "$VPN_KIT_ROLLBACK_DIR" \
  --arg snapshot_dir "$VPN_KIT_SNAPSHOT_DIR" \
  '{status:$status, lock_mode:$lock_mode, rollback_dir:$rollback_dir, snapshot_dir:$snapshot_dir}'
