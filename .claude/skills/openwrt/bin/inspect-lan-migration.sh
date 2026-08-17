#!/usr/bin/env bash
# Read-only, secret-safe inventory used before a LAN migration bundle is built.

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
    -h|--help) echo "Usage: bin/inspect-lan-migration.sh --router <alias>"; exit 0 ;;
    *) echo "inspect-lan-migration: unknown arg: $1" >&2; exit 13 ;;
  esac
done

resolve_router_config "$router"

ssh_run_remote <<'SH'
set -eu

echo '[rollback-runtime]'
[ -x "$(command -v setsid 2>/dev/null || true)" ] && echo 'setsid=present' || echo 'setsid=missing'
[ -x "$(command -v ss 2>/dev/null || true)" ] && echo 'ss=present' || echo 'ss=missing'
[ -x "$(command -v netstat 2>/dev/null || true)" ] && echo 'netstat=present' || echo 'netstat=missing'
[ -x "$(command -v nc 2>/dev/null || true)" ] && echo 'nc=present' || echo 'nc=missing'
[ -x "$(command -v stat 2>/dev/null || true)" ] && echo 'stat=present' || echo 'stat=missing'
busybox 2>/dev/null | grep -q 'stat' && echo 'busybox-stat=present' || echo 'busybox-stat=missing'
[ -e /etc/init.d/sing-box-tproxy ] && {
  stat -c '%a' /etc/init.d/sing-box-tproxy 2>/dev/null \
    || stat -f '%Lp' /etc/init.d/sing-box-tproxy 2>/dev/null \
    || echo 'stat-mode=unsupported'
}
[ -x /usr/sbin/vpn-kit-rollback ] && echo 'wrapper=present' || echo 'wrapper=missing'
[ -x /etc/init.d/vpn-kit-rollback ] && echo 'init=present' || echo 'init=missing'
[ -x /etc/init.d/sing-box-tproxy ] && echo 'sing-box-tproxy=executable' || echo 'sing-box-tproxy=not-executable'
if [ -x /etc/init.d/vpn-kit-rollback ]; then
  /etc/init.d/vpn-kit-rollback running && echo 'running=yes' || echo 'running=no'
  /etc/init.d/vpn-kit-rollback enabled && echo 'enabled=yes' || echo 'enabled=no'
fi

echo '[lan-migrations]'
for status in /etc/vpn-kit/lan-migrations/lan99-*/status.json; do
  [ -f "$status" ] || continue
  current_id="$(jq -r '.migration_id' "$status")"
  if [ -f "/etc/vpn-kit/rollback.d/$current_id.timer" ]; then timer_armed=true; else timer_armed=false; fi
  jq -c --argjson timer_armed "$timer_armed" \
    '{migration_id,state,detail,updated_at,snapshot_path,timer_armed:$timer_armed}' "$status"
done

echo '[network.lan]'
uci -q show network.lan || true
ubus call network.interface.lan status 2>/dev/null \
  | jq -c '{up,pending,available,uptime,l3_device,proto,ipv4_address,route:[.route[]? | select(.target == "192.168.1.0/24" or .target == "192.168.99.0/24") | {target,nexthop,metric}]}' || true

echo '[dnsmasq-live-dhcp-ranges]'
grep -hE '^dhcp-range=' /var/etc/dnsmasq.conf.* 2>/dev/null || true

echo '[network.wan]'
uci -q show network.wan || true
ubus call network.interface.wan status 2>/dev/null \
  | jq -c '{up,pending,available,autostart,dynamic,uptime,l3_device,proto,ipv4_address,route:[.route[]? | select(.target == "0.0.0.0" or .target == "0.0.0.0/0") | {target,nexthop,metric}]}' || true

echo '[interface-protocols]'
ubus call network.interface dump 2>/dev/null \
  | jq -c '[.interface[] | {interface,up,pending,available,autostart,dynamic,proto,l3_device}]' || true

echo '[dhcp.lan-and-hosts]'
uci -q show dhcp.lan || true
uci -q show dhcp | grep -E "=host$|\.name=|\.mac=|\.ip='192\.168\.(1|99)\." || true

echo '[dhcp-active-targets]'
awk '$3 ~ /^192\.168\.1\.(150|165)$/ {print $2, $3, $4}' /tmp/dhcp.leases 2>/dev/null || true

echo '[firewall-redirects]'
uci -q show firewall | grep -E "=redirect$|\.name=|\.src_dport=|\.dest_ip='192\.168\.(1|99)\." || true

echo '[sing-box-lan-inbounds]'
jq -c '[.inbounds[] | select(.listen == "192.168.1.1" or .listen == "192.168.99.1") | {tag,type,listen,listen_port}]' /etc/sing-box/config.json

echo '[sing-box-lan-source-rules]'
jq -c '[.route.rules[] | select(((.source_ip // []) + (.source_ip_cidr // [])) | any(startswith("192.168.1.") or startswith("192.168.99."))) | {source_ip,source_ip_cidr,outbound}]' /etc/sing-box/config.json

echo '[tproxy-lan-lines]'
grep -nE '192\.168\.(1|99)\.(105|139|150|158|191)' /etc/init.d/sing-box-tproxy 2>/dev/null || true

echo '[tproxy-network-actions]'
grep -nE 'network|ifup|ifdown|udhcpc|reload|restart' /etc/init.d/sing-box-tproxy 2>/dev/null || true

echo '[tproxy-service-actions]'
grep -nE 'sing-box|procd|CONFIG|config' /etc/init.d/sing-box-tproxy 2>/dev/null \
  | sed -E 's#(password|uuid|private_key|token)[^ ]*#REDACTED#Ig' || true

echo '[runtime-nft-lan-lines]'
nft -a list chain inet sing_box_tproxy mangle_prerouting 2>/dev/null \
  | grep -E '192\.168\.(1|99)\.(105|139|150|158|191)' || true

echo '[watchdog-lan-lines]'
for path in /usr/bin/polsha-fallback-watchdog /usr/sbin/polsha-fallback-watchdog /etc/polsha-fallback-watchdog.sh; do
  [ -f "$path" ] || continue
  printf '%s\n' "file=$path"
  grep -n '192\.168\.1\.105' "$path" 2>/dev/null || true
done
SH
