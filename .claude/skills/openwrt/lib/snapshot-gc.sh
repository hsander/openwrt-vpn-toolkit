#!/bin/sh
# snapshot-gc.sh — remove committed snapshots when no active rollback timer references them.
#
# Usage:
#   snapshot-gc.sh --delete-success <snapshot-path>
#
# This is intentionally conservative. It refuses to delete a snapshot if any timer
# in VPN_KIT_ROLLBACK_DIR still references the same path.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

mode=""
snapshot_path=""

while [ $# -gt 0 ]; do
  case "$1" in
    --delete-success) mode="delete-success"; snapshot_path="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "snapshot-gc: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

if [ "$mode" != "delete-success" ] || [ -z "$snapshot_path" ]; then
  echo "snapshot-gc: --delete-success <snapshot-path> is required" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

if [ ! -d "$snapshot_path" ]; then
  exit 0
fi

if [ -d "$VPN_KIT_ROLLBACK_DIR" ]; then
  for timer in "$VPN_KIT_ROLLBACK_DIR"/*.timer; do
    [ -f "$timer" ] || continue
    ref="$(jq -r '.snapshot_path // ""' "$timer" 2>/dev/null || true)"
    if [ "$ref" = "$snapshot_path" ]; then
      echo "snapshot-gc: active timer still references $snapshot_path" >&2
      exit "$VPN_KIT_EXIT_LOCK"
    fi
  done
fi

rm -rf "$snapshot_path"
"$SCRIPT_DIR/journal-append.sh" snapshot_cleaned snapshot="$snapshot_path" reason=delete-on-success >/dev/null 2>&1 || true
