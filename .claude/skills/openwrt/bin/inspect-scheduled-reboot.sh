#!/usr/bin/env bash
# Read-only inspection of router time, cron, and reboot/watchdog state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"

usage() {
  echo "Usage: bin/inspect-scheduled-reboot.sh --router <alias> [--ssh-alias <alias>]" >&2
  exit 64
}

router=""
ssh_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$router" ] || usage
if [ -n "$ssh_alias" ]; then
  [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
fi

resolve_router_config "$router"
if [ -n "$ssh_alias" ]; then
  ROUTER_SSH_ALIAS="$ssh_alias"
  export ROUTER_SSH_ALIAS
fi
ssh_check_alive 5 || exit 2

ssh_run_remote <<'REMOTE_SH'
set -eu

echo "router_time=$(date '+%Y-%m-%dT%H:%M:%S%z')"
echo "timezone=$(uci -q get system.@system[0].timezone || true)"
echo "zonename=$(uci -q get system.@system[0].zonename || true)"
echo "uptime_seconds=$(awk '{print int($1)}' /proc/uptime)"
[ -e /dev/watchdog ] && echo "hardware_watchdog_device=true" || echo "hardware_watchdog_device=false"
if command -v ubus >/dev/null 2>&1; then
  watchdog_status="$(ubus call system watchdog 2>/dev/null || true)"
  [ -n "$watchdog_status" ] && echo "procd_watchdog_api=true" || echo "procd_watchdog_api=false"
else
  echo "procd_watchdog_api=false"
fi
/etc/init.d/cron enabled >/dev/null 2>&1 && echo "cron_enabled=true" || echo "cron_enabled=false"
/etc/init.d/cron running >/dev/null 2>&1 && echo "cron_running=true" || echo "cron_running=false"
if [ -f /etc/crontabs/root ]; then
  count="$(grep -c 'openwrt-skill: travel-daily-reboot' /etc/crontabs/root 2>/dev/null || true)"
  echo "scheduled_reboot_entries=${count:-0}"
  grep 'openwrt-skill: travel-daily-reboot' /etc/crontabs/root 2>/dev/null || true
else
  echo "scheduled_reboot_entries=0"
fi
[ -x /usr/libexec/travel-daily-reboot ] && echo "scheduled_reboot_helper=true" || echo "scheduled_reboot_helper=false"
REMOTE_SH
