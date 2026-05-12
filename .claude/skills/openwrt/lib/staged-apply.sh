#!/bin/sh
# staged-apply.sh — snapshot -> arm rollback timer -> apply -> verify -> state commit.
#
# Usage:
#   staged-apply.sh --step-id <id> --expected-revision <n> --writer <id> \
#     --new-state <file> --apply '<cmd>' --verify '<cmd>' \
#     [--snapshot-path <path> ...] [--rollback-command '<cmd>'] [--timeout-seconds <n>]

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

step_id=""
expected_rev=""
writer=""
new_state_file=""
apply_cmd=""
verify_cmd=""
rollback_cmd=""
timeout_seconds=90
snapshot_paths_file="$(mktemp -t vpnkit-snapshot-paths.XXXXXX)"
trap 'rm -f "$snapshot_paths_file"' EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --step-id) step_id="${2:-}"; shift 2 ;;
    --expected-revision) expected_rev="${2:-}"; shift 2 ;;
    --writer) writer="${2:-}"; shift 2 ;;
    --new-state) new_state_file="${2:-}"; shift 2 ;;
    --apply) apply_cmd="${2:-}"; shift 2 ;;
    --verify) verify_cmd="${2:-}"; shift 2 ;;
    --rollback-command) rollback_cmd="${2:-}"; shift 2 ;;
    --snapshot-path) printf '%s\n' "${2:-}" >> "$snapshot_paths_file"; shift 2 ;;
    --timeout-seconds) timeout_seconds="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "staged-apply: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

if [ -z "$step_id" ] || [ -z "$expected_rev" ] || [ -z "$writer" ] || \
   [ -z "$new_state_file" ] || [ -z "$apply_cmd" ] || [ -z "$verify_cmd" ]; then
  echo "staged-apply: missing required args" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

vpn_kit_validate_step_id "$step_id" || {
  echo "staged-apply: invalid step id: $step_id" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
}
vpn_kit_validate_writer_id "$writer" || {
  echo "staged-apply: invalid writer: $writer" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
}
case "$expected_rev" in ''|*[!0-9]*) echo "staged-apply: expected revision must be integer" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;; esac
case "$timeout_seconds" in ''|*[!0-9]*) echo "staged-apply: timeout must be integer" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;; esac

if [ ! -f "$new_state_file" ] || ! jq -e 'type == "object"' "$new_state_file" >/dev/null 2>&1; then
  echo "staged-apply: --new-state must point to a JSON object" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

cur_rev=0
if [ -f "$VPN_KIT_STATE_FILE" ]; then
  cur_rev="$(jq -r '._revision // 0' "$VPN_KIT_STATE_FILE" 2>/dev/null || echo 0)"
fi
if [ "$cur_rev" != "$expected_rev" ]; then
  echo "staged-apply: STALE expected=$expected_rev current=$cur_rev" >&2
  exit "$VPN_KIT_EXIT_STALE"
fi

mkdir -p "$VPN_KIT_SNAPSHOT_DIR" "$VPN_KIT_ROLLBACK_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot="$VPN_KIT_SNAPSHOT_DIR/${step_id}-${stamp}-$$"
mkdir -p "$snapshot/files"

if [ -f "$VPN_KIT_STATE_FILE" ]; then
  cp "$VPN_KIT_STATE_FILE" "$snapshot/state-before.json"
else
  printf '{}\n' > "$snapshot/state-before.json"
fi

files_json='[]'
idx=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  backup="files/$idx-$(vpn_kit_safe_name "$path")"
  if [ -e "$path" ]; then
    cp "$path" "$snapshot/$backup"
    existed=true
  else
    existed=false
  fi
  files_json="$(printf '%s' "$files_json" | jq \
    --arg path "$path" --arg backup "$backup" --argjson existed "$existed" \
    '. + [{path:$path, backup:$backup, existed:$existed}]')"
  idx=$((idx + 1))
done < "$snapshot_paths_file"

created_at="$(vpn_kit_now_iso8601)"
printf '%s\n' "$files_json" | jq \
  --arg step_id "$step_id" \
  --arg created_at "$created_at" \
  --arg rollback_command "$rollback_cmd" \
  --argjson rev "$expected_rev" \
  '{step_id:$step_id, created_at:$created_at, state_revision_before:$rev, files:.}
   + (if ($rollback_command | length) > 0 then {rollback_command:$rollback_command} else {} end)' \
  > "$snapshot/meta.json"

deadline=$(( $(date +%s) + timeout_seconds ))
jq -n \
  --arg step_id "$step_id" \
  --arg snapshot_path "$snapshot" \
  --argjson deadline "$deadline" \
  --argjson state_revision_before "$expected_rev" \
  '{step_id:$step_id, deadline_unix:$deadline, snapshot_path:$snapshot_path, state_revision_before:$state_revision_before}' \
  | vpn_kit_atomic_write "$VPN_KIT_ROLLBACK_DIR/$step_id.timer"

"$SCRIPT_DIR/journal-append.sh" staged_apply_started step_id="$step_id" snapshot="$snapshot" state_revision="$expected_rev" >/dev/null

rollback_now() {
  "$SCRIPT_DIR/rollback-snapshot.sh" --snapshot "$snapshot" --step-id "$step_id" --triggered-by explicit
  rm -f "$VPN_KIT_ROLLBACK_DIR/$step_id.timer"
}

if ! sh -c "$apply_cmd"; then
  rollback_now
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

if ! sh -c "$verify_cmd"; then
  rollback_now
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

now_iso="$(vpn_kit_now_iso8601)"
commit_state="$(jq \
  --arg step_id "$step_id" \
  --arg committed_at "$now_iso" \
  --argjson revision_at_commit "$((expected_rev + 1))" \
  '
    .committed_steps = ((.committed_steps // []) + [{
      step_id:$step_id,
      committed_at:$committed_at,
      revision_at_commit:$revision_at_commit
    }])
    | .last_modified_at = $committed_at
  ' "$new_state_file")"

"$SCRIPT_DIR/journal-append.sh" staged_apply_committed step_id="$step_id" snapshot="$snapshot" state_revision="$expected_rev" >/dev/null || {
  rollback_now
  exit "$VPN_KIT_EXIT_VALIDATION"
}

attempt=1
while [ "$attempt" -le 3 ]; do
  if new_rev="$(printf '%s\n' "$commit_state" | "$SCRIPT_DIR/state-write.sh" --expected-revision "$expected_rev" --writer "$writer")"; then
    printf '%s\n' "$new_rev"
    exit 0
  fi
  rc=$?
  if [ "$rc" = "$VPN_KIT_EXIT_STALE" ]; then
    "$SCRIPT_DIR/journal-append.sh" concurrent_write_conflict_unresolved step_id="$step_id" state_revision="$expected_rev" >/dev/null 2>&1 || true
    rollback_now
    exit "$VPN_KIT_EXIT_STALE"
  fi
  if [ "$rc" != "$VPN_KIT_EXIT_LOCK" ]; then
    rollback_now
    exit "$rc"
  fi
  sleep 1
  attempt=$((attempt + 1))
done

"$SCRIPT_DIR/journal-append.sh" concurrent_write_conflict_unresolved step_id="$step_id" state_revision="$expected_rev" >/dev/null 2>&1 || true
rollback_now
exit "$VPN_KIT_EXIT_STALE"
