#!/usr/bin/env bash
# Add a separate, non-default-route AWG relay client to an OpenWrt node.

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
Usage: bin/configure-backup-awg-client.sh --router <alias> [--ssh-alias <alias>]
  --interface <awg2|awg3> --peer-section <name> --tunnel-ip <10.69.0.x>
  --endpoint <IPv4> --server-public-key <key> --allowed-cidr <cidr> [--allowed-cidr <cidr> ...]
EOF
  exit 64
}

router=""; ssh_alias=""; interface=""; peer_section=""; tunnel_ip=""
endpoint=""; server_public_key=""; allowed_cidrs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --interface) interface="${2:-}"; shift 2 ;;
    --peer-section) peer_section="${2:-}"; shift 2 ;;
    --tunnel-ip) tunnel_ip="${2:-}"; shift 2 ;;
    --endpoint) endpoint="${2:-}"; shift 2 ;;
    --server-public-key) server_public_key="${2:-}"; shift 2 ;;
    --allowed-cidr) allowed_cidrs+=("${2:-}"); shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$router" ] && [ -n "$interface" ] && [ -n "$peer_section" ] && \
  [ -n "$tunnel_ip" ] && [ -n "$endpoint" ] && [ -n "$server_public_key" ] && \
  [ "${#allowed_cidrs[@]}" -gt 0 ] || usage
[[ "$interface" =~ ^awg[0-9]{1,2}$ ]] || exit 13
[[ "$peer_section" =~ ^[A-Za-z0-9_]{1,64}$ ]] || exit 13
[[ "$tunnel_ip" =~ ^10\.69\.0\.([0-9]{1,3})$ ]] || exit 13
(( BASH_REMATCH[1] >= 2 && BASH_REMATCH[1] <= 254 )) || exit 13
[[ "$endpoint" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 13
[[ "$server_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || exit 13
if [ -n "$ssh_alias" ]; then
  [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
fi
for cidr in "${allowed_cidrs[@]}"; do
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] || exit 13
  [ "$cidr" != 0.0.0.0/0 ] || {
    echo "configure-backup-awg-client: default route is forbidden" >&2
    exit 13
  }
done
allowed_csv="$(IFS=,; printf '%s' "${allowed_cidrs[*]}")"

resolve_router_config "$router"
if [ -n "$ssh_alias" ]; then
  ROUTER_SSH_ALIAS="$ssh_alias"
  export ROUTER_SSH_ALIAS
fi
ssh_check_alive 5 || exit 2
snapshot_args=(--router "$router" --label "before backup awg client" --quiet)
[ -z "$ssh_alias" ] || snapshot_args+=(--ssh-alias "$ssh_alias")
snapshot_id="$($SCRIPT_DIR/backup-now.sh "${snapshot_args[@]}")"

result_file="$(mktemp)"
trap 'rm -f "$result_file"' EXIT INT TERM HUP
set +e
ssh_run_remote_with_args /dev/stdin "$interface" "$peer_section" "$tunnel_ip" "$endpoint" "$server_public_key" "$allowed_csv" <<'REMOTE_SH' | tee "$result_file"
set -eu
interface="$1"; peer_section="$2"; tunnel_ip="$3"; endpoint="$4"
server_public_key="$5"; allowed_csv="$6"

for cmd in awg uci ip fw4 jsonfilter; do command -v "$cmd" >/dev/null 2>&1 || exit 13; done
modprobe amneziawg
[ -d /sys/module/amneziawg ]
default_before="$(ip -4 route show default)"

if uci -q get network."$interface" >/dev/null 2>&1; then
  [ "$(uci -q get network."$interface".openwrt_skill || true)" = resilient_awg ] || {
    echo "interface_owned_by_skill=false" >&2
    exit 13
  }
  [ "$(uci -q get network."$interface".addresses || true)" = "$tunnel_ip/24" ] || exit 13
  [ "$(uci -q get network."$peer_section".endpoint_host || true)" = "$endpoint" ] || exit 13
  [ "$(uci -q get network."$peer_section".endpoint_port || true)" = 443 ] || exit 13
  [ "$(uci -q get network."$peer_section".public_key || true)" = "$server_public_key" ] || exit 13
  expected_allowed="$(printf '%s' "$allowed_csv" | tr ',' ' ')"
  [ "$(uci -q get network."$peer_section".allowed_ips || true)" = "$expected_allowed" ] || exit 13
  private_key="$(uci -q get network."$interface".private_key)"
  public_key="$(printf '%s' "$private_key" | awg pubkey)"
  firewall_backup="$(mktemp /tmp/backup-awg-firewall.XXXXXX)"
  cp /etc/config/firewall "$firewall_backup"
  cleanup_ok=0
  cleanup_firewall() {
    [ "$cleanup_ok" = 1 ] || {
      cp "$firewall_backup" /etc/config/firewall
      /etc/init.d/firewall reload >/dev/null 2>&1 || true
    }
    rm -f "$firewall_backup"
  }
  cleanup_signal() { trap - EXIT INT TERM HUP; cleanup_firewall; exit 130; }
  trap cleanup_firewall EXIT
  trap cleanup_signal INT TERM HUP
  for section in awg_relay lan_to_awg_relay awg_relay_to_lan; do
    uci -q delete firewall."$section".openwrt_skill || true
  done
  uci commit firewall
  fw4 check >/dev/null
  /etc/init.d/firewall reload >/dev/null
  cleanup_ok=1
  cleanup_firewall
  trap - EXIT INT TERM HUP
  unset private_key server_public_key
  echo "backup_awg_client=already_configured"
  echo "client_public_key=$public_key"
  echo "interface=$interface"
  echo "snapshot_unchanged=true"
  exit 0
fi

backup_dir="$(mktemp -d /tmp/backup-awg-client.XXXXXX)"
chmod 700 "$backup_dir"
cp /etc/config/network "$backup_dir/network"
cp /etc/config/firewall "$backup_dir/firewall"
chmod 600 "$backup_dir"/*
success=0
private_key=""
public_key=""

rollback() {
  [ "$success" = 1 ] && return 0
  ifdown "$interface" >/dev/null 2>&1 || true
  cp "$backup_dir/network" /etc/config/network
  cp "$backup_dir/firewall" /etc/config/firewall
  /etc/init.d/firewall reload >/dev/null 2>&1 || true
}
cleanup() { rollback; rm -rf "$backup_dir"; unset private_key public_key server_public_key; }
on_signal() { trap - EXIT INT TERM HUP; cleanup; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP

private_key="$(awg genkey)"
public_key="$(printf '%s' "$private_key" | awg pubkey)"

for section in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='awg_relay'$/\1/p"); do
  [ "$section" = awg_relay ] || { echo "conflicting_awg_relay_zone=$section" >&2; exit 13; }
done
for section in awg_relay lan_to_awg_relay awg_relay_to_lan; do
  if uci -q get firewall."$section" >/dev/null 2>&1; then
    case "$section" in
      awg_relay)
        [ "$(uci -q get firewall."$section")" = zone ] &&
          [ "$(uci -q get firewall."$section".name || true)" = awg_relay ] || exit 13
        ;;
      lan_to_awg_relay)
        [ "$(uci -q get firewall."$section")" = forwarding ] &&
          [ "$(uci -q get firewall."$section".src || true)" = lan ] &&
          [ "$(uci -q get firewall."$section".dest || true)" = awg_relay ] || exit 13
        ;;
      awg_relay_to_lan)
        [ "$(uci -q get firewall."$section")" = forwarding ] &&
          [ "$(uci -q get firewall."$section".src || true)" = awg_relay ] &&
          [ "$(uci -q get firewall."$section".dest || true)" = lan ] || exit 13
        ;;
    esac
  fi
done

uci set network."$interface"=interface
uci set network."$interface".proto='amneziawg'
uci set network."$interface".private_key="$private_key"
uci add_list network."$interface".addresses="$tunnel_ip/24"
uci set network."$interface".mtu='1360'
uci set network."$interface".openwrt_skill='resilient_awg'
uci set network."$interface".awg_jc='4'
uci set network."$interface".awg_jmin='40'
uci set network."$interface".awg_jmax='70'
uci set network."$interface".awg_s1='42'
uci set network."$interface".awg_s2='16'
uci set network."$interface".awg_s3='40'
uci set network."$interface".awg_s4='100'
uci set network."$interface".awg_h1='65236728'
uci set network."$interface".awg_h2='2314199929'
uci set network."$interface".awg_h3='830645635'
uci set network."$interface".awg_h4='380976151'
uci set network."$interface".awg_i1='<b 0x1a2d0100000100000000000109696e666572656e6365><t><r 15>'

uci set network."$peer_section"="amneziawg_$interface"
uci set network."$peer_section".public_key="$server_public_key"
uci set network."$peer_section".endpoint_host="$endpoint"
uci set network."$peer_section".endpoint_port='443'
uci set network."$peer_section".persistent_keepalive='25'
uci set network."$peer_section".route_allowed_ips='0'
old_ifs="$IFS"; IFS=','
for cidr in $allowed_csv; do uci add_list network."$peer_section".allowed_ips="$cidr"; done
IFS="$old_ifs"

uci -q delete firewall.awg_relay || true
uci set firewall.awg_relay='zone'
uci set firewall.awg_relay.name='awg_relay'
# The relay is also the management path for LuCI/SSH during direct-AWG
# outages; keep router-local services reachable while forwarding remains
# limited by the explicit lan<->relay rules below.
uci set firewall.awg_relay.input='ACCEPT'
uci set firewall.awg_relay.output='ACCEPT'
uci set firewall.awg_relay.forward='REJECT'
uci set firewall.awg_relay.family='ipv4'
uci set firewall.awg_relay.masq='0'
uci add_list firewall.awg_relay.network="$interface"
uci -q delete firewall.lan_to_awg_relay || true
uci set firewall.lan_to_awg_relay='forwarding'
uci set firewall.lan_to_awg_relay.src='lan'
uci set firewall.lan_to_awg_relay.dest='awg_relay'
uci -q delete firewall.awg_relay_to_lan || true
uci set firewall.awg_relay_to_lan='forwarding'
uci set firewall.awg_relay_to_lan.src='awg_relay'
uci set firewall.awg_relay_to_lan.dest='lan'
# Permit only the overlay peer networks needed by this relay.  This is
# intentionally separate from the zone's router-local input policy.
uci -q delete firewall.awg_relay_to_lan.dest_ip || true

uci commit network
uci commit firewall
fw4 check >/dev/null
ifup "$interface"
/etc/init.d/firewall reload >/dev/null

attempt=0
while [ "$attempt" -lt 20 ]; do
  attempt=$((attempt + 1))
  ip link show dev "$interface" >/dev/null 2>&1 && break
  sleep 1
done
ip link show dev "$interface" >/dev/null
ip -4 address show dev "$interface" | grep -Fq "inet $tunnel_ip/24"
awg showconf "$interface" | grep -q '^S3 = 40$'
awg showconf "$interface" | grep -q '^S4 = 100$'
[ "$(ip -4 route show default)" = "$default_before" ]
free_kb="$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo)"
[ "${free_kb:-0}" -ge 20480 ]

success=1
rm -rf "$backup_dir"
trap - EXIT INT TERM HUP
unset private_key server_public_key
echo "backup_awg_client=configured"
echo "client_public_key=$public_key"
echo "interface=$interface"
echo "tunnel_ip=$tunnel_ip"
echo "endpoint=$endpoint:443/udp"
echo "default_route_unchanged=true"
echo "free_kb=$free_kb"
REMOTE_SH
rc=${PIPESTATUS[0]}
set -e
result="$(cat "$result_file")"
rm -f "$result_file"
trap - EXIT INT TERM HUP

if [ "$rc" -ne 0 ]; then
  [ -z "$result" ] || printf '%s\n' "$result" >&2
  echo "configure-backup-awg-client: failed and restored (snapshot=$snapshot_id)" >&2
  exit 20
fi

echo "snapshot=$snapshot_id"
memory_journal_append "$router" "backup_awg_client_configured"
