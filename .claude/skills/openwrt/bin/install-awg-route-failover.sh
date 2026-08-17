#!/usr/bin/env bash
# Install the bounded private-route failover daemon on one OpenWrt node.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"
. "$SKILL_HOME/lib/router-config.sh"
. "$SKILL_HOME/lib/ssh-runner.sh"
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/install-awg-route-failover.sh --router <alias> [--ssh-alias <alias>]
  --target-cidr <cidr> --primary-interface <name> --primary-probe-ip <ip>
  --backup-interface <name> --backup-probe-ip <ip>
  [--target-probe-ip <ip>]
  [--interval 10] [--fail-threshold 3] [--recover-threshold 3]
EOF
  exit 64
}

router=""; ssh_alias=""; target_cidr=""; primary_interface=""; primary_probe_ip=""
backup_interface=""; backup_probe_ip=""; interval=10; fail_threshold=3; recover_threshold=3
target_probe_ip=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --target-cidr) target_cidr="${2:-}"; shift 2 ;;
    --primary-interface) primary_interface="${2:-}"; shift 2 ;;
    --primary-probe-ip) primary_probe_ip="${2:-}"; shift 2 ;;
    --backup-interface) backup_interface="${2:-}"; shift 2 ;;
    --backup-probe-ip) backup_probe_ip="${2:-}"; shift 2 ;;
    --target-probe-ip) target_probe_ip="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --fail-threshold) fail_threshold="${2:-}"; shift 2 ;;
    --recover-threshold) recover_threshold="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$router" ] && [ -n "$target_cidr" ] && [ -n "$primary_interface" ] && \
  [ -n "$primary_probe_ip" ] && [ -n "$backup_interface" ] && [ -n "$backup_probe_ip" ] || usage
[[ "$target_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] || exit 13
[ "$target_cidr" != 0.0.0.0/0 ] || exit 13
for interface in "$primary_interface" "$backup_interface"; do
  [[ "$interface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || exit 13
done
for address in "$primary_probe_ip" "$backup_probe_ip"; do
  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 13
done
if [ -n "$target_probe_ip" ]; then [[ "$target_probe_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 13; fi
for count in "$interval" "$fail_threshold" "$recover_threshold"; do
  [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 && count <= 60 )) || exit 13
done
if [ -n "$ssh_alias" ]; then [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13; fi

daemon_src="$SKILL_HOME/openwrt/resilient-awg-failover"
init_src="$SKILL_HOME/openwrt/init.d/resilient-awg-failover"
sh -n "$daemon_src"
sh -n "$init_src"

resolve_router_config "$router"
if [ -n "$ssh_alias" ]; then ROUTER_SSH_ALIAS="$ssh_alias"; export ROUTER_SSH_ALIAS; fi
ssh_check_alive 5 || exit 2
snapshot_args=(--router "$router" --label "before resilient awg failover" --quiet)
[ -z "$ssh_alias" ] || snapshot_args+=(--ssh-alias "$ssh_alias")
snapshot_id="$($SCRIPT_DIR/backup-now.sh "${snapshot_args[@]}")"

remote_daemon="/tmp/resilient-awg-failover.$$"
remote_init="/tmp/resilient-awg-failover-init.$$"
scp_to "$daemon_src" "$remote_daemon"
scp_to "$init_src" "$remote_init"

set +e
ssh_run_remote_with_args /dev/stdin "$target_cidr" "$primary_interface" "$primary_probe_ip" "$target_probe_ip" \
  "$backup_interface" "$backup_probe_ip" "$interval" "$fail_threshold" "$recover_threshold" \
  "$remote_daemon" "$remote_init" <<'REMOTE_SH'
set -eu
target_cidr="$1"; primary_interface="$2"; primary_probe_ip="$3"; target_probe_ip="$4"
backup_interface="$5"; backup_probe_ip="$6"; interval="$7"
fail_threshold="$8"; recover_threshold="$9"; daemon_src="${10}"; init_src="${11}"

cleanup_sources() { rm -f "$daemon_src" "$init_src"; }
trap cleanup_sources EXIT
for cmd in ip ping procd; do command -v "$cmd" >/dev/null 2>&1 || exit 13; done
ip link show dev "$primary_interface" >/dev/null
ip link show dev "$backup_interface" >/dev/null
ping -I "$primary_interface" -c 2 -W 2 "$primary_probe_ip" >/dev/null
# A newly-created relay may need a keepalive interval before its first probe.
# Validate the interface/config here, but let the daemon establish the first
# handshake after boot instead of making installation depend on transient UDP.
ip link show dev "$backup_interface" >/dev/null
default_before="$(ip -4 route show default)"
route_before="$(ip -4 route show "$target_cidr" | head -n 1)"
printf '%s' "$route_before" | grep -Fq "dev $primary_interface"
sh -n "$daemon_src"
sh -n "$init_src"
config_name="$(printf '%s' "$target_cidr" | tr './' '__')"
config_dir=/etc/resilient-awg-failover.d
config_file="$config_dir/$config_name.conf"

guard="$(mktemp -d /tmp/resilient-awg-failover.XXXXXX)"
chmod 700 "$guard"
for path in \
  /usr/libexec/resilient-awg-failover \
  /etc/init.d/resilient-awg-failover; do
  [ ! -e "$path" ] || cp "$path" "$guard/$(basename "$path")"
done
[ ! -e "$config_file" ] || cp "$config_file" "$guard/target.conf"
/etc/init.d/resilient-awg-failover enabled >/dev/null 2>&1 && touch "$guard/enabled" || true
/etc/init.d/resilient-awg-failover running >/dev/null 2>&1 && touch "$guard/running" || true
success=0

rollback() {
  [ "$success" = 1 ] && return 0
  /etc/init.d/resilient-awg-failover stop >/dev/null 2>&1 || true
  for path in \
    /usr/libexec/resilient-awg-failover \
    /etc/init.d/resilient-awg-failover; do
    saved="$guard/$(basename "$path")"
    if [ -f "$saved" ]; then cp "$saved" "$path"; else rm -f "$path"; fi
  done
  if [ -f "$guard/target.conf" ]; then
    mkdir -p "$config_dir"
    cp "$guard/target.conf" "$config_file"
  else
    rm -f "$config_file"
  fi
  if [ -e "$guard/enabled" ]; then
    /etc/init.d/resilient-awg-failover enable >/dev/null 2>&1 || true
  else
    /etc/init.d/resilient-awg-failover disable >/dev/null 2>&1 || true
  fi
  [ ! -e "$guard/running" ] || /etc/init.d/resilient-awg-failover start >/dev/null 2>&1 || true
  ip -4 route replace "$target_cidr" dev "$primary_interface" metric 10 >/dev/null 2>&1 || true
}
cleanup() { rollback; rm -rf "$guard"; cleanup_sources; }
on_signal() { trap - EXIT INT TERM HUP; cleanup; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP

mkdir -p /usr/libexec
cp "$daemon_src" /usr/libexec/resilient-awg-failover.tmp
chmod 755 /usr/libexec/resilient-awg-failover.tmp
mv -f /usr/libexec/resilient-awg-failover.tmp /usr/libexec/resilient-awg-failover
cp "$init_src" /etc/init.d/resilient-awg-failover.tmp
chmod 755 /etc/init.d/resilient-awg-failover.tmp
mv -f /etc/init.d/resilient-awg-failover.tmp /etc/init.d/resilient-awg-failover

mkdir -p "$config_dir"
chmod 700 "$config_dir"
cat >"$config_file.tmp" <<EOF
# managed by openwrt-skill: resilient-awg
TARGET_CIDR='$target_cidr'
TARGET_PROBE_IP='$target_probe_ip'
PRIMARY_INTERFACE='$primary_interface'
PRIMARY_PROBE_IP='$primary_probe_ip'
BACKUP_INTERFACE='$backup_interface'
BACKUP_PROBE_IP='$backup_probe_ip'
INTERVAL_SECONDS='$interval'
FAIL_THRESHOLD='$fail_threshold'
RECOVER_THRESHOLD='$recover_threshold'
STATE_FILE='/var/run/resilient-awg-failover-$config_name.state'
EOF
chmod 600 "$config_file.tmp"
mv -f "$config_file.tmp" "$config_file"

/etc/init.d/resilient-awg-failover enable
/etc/init.d/resilient-awg-failover restart
sleep 3
/etc/init.d/resilient-awg-failover enabled
/etc/init.d/resilient-awg-failover running
[ "$(ip -4 route show "$target_cidr" | awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1) }')" = "$primary_interface" ]
[ "$(ip -4 route show default)" = "$default_before" ]

success=1
rm -rf "$guard"
trap - EXIT INT TERM HUP
cleanup_sources
echo "route_failover=installed"
echo "target_cidr=$target_cidr"
echo "primary_interface=$primary_interface"
echo "backup_interface=$backup_interface"
echo "config=$config_file"
echo "failover_seconds=$((interval * fail_threshold))"
echo "failback_seconds=$((interval * recover_threshold))"
echo "default_route_unchanged=true"
REMOTE_SH
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "install-awg-route-failover: failed and restored (snapshot=$snapshot_id)" >&2
  exit 20
fi
echo "snapshot=$snapshot_id"
memory_journal_append "$router" "resilient_awg_failover_installed"
