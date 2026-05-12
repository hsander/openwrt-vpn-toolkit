#!/bin/sh
# state-write.sh — atomic CAS write of /etc/vpn-kit/install-state.json
#
# Usage:
#   state-write.sh --expected-revision N --writer <id> [--writer-host <host>] < new.json
#
# Semantics (see PROPOSAL.md §9.3):
#   - new.json on stdin is the full new state WITHOUT _revision/_last_writer/_last_updated_at
#     — those fields are managed by this script and overwritten with N+1 / writer / now.
#   - If expected-revision != current on-disk revision → exit 11 (STALE). Caller re-reads and retries.
#   - If expected-revision == 0 AND file does not exist → initial write (revision becomes 1).
#   - Uses flock (or mkdir fallback) on /var/lock/vpn-kit-state.lock; timeout → exit 12.
#   - Produced JSON parse-checked; malformed input → exit 13.
#
# Exit codes:
#   0  — committed; new revision = N+1
#   11 — STALE: on-disk revision != expected
#   12 — LOCK: could not acquire lock within timeout
#   13 — VALIDATION: bad input JSON or bad args

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

expected_rev=""
writer=""
writer_host=""

while [ $# -gt 0 ]; do
  case "$1" in
    --expected-revision) expected_rev="$2"; shift 2 ;;
    --writer)            writer="$2"; shift 2 ;;
    --writer-host)       writer_host="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "state-write: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

if [ -z "$expected_rev" ] || [ -z "$writer" ]; then
  echo "state-write: --expected-revision and --writer are required" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

case "$expected_rev" in
  ''|*[!0-9]*)
    echo "state-write: --expected-revision must be a non-negative integer" >&2
    exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac

if ! vpn_kit_validate_writer_id "$writer"; then
  echo "state-write: --writer must match <role>@<instance-id>" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

# Read stdin fully (we need to validate + merge).
new_raw="$(cat)"
if ! printf '%s' "$new_raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "state-write: stdin is not a valid JSON object" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

_do_write() {
  # Inside lock: read current, compare, write.
  cur_rev=""
  if [ -f "$VPN_KIT_STATE_FILE" ]; then
    cur_rev="$(jq -r '._revision // 0' "$VPN_KIT_STATE_FILE" 2>/dev/null || echo "0")"
  else
    cur_rev="0"
  fi

  if [ "$cur_rev" != "$expected_rev" ]; then
    echo "state-write: STALE expected=$expected_rev current=$cur_rev" >&2
    return "$VPN_KIT_EXIT_STALE"
  fi

  next_rev=$((cur_rev + 1))
  now="$(vpn_kit_now_iso8601)"

  # Merge: set CAS fields on the new object.
  merged="$(printf '%s' "$new_raw" | jq \
    --argjson rev "$next_rev" \
    --arg writer "$writer" \
    --arg whost "$writer_host" \
    --arg now "$now" \
    '. + {
       _revision: $rev,
       _last_writer: $writer,
       _last_updated_at: $now
     } + (if ($whost | length) > 0 then {_last_writer_host: $whost} else {} end)')"

  # Final parse-check of merged output.
  if ! printf '%s' "$merged" | jq -e . >/dev/null 2>&1; then
    echo "state-write: merged JSON failed parse-check" >&2
    return "$VPN_KIT_EXIT_VALIDATION"
  fi

  printf '%s\n' "$merged" | vpn_kit_atomic_write "$VPN_KIT_STATE_FILE" || return 1
  printf '%s\n' "$next_rev"
  return 0
}

vpn_kit_with_lock state _do_write
rc=$?
exit "$rc"
