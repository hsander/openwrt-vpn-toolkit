#!/usr/bin/env bash
# Reconcile netifd/dnsmasq with the already-committed dual-LAN UCI config.
# Arms an autonomous restore+reboot timer before calling network reload.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPENWRT_SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
source "$OPENWRT_SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
source "$OPENWRT_SKILL_HOME/lib/ssh-runner.sh"

router=""
rollback_snapshot=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --rollback-snapshot) rollback_snapshot="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --router home --rollback-snapshot snap-YYYYMMDDTHHMMSSZ"
      exit 0 ;;
    *) echo "reconcile-home-lan-runtime: unknown arg: $1" >&2; exit 13 ;;
  esac
done

[[ "$rollback_snapshot" =~ ^snap-[0-9]{8}T[0-9]{6}Z$ ]] || {
  echo 'reconcile-home-lan-runtime: invalid rollback snapshot' >&2
  exit 13
}

resolve_router_config "$router"

pre_snapshot="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
  --label 'before netifd LAN99 reconciliation' --quiet)"
[[ -n "$pre_snapshot" ]] || { echo 'reconcile: pre-snapshot failed' >&2; exit 13; }

scp_to "$SCRIPT_DIR/lan99-reconcile-rollback-remote.sh" /tmp/lan99-reconcile-rollback

arm_result="$(ssh_run_remote_with_args /dev/stdin "$rollback_snapshot" <<'SH'
set -eu
rollback_snapshot="$1"
timer='/etc/vpn-kit/rollback.d/lan99-reconcile.timer'
handler='/usr/local/sbin/vpn-kit-lan99-reconcile-rollback'

[ -f "/etc/vpn-kit/snapshots/$rollback_snapshot.tar.gz" ]
[ -f "/etc/vpn-kit/snapshots/$rollback_snapshot.meta.json" ]
[ -x /usr/sbin/vpn-kit-rollback ]
/etc/init.d/vpn-kit-rollback enabled
/etc/init.d/vpn-kit-rollback running

mkdir -p /usr/local/sbin
cp /tmp/lan99-reconcile-rollback "$handler.new"
chmod 0700 "$handler.new"
mv -f "$handler.new" "$handler"
rm -f /tmp/lan99-reconcile-rollback
mkdir -p /etc/vpn-kit/rollback.d
deadline=$(( $(date +%s) + 300 ))
jq -n \
  --arg step_id lan99-reconcile \
  --arg snapshot_path "/etc/vpn-kit/snapshots/$rollback_snapshot.tar.gz" \
  --arg handler_command "$handler $rollback_snapshot" \
  --argjson deadline_unix "$deadline" \
  '{step_id:$step_id,timer_type:"lan_migration",deadline_unix:$deadline_unix,
    snapshot_path:$snapshot_path,state_revision_before:0,handler_command:$handler_command}' \
  > "$timer.new"
mv "$timer.new" "$timer"
sync
printf 'timer_armed=true\ndeadline_unix=%s\n' "$deadline"
SH
)"
printf '%s\n' "$arm_result"
printf 'pre_reconcile_snapshot=%s\n' "$pre_snapshot"

# Run detached so an expected SSH interruption cannot stop the reload.
ssh_run "setsid sh -c 'ubus call network reload >/etc/vpn-kit/lan99-reconcile.log 2>&1' </dev/null &" \
  >/dev/null 2>&1 || true

validated=0
for _ in {1..24}; do
  sleep 5
  if ssh_run_remote <<'SH' >/dev/null 2>&1
set -eu
ip -4 address show dev br-lan | grep -q '192\.168\.99\.1/24'
ip -4 address show dev br-lan | grep -q '192\.168\.1\.1/24'
ubus call network.interface.lan status \
  | jq -e 'any(."ipv4-address"[]?; .address == "192.168.99.1")' >/dev/null
grep -hE '^dhcp-range=set:lan,192\.168\.99\.200,192\.168\.99\.249,255\.255\.255\.0,12h$' \
  /var/etc/dnsmasq.conf.* >/dev/null
ubus call network.interface.wan status | jq -e '.up == true' >/dev/null
ip -4 route show default | grep -q .
ping -c 1 -W 2 192.168.99.50 >/dev/null
nslookup openwrt.org 127.0.0.1 >/dev/null
SH
  then
    if curl -fsS --max-time 8 https://api.ipify.org >/dev/null \
      && curl -fsS --max-time 10 --proxy http://192.168.99.1:4002 https://api.ipify.org >/dev/null; then
      validated=1
      break
    fi
  fi
done

if [[ "$validated" != 1 ]]; then
  echo 'reconcile: validation failed; autonomous rollback remains armed' >&2
  exit 20
fi

ssh_run_remote <<'SH'
set -eu
rm -f /etc/vpn-kit/rollback.d/lan99-reconcile.timer
rm -f /usr/local/sbin/vpn-kit-lan99-reconcile-rollback
sync
echo 'timer_armed=false'
echo 'reconcile_state=committed'
SH
