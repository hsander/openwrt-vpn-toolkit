#!/usr/bin/env bash
# Non-network self-test for the installed OpenWrt rollback runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPENWRT_SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
source "$OPENWRT_SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
source "$OPENWRT_SKILL_HOME/lib/ssh-runner.sh"

router=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: bin/test-lan-migration-runtime.sh --router <alias>"; exit 0 ;;
    *) echo "test-lan-migration-runtime: unknown arg: $1" >&2; exit 13 ;;
  esac
done

resolve_router_config "$router"

ssh_run_remote <<'SH'
set -eu
command -v setsid >/dev/null
command -v flock >/dev/null
[ -x /usr/sbin/vpn-kit-rollback ]
[ -x /usr/sbin/vpn-kit-lan-migrate ]
/etc/init.d/vpn-kit-rollback enabled
/etc/init.d/vpn-kit-rollback running

test_id="lan-selftest-$(date +%s)-$$"
test_root="/tmp/$test_id"
snapshot="/etc/vpn-kit/snapshots/$test_id"
timer="/etc/vpn-kit/rollback.d/$test_id.timer"
marker="$test_root/orphan-marker"
cleanup() {
  rm -f "$timer"
  rm -rf "$test_root" "$snapshot" "/etc/vpn-kit/snapshots/rolled-back/$test_id"
}
trap cleanup EXIT INT TERM
mkdir -p "$test_root" "$snapshot/files"

# Real BusyBox flock proof, including fd inheritance by a child after its
# parent shell exits.
lock_file="$test_root/flock.lock"
ready_file="$test_root/flock.ready"
(
  exec 9>"$lock_file"
  flock -x 9
  sh -c 'sleep 4' &
  printf 'ready\n' > "$ready_file"
) &
holder_pid=$!
while [ ! -f "$ready_file" ]; do sleep 1; done
wait "$holder_pid"
if (exec 8>"$lock_file"; flock -s -n 8); then
  echo 'flock inheritance test failed: child did not retain lock' >&2
  exit 1
fi
sleep 5
(exec 8>"$lock_file"; flock -x -n 8)

# Real BusyBox setsid/negative-PGID proof: a TERM-ignoring child must not write
# after the whole group receives KILL.
setsid sh -c "trap '' TERM; sleep 4; echo escaped > '$marker'" &
group_pid=$!
sleep 1
kill -TERM "-$group_pid" 2>/dev/null || true
sleep 1
kill -KILL "-$group_pid" 2>/dev/null || true
sleep 4
[ ! -e "$marker" ]

# Real rollback-daemon fixture. Only a temporary file is restored.
target="$test_root/config"
printf 'old\n' > "$target"
chmod 0700 "$target"
cp -p "$target" "$snapshot/files/0-config"
printf '{}\n' > "$snapshot/state-before.json"
cat > "$snapshot/meta.json" <<JSON
{"step_id":"$test_id","created_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","restore_state":false,"files":[{"path":"$target","backup":"files/0-config","existed":true}]}
JSON
printf 'new\n' > "$target"
chmod 0644 "$target"
cat > "$timer" <<JSON
{"step_id":"$test_id","timer_type":"lan_migration","deadline_unix":0,"snapshot_path":"$snapshot","state_revision_before":0}
JSON
/usr/sbin/vpn-kit-rollback --once
[ "$(cat "$target")" = old ]
[ -x "$target" ]
[ ! -e "$timer" ]
[ -d "/etc/vpn-kit/snapshots/rolled-back/$test_id" ]

echo 'process_group_test=ok'
echo 'flock_inheritance_test=ok'
echo 'timer_restore_test=ok'
echo 'mode_restore_test=ok'
echo 'runtime_selftest=ok'
SH
