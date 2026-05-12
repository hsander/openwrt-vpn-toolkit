#!/bin/sh
# vpn-kit-rollback.sh — rollback timer watcher for staged network changes.
#
# Usage:
#   vpn-kit-rollback.sh --once
#   vpn-kit-rollback.sh --daemon

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

mode=""
case "${1:-}" in
  --once) mode="once" ;;
  --daemon) mode="daemon" ;;
  -h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) echo "vpn-kit-rollback: use --once or --daemon" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac

tick_once() {
  mkdir -p "$VPN_KIT_ROLLBACK_DIR"
  now="$(date +%s)"

  for timer in "$VPN_KIT_ROLLBACK_DIR"/*.timer; do
    [ -f "$timer" ] || continue
    if ! jq -e . "$timer" >/dev/null 2>&1; then
      echo "vpn-kit-rollback: invalid timer: $timer" >&2
      continue
    fi

    step_id="$(jq -r '.step_id' "$timer")"
    deadline="$(jq -r '.deadline_unix' "$timer")"
    snapshot_path="$(jq -r '.snapshot_path' "$timer")"

    if [ -f "$VPN_KIT_STATE_FILE" ] && jq -e --arg step "$step_id" \
      '(.committed_steps // []) | any(.step_id == $step)' "$VPN_KIT_STATE_FILE" >/dev/null 2>&1; then
      rm -f "$timer"
      "$SCRIPT_DIR/snapshot-gc.sh" --delete-success "$snapshot_path" >/dev/null 2>&1 || true
      continue
    fi

    case "$deadline" in
      ''|*[!0-9]*)
        echo "vpn-kit-rollback: invalid deadline in $timer" >&2
        continue ;;
    esac

    if [ "$now" -ge "$deadline" ]; then
      "$SCRIPT_DIR/rollback-snapshot.sh" --snapshot "$snapshot_path" --step-id "$step_id" --triggered-by timer
      rm -f "$timer"
    fi
  done
}

if [ "$mode" = "once" ]; then
  tick_once
  exit 0
fi

while :; do
  tick_once
  sleep "$VPN_KIT_ROLLBACK_TICK_SECONDS"
done
