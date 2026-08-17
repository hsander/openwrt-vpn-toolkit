#!/usr/bin/env bash
# Remove the skill-owned backup AWG client and route watchdog from OpenWrt.

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
Usage: bin/remove-resilient-awg.sh --router <alias> [--ssh-alias <alias>]
  --interface <name> --peer-section <name> --target-cidr <cidr> --primary-interface <name>
  [--keep-client]
EOF
  exit 64
}

router=""; ssh_alias=""; interface=""; peer_section=""; target_cidr=""; primary_interface=""; keep_client=0
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --interface) interface="${2:-}"; shift 2 ;;
    --peer-section) peer_section="${2:-}"; shift 2 ;;
    --target-cidr) target_cidr="${2:-}"; shift 2 ;;
    --primary-interface) primary_interface="${2:-}"; shift 2 ;;
    --keep-client) keep_client=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$router" ] && [ -n "$interface" ] && [ -n "$peer_section" ] && \
  [ -n "$target_cidr" ] && [ -n "$primary_interface" ] || usage
for name in "$interface" "$primary_interface"; do [[ "$name" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || exit 13; done
[[ "$peer_section" =~ ^[A-Za-z0-9_]{1,64}$ ]] || exit 13
[[ "$target_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] || exit 13
if [ -n "$ssh_alias" ]; then [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13; fi

resolve_router_config "$router"
if [ -n "$ssh_alias" ]; then ROUTER_SSH_ALIAS="$ssh_alias"; export ROUTER_SSH_ALIAS; fi
ssh_check_alive 5 || exit 2
snapshot_args=(--router "$router" --label "before removing resilient awg" --quiet)
[ -z "$ssh_alias" ] || snapshot_args+=(--ssh-alias "$ssh_alias")
snapshot_id="$($SCRIPT_DIR/backup-now.sh "${snapshot_args[@]}")"

set +e
ssh_run_remote_with_args /dev/stdin "$interface" "$peer_section" "$target_cidr" "$primary_interface" "$keep_client" <<'REMOTE_SH'
set -eu
interface="$1"; peer_section="$2"; target_cidr="$3"; primary_interface="$4"; keep_client="$5"
[ "$(uci -q get network."$interface".openwrt_skill || true)" = resilient_awg ]
[ "$(uci -q get firewall.awg_relay)" = zone ]
[ "$(uci -q get firewall.awg_relay.name)" = awg_relay ]
[ "$(uci -q get firewall.lan_to_awg_relay)" = forwarding ]
[ "$(uci -q get firewall.lan_to_awg_relay.src)" = lan ]
[ "$(uci -q get firewall.lan_to_awg_relay.dest)" = awg_relay ]
[ "$(uci -q get firewall.awg_relay_to_lan)" = forwarding ]
[ "$(uci -q get firewall.awg_relay_to_lan.src)" = awg_relay ]
[ "$(uci -q get firewall.awg_relay_to_lan.dest)" = lan ]
default_before="$(ip -4 route show default)"
config_name="$(printf '%s' "$target_cidr" | tr './' '__')"
config_dir=/etc/resilient-awg-failover.d
config_file="$config_dir/$config_name.conf"
[ -f "$config_file" ]
guard="$(mktemp -d /tmp/remove-resilient-awg.XXXXXX)"
chmod 700 "$guard"
cp /etc/config/network "$guard/network"
cp /etc/config/firewall "$guard/firewall"
for path in /usr/libexec/resilient-awg-failover /etc/init.d/resilient-awg-failover; do
  [ ! -e "$path" ] || cp "$path" "$guard/$(basename "$path")"
done
cp "$config_file" "$guard/target.conf"
/etc/init.d/resilient-awg-failover enabled >/dev/null 2>&1 && touch "$guard/enabled" || true
/etc/init.d/resilient-awg-failover running >/dev/null 2>&1 && touch "$guard/running" || true
success=0
rollback() {
  [ "$success" = 1 ] && return 0
  cp "$guard/network" /etc/config/network
  cp "$guard/firewall" /etc/config/firewall
  for path in /usr/libexec/resilient-awg-failover /etc/init.d/resilient-awg-failover; do
    saved="$guard/$(basename "$path")"; [ ! -f "$saved" ] || cp "$saved" "$path"
  done
  mkdir -p "$config_dir"
  cp "$guard/target.conf" "$config_file"
  [ "$keep_client" = 1 ] || ifup "$interface" >/dev/null 2>&1 || true
  /etc/init.d/firewall reload >/dev/null 2>&1 || true
  [ ! -e "$guard/enabled" ] || /etc/init.d/resilient-awg-failover enable >/dev/null 2>&1 || true
  [ ! -e "$guard/running" ] || /etc/init.d/resilient-awg-failover start >/dev/null 2>&1 || true
}
cleanup() { rollback; rm -rf "$guard"; }
on_signal() { trap - EXIT INT TERM HUP; cleanup; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP

/etc/init.d/resilient-awg-failover stop >/dev/null 2>&1 || true
ip -4 route replace "$target_cidr" dev "$primary_interface" metric 10
rm -f "$config_file" "/var/run/resilient-awg-failover-$config_name.state"

remaining=0
for conf in "$config_dir"/*.conf; do [ ! -f "$conf" ] || remaining=$((remaining + 1)); done
if [ "$keep_client" = 1 ]; then
  if [ "$remaining" -gt 0 ]; then
    /etc/init.d/resilient-awg-failover enable
    /etc/init.d/resilient-awg-failover start
  else
    /etc/init.d/resilient-awg-failover disable >/dev/null 2>&1 || true
  fi
else
  [ "$remaining" = 0 ] || { echo "other_failover_targets_exist=true" >&2; exit 13; }
  /etc/init.d/resilient-awg-failover disable >/dev/null 2>&1 || true
  ifdown "$interface" >/dev/null 2>&1 || true
  uci -q delete network."$peer_section" || true
  uci -q delete network."$interface" || true
  uci -q delete firewall.lan_to_awg_relay || true
  uci -q delete firewall.awg_relay_to_lan || true
  uci -q delete firewall.awg_relay || true
  uci commit network
  uci commit firewall
  /etc/init.d/firewall reload >/dev/null
  rm -f /usr/libexec/resilient-awg-failover /etc/init.d/resilient-awg-failover
  rmdir "$config_dir" >/dev/null 2>&1 || true
  ! uci -q get network."$interface" >/dev/null 2>&1
fi

[ "$(ip -4 route show "$target_cidr" | awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1) }')" = "$primary_interface" ]
[ "$(ip -4 route show default)" = "$default_before" ]
success=1
rm -rf "$guard"
trap - EXIT INT TERM HUP
echo "resilient_awg=removed"
echo "client_retained=$keep_client"
echo "primary_route_restored=true"
echo "default_route_unchanged=true"
REMOTE_SH
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "remove-resilient-awg: failed and restored (snapshot=$snapshot_id)" >&2
  exit 20
fi
echo "snapshot=$snapshot_id"
memory_journal_append "$router" "resilient_awg_removed"
