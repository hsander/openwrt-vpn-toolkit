#!/usr/bin/env bash
# Reboot one registered router and wait for SSH to return.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"
. "$SKILL_HOME/lib/router-config.sh"
. "$SKILL_HOME/lib/ssh-runner.sh"
. "$SKILL_HOME/lib/memory-journal.sh"

router=""; ssh_alias_override=""; timeout_s=180
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias_override="${2:-}"; shift 2 ;;
    --timeout) timeout_s="${2:-}"; shift 2 ;;
    *) echo "Usage: bin/reboot-router.sh --router <alias> [--ssh-alias <alias>] [--timeout 180]" >&2; exit 64 ;;
  esac
done
[[ "$timeout_s" =~ ^[0-9]+$ ]] && (( timeout_s >= 30 && timeout_s <= 600 )) || exit 13
resolve_router_config "$router"
if [ -n "$ssh_alias_override" ]; then
  [[ "$ssh_alias_override" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
  ROUTER_SSH_ALIAS="$ssh_alias_override"
  export ROUTER_SSH_ALIAS
fi
ssh_check_alive 5 || exit 2

before_uptime="$(ssh_run "cut -d. -f1 /proc/uptime")"
ssh_run "sync; ubus call system reboot >/dev/null 2>&1 || reboot" >/dev/null 2>&1 || true

deadline=$((SECONDS + timeout_s))
went_down=0
while (( SECONDS < deadline )); do
  if ssh_check_alive 3; then
    if [ "$went_down" = 1 ]; then
      after_uptime="$(ssh_run "cut -d. -f1 /proc/uptime")"
      if [ "$after_uptime" -lt "$before_uptime" ]; then
        echo "reboot=ok"
        echo "uptime_seconds=$after_uptime"
        memory_journal_append "$router" "router_rebooted"
        exit 0
      fi
    fi
  else
    went_down=1
  fi
  sleep 3
done

echo "reboot-router: SSH did not return after reboot" >&2
exit 2
