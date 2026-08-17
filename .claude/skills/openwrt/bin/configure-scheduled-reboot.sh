#!/usr/bin/env bash
# Install one guarded daily reboot entry without disturbing unrelated cron jobs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  echo "Usage: bin/configure-scheduled-reboot.sh --router <alias> [--ssh-alias <alias>] [--hour 0] [--minute 0]" >&2
  exit 64
}

router=""
ssh_alias=""
hour=0
minute=0
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --hour) hour="${2:-}"; shift 2 ;;
    --minute) minute="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$router" ] || usage
[[ "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || exit 13
[[ "$minute" =~ ^([0-9]|[1-5][0-9])$ ]] || exit 13
if [ -n "$ssh_alias" ]; then
  [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
fi

helper_src="$SKILL_HOME/openwrt/travel-daily-reboot"
[ -f "$helper_src" ] || exit 13
sh -n "$helper_src"

resolve_router_config "$router"
if [ -n "$ssh_alias" ]; then
  ROUTER_SSH_ALIAS="$ssh_alias"
  export ROUTER_SSH_ALIAS
fi
ssh_check_alive 5 || exit 2

backup_args=(--router "$router" --label "before scheduled daily reboot" --quiet)
[ -z "$ssh_alias" ] || backup_args+=(--ssh-alias "$ssh_alias")
snapshot_id="$($SCRIPT_DIR/backup-now.sh "${backup_args[@]}")"

remote_tmp="/tmp/openwrt-skill-travel-daily-reboot.$$"
scp_to "$helper_src" "$remote_tmp"

set +e
ssh_run_remote_with_args /dev/stdin "$hour" "$minute" "$remote_tmp" <<'REMOTE_SH'
set -eu
hour="$1"
minute="$2"
helper_src="$3"
helper=/usr/libexec/travel-daily-reboot
cron_file=/etc/crontabs/root
marker='openwrt-skill: travel-daily-reboot'

cleanup_source() { rm -f "$helper_src"; }
trap cleanup_source EXIT
[ -x /etc/init.d/cron ]
sh -n "$helper_src"

rollback_dir="$(mktemp -d /tmp/scheduled-reboot-rollback.XXXXXX)"
[ ! -f "$cron_file" ] || cp "$cron_file" "$rollback_dir/root.cron"
[ ! -f "$helper" ] || cp "$helper" "$rollback_dir/helper"
success=0
rollback() {
  [ "$success" = 1 ] && return 0
  if [ -f "$rollback_dir/root.cron" ]; then
    cp "$rollback_dir/root.cron" "$cron_file"
  else
    rm -f "$cron_file"
  fi
  if [ -f "$rollback_dir/helper" ]; then
    cp "$rollback_dir/helper" "$helper"
    chmod 755 "$helper"
  else
    rm -f "$helper"
  fi
  /etc/init.d/cron restart >/dev/null 2>&1 || true
}
cleanup() { rollback; rm -rf "$rollback_dir"; cleanup_source; }
on_signal() {
  trap - EXIT INT TERM HUP
  cleanup
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM HUP

mkdir -p /usr/libexec /etc/crontabs
cp "$helper_src" "$helper.tmp.$$"
chmod 755 "$helper.tmp.$$"
mv -f "$helper.tmp.$$" "$helper"

touch "$cron_file"
cron_tmp="$cron_file.tmp.$$"
awk -v marker="$marker" 'index($0, marker) == 0 { print }' "$cron_file" >"$cron_tmp"
printf '%s %s * * * /usr/libexec/travel-daily-reboot # %s\n' "$minute" "$hour" "$marker" >>"$cron_tmp"
chmod 600 "$cron_tmp"
mv -f "$cron_tmp" "$cron_file"

/etc/init.d/cron enable
/etc/init.d/cron restart
sleep 1
/etc/init.d/cron enabled
/etc/init.d/cron running
sh -n "$helper"
[ "$(grep -c "$marker" "$cron_file")" = 1 ]
grep -Fq "$minute $hour * * * /usr/libexec/travel-daily-reboot # $marker" "$cron_file"
TRAVEL_DAILY_REBOOT_DRY_RUN=1 "$helper"

success=1
echo "scheduled_reboot=configured"
echo "schedule=$minute $hour * * *"
echo "cron_enabled=true"
echo "cron_running=true"
REMOTE_SH
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "configure-scheduled-reboot: failed and restored previous cron/helper state (snapshot=$snapshot_id)" >&2
  exit 20
fi

echo "snapshot=$snapshot_id"
memory_journal_append "$router" "scheduled_reboot_configured"
