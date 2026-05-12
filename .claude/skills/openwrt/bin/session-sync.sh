#!/bin/sh
# session-sync.sh — sync router-authoritative state/journal/notes/quirks to/from client cache.
#
# Usage:
#   session-sync.sh pull --cache-dir <dir>
#   session-sync.sh push --cache-dir <dir>
#   session-sync.sh check-owned-files

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LIB_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/vpn-kit-common.sh
. "$LIB_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

mode="${1:-}"
[ $# -gt 0 ] && shift
cache_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cache-dir) cache_dir="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "session-sync: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

copy_if_exists() {
  _src="$1"
  _dst="$2"
  if [ -f "$_src" ]; then
    mkdir -p "$(dirname "$_dst")"
    cp "$_src" "$_dst"
  fi
}

case "$mode" in
  pull)
    [ -n "$cache_dir" ] || { echo "session-sync: pull needs --cache-dir" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
    mkdir -p "$cache_dir"
    copy_if_exists "$VPN_KIT_STATE_FILE" "$cache_dir/install-state.json"
    copy_if_exists "$VPN_KIT_JOURNAL_FILE" "$cache_dir/events.jsonl"
    copy_if_exists "$VPN_KIT_NOTES_FILE" "$cache_dir/router-notes.md"
    copy_if_exists "$VPN_KIT_QUIRKS_FILE" "$cache_dir/learned-quirks.yaml"
    rev=0
    [ -f "$VPN_KIT_STATE_FILE" ] && rev="$(jq -r '._revision // 0' "$VPN_KIT_STATE_FILE" 2>/dev/null || echo 0)"
    jq -n --argjson revision "$rev" --arg pulled_at "$(vpn_kit_now_iso8601)" '{_sync_base_revision:$revision, pulled_at:$pulled_at}' > "$cache_dir/sync-meta.json"
    ;;
  push)
    [ -n "$cache_dir" ] || { echo "session-sync: push needs --cache-dir" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
    [ -f "$cache_dir/sync-meta.json" ] || { echo "session-sync: missing sync-meta.json" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
    base="$(jq -r '._sync_base_revision // 0' "$cache_dir/sync-meta.json")"
    current=0
    [ -f "$VPN_KIT_STATE_FILE" ] && current="$(jq -r '._revision // 0' "$VPN_KIT_STATE_FILE" 2>/dev/null || echo 0)"
    if [ "$current" != "$base" ]; then
      echo "session-sync: STALE router revision changed base=$base current=$current" >&2
      exit "$VPN_KIT_EXIT_STALE"
    fi
    copy_if_exists "$cache_dir/install-state.json" "$VPN_KIT_STATE_FILE"
    copy_if_exists "$cache_dir/events.jsonl" "$VPN_KIT_JOURNAL_FILE"
    copy_if_exists "$cache_dir/router-notes.md" "$VPN_KIT_NOTES_FILE"
    copy_if_exists "$cache_dir/learned-quirks.yaml" "$VPN_KIT_QUIRKS_FILE"
    ;;
  check-owned-files)
    [ -f "$VPN_KIT_STATE_FILE" ] || exit 2
    mkdir -p "$VPN_KIT_LOCK_DIR"
    drift='[]'
    jq -r '.owned_file_checksums // {} | to_entries[] | [.key, .value] | @tsv' "$VPN_KIT_STATE_FILE" |
    while IFS="$(printf '\t')" read -r path expected; do
      if [ ! -f "$path" ]; then
        actual="missing"
      else
        actual="$(vpn_kit_sha256 < "$path")"
      fi
      if [ "$actual" != "$expected" ]; then
        drift="$(printf '%s' "$drift" | jq --arg path "$path" --arg expected "$expected" --arg actual "$actual" '. + [{path:$path, expected:$expected, actual:$actual}]')"
      fi
      printf '%s\n' "$drift" > "${VPN_KIT_LOCK_DIR}/vpn-kit-owned-drift.$$"
    done
    if [ -f "${VPN_KIT_LOCK_DIR}/vpn-kit-owned-drift.$$" ]; then
      drift="$(cat "${VPN_KIT_LOCK_DIR}/vpn-kit-owned-drift.$$")"
      rm -f "${VPN_KIT_LOCK_DIR}/vpn-kit-owned-drift.$$"
    fi
    printf '%s\n' "$drift" | jq '{status:(if length == 0 then "ok" else "drift" end), drift:.}'
    ;;
  *)
    echo "session-sync: use pull, push, or check-owned-files" >&2
    exit "$VPN_KIT_EXIT_VALIDATION"
    ;;
esac
