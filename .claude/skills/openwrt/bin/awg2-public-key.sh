#!/usr/bin/env bash
# Print only the public key for an existing AWG interface.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"
. "$SKILL_HOME/lib/router-config.sh"
. "$SKILL_HOME/lib/ssh-runner.sh"

router=""; interface=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --interface) interface="${2:-}"; shift 2 ;;
    *) echo "Usage: bin/awg2-public-key.sh --router <alias> --interface <name>" >&2; exit 64 ;;
  esac
done
[[ "$interface" =~ ^[a-zA-Z0-9_]{1,15}$ ]] || exit 13
resolve_router_config "$router"
ssh_check_alive 5 || exit 2
key="$(ssh_run "awg show '$interface' public-key")"
[[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "awg2-public-key: invalid or missing public key" >&2; exit 2; }
printf '%s\n' "$key"
