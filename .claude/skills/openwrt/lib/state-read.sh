#!/bin/sh
# state-read.sh — read /etc/vpn-kit/install-state.json
#
# Usage:
#   state-read.sh                      # print full JSON to stdout
#   state-read.sh --field _revision    # print one field (jq path, leading dot optional)
#   state-read.sh --revision           # shortcut for --field _revision
#
# Exit codes:
#   0  — ok
#   2  — state file does not exist (caller should go into adopt mode)
#   13 — state file exists but is malformed JSON  (VALIDATION)
#
# Env:
#   VPN_KIT_STATE_FILE (default /etc/vpn-kit/install-state.json)

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

field=""
case "${1:-}" in
  --field)     field="${2:-}"; shift 2 ;;
  --revision)  field="_revision"; shift ;;
  -h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) echo "state-read: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac

if [ ! -f "$VPN_KIT_STATE_FILE" ]; then
  exit 2
fi

# Parse-check first; fail fast with exit 13 on corruption.
if ! jq -e . >/dev/null 2>&1 <"$VPN_KIT_STATE_FILE"; then
  echo "state-read: $VPN_KIT_STATE_FILE is not valid JSON" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

if [ -n "$field" ]; then
  # Normalize: accept "_revision" or "._revision".
  case "$field" in
    .*) jq_path="$field" ;;
    *)  jq_path=".$field" ;;
  esac
  jq -r "$jq_path" <"$VPN_KIT_STATE_FILE"
else
  cat "$VPN_KIT_STATE_FILE"
fi
