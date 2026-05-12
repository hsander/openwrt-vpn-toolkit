#!/bin/sh
# journal-append.sh — append one event to /etc/vpn-kit/journal/events.jsonl
#
# Usage:
#   journal-append.sh <type> [key=value]...
#     Auto-adds {"ts": <now>, "type": <type>}. Extra pairs become fields.
#
#   journal-append.sh --json '{"type":"...","ts":"...",...}'
#     Take the full JSON object from arg. Still passed through secret filter.
#
#   journal-append.sh --stdin
#     Read the full JSON object from stdin.
#
# Behavior:
#   - Rejects (exit 13) if the event text matches any secret pattern.
#   - flock'd append on /var/lock/vpn-kit-journal.lock; timeout → exit 12.
#   - Rotates the file after append if > VPN_KIT_JOURNAL_MAX_BYTES.
#
# Exit codes:
#   0   ok
#   12  LOCK
#   13  VALIDATION (bad input or secret detected)

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

mode="kv"
json_arg=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)   mode="json"; json_arg="${2:-}"; shift 2 ;;
    --stdin)  mode="stdin"; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --*) echo "journal-append: unknown flag: $1" >&2
         exit "$VPN_KIT_EXIT_VALIDATION" ;;
    *) break ;;
  esac
done

# _build_event_simple <type> [k=v]...
# Prints one line of compact JSON: {"ts":..., "type":..., k1:v1, ...}.
# Returns 13 on invalid input.
_build_event_simple() {
  _t="$1"; shift
  _n="$(vpn_kit_now_iso8601)"
  _prog='{ts:$ts, type:$type'
  _tmp="$(mktemp -t vpnkit-evt.XXXXXX)"
  # Argument file: one line per token, to survive arbitrary values.
  {
    printf -- '--arg\nts\n%s\n--arg\ntype\n%s\n' "$_n" "$_t"
  } > "$_tmp"
  for pair in "$@"; do
    case "$pair" in
      *=*) : ;;
      *)   echo "journal-append: positional args must be key=value: $pair" >&2
           rm -f "$_tmp"; return 13 ;;
    esac
    _k="${pair%%=*}"
    _v="${pair#*=}"
    case "$_k" in
      *[!a-zA-Z0-9_]*|'')
        echo "journal-append: invalid key: $_k" >&2
        rm -f "$_tmp"; return 13 ;;
    esac
    _prog="$_prog, $_k:\$$_k"
    printf -- '--arg\n%s\n%s\n' "$_k" "$_v" >> "$_tmp"
  done
  _prog="$_prog}"
  # Build jq argv from tmp lines with safe quoting.
  _argv=""
  while IFS= read -r _ln; do
    _q=$(printf '%s' "$_ln" | sed "s/'/'\\\\''/g")
    _argv="$_argv '$_q'"
  done < "$_tmp"
  rm -f "$_tmp"
  eval "jq -c -n $_argv '$_prog'"
}

case "$mode" in
  kv)
    if [ $# -lt 1 ]; then
      echo "journal-append: event type is required" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    fi
    line="$(_build_event_simple "$@")" || exit "$VPN_KIT_EXIT_VALIDATION"
    ;;
  json)
    if ! printf '%s' "$json_arg" | jq -e '.type and .ts' >/dev/null 2>&1; then
      echo "journal-append: --json must be an object with 'type' and 'ts'" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    fi
    line="$(printf '%s' "$json_arg" | jq -c .)"
    ;;
  stdin)
    raw="$(cat)"
    if ! printf '%s' "$raw" | jq -e '.type and .ts' >/dev/null 2>&1; then
      echo "journal-append: stdin must be a JSON object with 'type' and 'ts'" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    fi
    line="$(printf '%s' "$raw" | jq -c .)"
    ;;
esac

# Secret filter — last line of defense.
if printf '%s' "$line" | vpn_kit_contains_secret; then
  echo "journal-append: secret pattern detected, refusing to write" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

_append_and_rotate() {
  mkdir -p "$(dirname "$VPN_KIT_JOURNAL_FILE")" 2>/dev/null || true
  printf '%s\n' "$line" >> "$VPN_KIT_JOURNAL_FILE"
  _sz=$(wc -c < "$VPN_KIT_JOURNAL_FILE" 2>/dev/null || echo 0)
  _sz=$(printf '%s' "$_sz" | tr -d ' ')
  if [ "$_sz" -gt "$VPN_KIT_JOURNAL_MAX_BYTES" ]; then
    _n="$VPN_KIT_JOURNAL_ROTATE_KEEP"
    _i="$_n"
    while [ "$_i" -gt 1 ]; do
      _prev=$((_i - 1))
      [ -f "${VPN_KIT_JOURNAL_FILE}.${_prev}" ] && \
        mv -f "${VPN_KIT_JOURNAL_FILE}.${_prev}" "${VPN_KIT_JOURNAL_FILE}.${_i}"
      _i=$((_i - 1))
    done
    mv -f "$VPN_KIT_JOURNAL_FILE" "${VPN_KIT_JOURNAL_FILE}.1"
    : > "$VPN_KIT_JOURNAL_FILE"
  fi
  return 0
}

vpn_kit_with_lock journal _append_and_rotate
exit $?
