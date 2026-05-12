#!/bin/sh
# reachability-check.sh — run one or more post-apply probes.
#
# Usage:
#   reachability-check.sh --command '<shell command>' [--command '<shell command>' ...]
#   reachability-check.sh --state-readable
#
# Exit codes:
#   0  all probes passed
#   13 bad args or a probe failed

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

commands_file=""
state_readable=0

commands_file="$(mktemp -t vpnkit-reachability.XXXXXX)"
trap 'rm -f "$commands_file"' EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --command)
      [ $# -ge 2 ] || { echo "reachability-check: --command needs a value" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
      printf '%s\n' "$2" >> "$commands_file"
      shift 2
      ;;
    --state-readable)
      state_readable=1
      shift
      ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "reachability-check: unknown arg: $1" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
      ;;
  esac
done

if [ "$state_readable" -eq 1 ]; then
  "$SCRIPT_DIR/state-read.sh" >/dev/null || {
    echo "reachability-check: state-read failed" >&2
    exit "$VPN_KIT_EXIT_VALIDATION"
  }
fi

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  if ! sh -c "$cmd"; then
    echo "reachability-check: probe failed: $cmd" >&2
    exit "$VPN_KIT_EXIT_VALIDATION"
  fi
done < "$commands_file"

exit 0
