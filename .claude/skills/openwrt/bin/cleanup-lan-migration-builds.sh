#!/usr/bin/env bash
# Remove only unprepared temporary LAN bundle builds from /tmp on a router.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPENWRT_SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"
source "$OPENWRT_SKILL_HOME/lib/router-config.sh"
source "$OPENWRT_SKILL_HOME/lib/ssh-runner.sh"

router=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: bin/cleanup-lan-migration-builds.sh --router <alias>"; exit 0 ;;
    *) echo "cleanup-lan-migration-builds: unknown arg: $1" >&2; exit 13 ;;
  esac
done
resolve_router_config "$router"

ssh_run_remote <<'SH'
set -eu
removed=0
for path in /tmp/vpn-kit-lan99-*.bundle; do
  [ -d "$path" ] || continue
  base="${path#/tmp/}"
  printf '%s\n' "$base" | grep -qE '^vpn-kit-lan99-[0-9]{14}\.bundle$' || {
    echo "cleanup: refusing unexpected path $path" >&2
    exit 13
  }
  rm -rf "$path"
  removed=$((removed + 1))
done
printf 'removed_temp_bundles=%s\n' "$removed"
SH
