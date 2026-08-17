#!/bin/sh
# rollback-snapshot.sh — restore files and semantic state from a staged-apply snapshot.
#
# Usage:
#   rollback-snapshot.sh --snapshot <path> --step-id <id> [--triggered-by timer|explicit|daemon]

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

snapshot=""
step_id=""
triggered_by="explicit"

while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) snapshot="${2:-}"; shift 2 ;;
    --step-id) step_id="${2:-}"; shift 2 ;;
    --triggered-by) triggered_by="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "rollback-snapshot: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

if [ -z "$snapshot" ] || [ -z "$step_id" ]; then
  echo "rollback-snapshot: --snapshot and --step-id are required" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

if ! vpn_kit_validate_step_id "$step_id"; then
  echo "rollback-snapshot: invalid step id: $step_id" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

meta="$snapshot/meta.json"
if [ ! -f "$meta" ] || ! jq -e . "$meta" >/dev/null 2>&1; then
  echo "rollback-snapshot: missing or invalid snapshot metadata: $meta" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

count="$(jq '.files | length' "$meta")"
i=0
while [ "$i" -lt "$count" ]; do
  path="$(jq -r ".files[$i].path" "$meta")"
  existed="$(jq -r ".files[$i].existed" "$meta")"
  backup="$(jq -r ".files[$i].backup // \"\"" "$meta")"
  mode="$(jq -r ".files[$i].mode // \"\"" "$meta")"
  if [ "$existed" = "true" ]; then
    mkdir -p "$(dirname "$path")"
    cp -p "$snapshot/$backup" "$path"
    [ -z "$mode" ] || chmod "$mode" "$path"
  else
    rm -f "$path"
  fi
  i=$((i + 1))
done

rollback_command="$(jq -r '.rollback_command // ""' "$meta")"
if [ -n "$rollback_command" ]; then
  sh -c "$rollback_command"
fi

restore_state="$(jq -r 'if has("restore_state") then .restore_state else true end' "$meta")"
if [ "$restore_state" = true ] && [ -f "$snapshot/state-before.json" ]; then
  cur_rev=0
  if [ -f "$VPN_KIT_STATE_FILE" ]; then
    cur_rev="$(jq -r '._revision // 0' "$VPN_KIT_STATE_FILE" 2>/dev/null || echo 0)"
  fi
  state_payload="$(jq 'del(._revision, ._last_writer, ._last_writer_host, ._last_updated_at)' "$snapshot/state-before.json")"
  printf '%s\n' "$state_payload" | "$SCRIPT_DIR/state-write.sh" \
    --expected-revision "$cur_rev" \
    --writer "vpn-kit-rollback@$step_id" >/dev/null
fi

mkdir -p "$VPN_KIT_SNAPSHOT_DIR/rolled-back"
rolled_path="$VPN_KIT_SNAPSHOT_DIR/rolled-back/$(basename "$snapshot")"
if [ "$snapshot" != "$rolled_path" ]; then
  rm -rf "$rolled_path"
  mv "$snapshot" "$rolled_path"
fi

state_rev=0
if [ -f "$VPN_KIT_STATE_FILE" ]; then
  state_rev="$(jq -r '._revision // 0' "$VPN_KIT_STATE_FILE" 2>/dev/null || echo 0)"
fi

"$SCRIPT_DIR/journal-append.sh" staged_apply_rolled_back \
  step_id="$step_id" \
  snapshot="$rolled_path" \
  triggered_by="$triggered_by" \
  state_revision="$state_rev" >/dev/null
