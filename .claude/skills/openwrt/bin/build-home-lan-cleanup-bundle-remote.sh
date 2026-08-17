#!/bin/sh
# Build a router-local bundle that removes 192.168.1.0/24 compatibility.
# This script only stages and validates files; it never applies them.

set -eu

migration_id="${1:-}"
old_prefix='192.168.1'
new_prefix='192.168.99'
bundle="${2:-/tmp/vpn-kit-$migration_id.bundle}"

printf '%s' "$migration_id" | grep -qE '^[a-z0-9][a-z0-9-]*$'
for command_name in awk grep ip jq netstat nslookup ping sed sha256sum sing-box ubus uci; do
  command -v "$command_name" >/dev/null || {
    echo "cleanup bundle: required command is missing: $command_name" >&2
    exit 13
  }
done

rm -rf "$bundle"
mkdir -p "$bundle/files" "$bundle/scripts"
cp /etc/config/network "$bundle/files/network"
cp /etc/config/firewall "$bundle/files/firewall"
cp /etc/sing-box/config.json "$bundle/files/sing-box-config.json"
cp /etc/init.d/sing-box-tproxy "$bundle/files/sing-box-tproxy"

# Persist only the final LAN99 address.
uci -c "$bundle/files" -q delete network.lan.ipaddr || true
uci -c "$bundle/files" -q delete network.lan.netmask || true
uci -c "$bundle/files" add_list network.lan.ipaddr="$new_prefix.1/24"
uci -c "$bundle/files" commit network

# Move any remaining LAN redirect target to the matching LAN99 address.
uci -c "$bundle/files" show firewall \
  | sed -n "s/^\([^=]*\.dest_ip\)='$old_prefix\.\([0-9][0-9]*\)'$/\1 \2/p" \
  | while read -r key octet; do
      uci -c "$bundle/files" set "$key=$new_prefix.$octet"
    done
uci -c "$bundle/files" commit firewall

# Remove old listeners/rules and keep the already-created LAN99 equivalents.
jq --arg old "$old_prefix.1" --arg old_prefix "$old_prefix." '
  def strip_old($prefix):
    if type == "array" then
      map(select((type != "string") or (startswith($prefix) | not)))
    else . end;
  (.inbounds | map(select(.listen == $old) | .tag)) as $old_tags
  | .inbounds |= map(select(.listen != $old))
  | .route.rules |= map(
      . as $before
      | if (.inbound? | type) == "array" then
          .inbound |= map(select(. as $value | ($old_tags | index($value) | not)))
        else . end
      | if (.source_ip? | type) == "array" then .source_ip |= strip_old($old_prefix) else . end
      | if (.source_ip_cidr? | type) == "array" then .source_ip_cidr |= strip_old($old_prefix) else . end
      | select(
          (($before.inbound? | type) != "array" or (.inbound | length) > 0)
          and (($before.source_ip? | type) != "array" or (.source_ip | length) > 0)
          and (($before.source_ip_cidr? | type) != "array" or (.source_ip_cidr | length) > 0)
        )
    )
' /etc/sing-box/config.json > "$bundle/files/sing-box-config.json.tmp"
mv "$bundle/files/sing-box-config.json.tmp" "$bundle/files/sing-box-config.json"
sing-box check -c "$bundle/files/sing-box-config.json"
if jq -e '.. | strings | select(contains("192.168.1."))' \
  "$bundle/files/sing-box-config.json" >/dev/null; then
  echo 'cleanup bundle: legacy sing-box reference remains' >&2
  exit 13
fi

grep -v '192\.168\.1\.' /etc/init.d/sing-box-tproxy \
  > "$bundle/files/sing-box-tproxy"
sh -n "$bundle/files/sing-box-tproxy"

cat > "$bundle/scripts/apply.sh" <<'SH'
#!/bin/sh
set -eu
wan_uptime_before="$(ubus call network.interface.wan status | jq -r '.uptime // 0')"
printf '%s\n' "$wan_uptime_before" > "$VPN_KIT_MIGRATION_DIR/wan-uptime-before"

/etc/init.d/sing-box-tproxy restart
ip -4 address show dev br-lan | grep -q '192\.168\.1\.1/24' \
  && ip address del 192.168.1.1/24 dev br-lan \
  || true

if [ -f /tmp/dhcp.leases ]; then
  awk '$3 !~ /^192\.168\.1\./' /tmp/dhcp.leases > /tmp/dhcp.leases.lan99
  mv /tmp/dhcp.leases.lan99 /tmp/dhcp.leases
fi
/etc/init.d/dnsmasq restart
/etc/init.d/firewall reload

wan_uptime_after="$(ubus call network.interface.wan status | jq -r '.uptime // 0')"
[ "$wan_uptime_after" -ge "$wan_uptime_before" ]
printf 'apply_wan_uptime_before=%s\napply_wan_uptime_after=%s\n' \
  "$wan_uptime_before" "$wan_uptime_after"
SH

cat > "$bundle/scripts/verify.sh" <<'SH'
#!/bin/sh
set -eu
verify_fail() { printf 'verify_failed=%s\n' "$1" >&2; exit 13; }
verify_ok() { printf 'verify_ok=%s\n' "$1"; }

ip -4 address show dev br-lan | grep -q '192\.168\.99\.1/24' || verify_fail lan99_address
! ip -4 address show dev br-lan | grep -q '192\.168\.1\.1/24' || verify_fail old_address
! ip -4 route show | grep -q '^192\.168\.1\.0/24 ' || verify_fail old_route
[ "$(uci -q get network.lan.ipaddr)" = '192.168.99.1/24' ] || verify_fail uci_lan
verify_ok lan_address

sing-box check -c /etc/sing-box/config.json || verify_fail sing_box_config
! jq -e '.. | strings | select(contains("192.168.1."))' /etc/sing-box/config.json >/dev/null \
  || verify_fail sing_box_legacy
! grep -q '192\.168\.1\.' /etc/init.d/sing-box-tproxy || verify_fail tproxy_legacy
verify_ok sing_box_cleanup

netstat -lnt 2>/dev/null | grep -q '192\.168\.99\.1:4002' || verify_fail proxy_4002
! netstat -lnt 2>/dev/null | grep -q '192\.168\.1\.1:' || verify_fail old_listener
[ "$(uci -q get firewall.localbackend_8080.dest_ip)" = 192.168.99.165 ] \
  || verify_fail firewall_redirect
! uci -q show firewall | grep -q '192\.168\.1\.' || verify_fail firewall_legacy
verify_ok listeners_firewall

! grep -hE '^dhcp-range=.*192\.168\.1\.' /var/etc/dnsmasq.conf.* 2>/dev/null \
  || verify_fail old_dhcp_range
! awk '$3 ~ /^192\.168\.1\./ {found=1} END {exit found ? 0 : 1}' /tmp/dhcp.leases 2>/dev/null \
  || verify_fail old_dhcp_lease
verify_ok dhcp_cleanup

ubus call network.interface.wan status | jq -e '.up == true' >/dev/null || verify_fail wan
ip -4 route show default | grep -q . || verify_fail default_route
ping -c 1 -W 2 192.168.99.50 >/dev/null || verify_fail home_server
nslookup openwrt.org 127.0.0.1 >/dev/null || verify_fail dns
verify_ok connectivity
SH

cat > "$bundle/scripts/rollback.sh" <<'SH'
#!/bin/sh
set -eu
ip -4 address show dev br-lan | grep -q '192\.168\.1\.1/24' \
  || ip address add 192.168.1.1/24 dev br-lan
/etc/init.d/dnsmasq restart
/etc/init.d/firewall reload
/etc/init.d/sing-box-tproxy restart
SH

chmod 0700 "$bundle/scripts"/*.sh

files='[]'
add_file() {
  _path="$1" _staged="$2" _mode="$3"
  _before="$(sha256sum "$_path" | awk '{print $1}')"
  _after="$(sha256sum "$bundle/$_staged" | awk '{print $1}')"
  files="$(printf '%s' "$files" | jq --arg path "$_path" --arg staged "$_staged" \
    --arg mode "$_mode" --arg before "$_before" --arg after "$_after" \
    '. + [{path:$path,staged:$staged,mode:$mode,before_sha256:$before,staged_sha256:$after}]')"
}

add_file /etc/config/network files/network 0644
add_file /etc/config/firewall files/firewall 0644
add_file /etc/sing-box/config.json files/sing-box-config.json 0644
add_file /etc/init.d/sing-box-tproxy files/sing-box-tproxy 0755

apply_sha="$(sha256sum "$bundle/scripts/apply.sh" | awk '{print $1}')"
verify_sha="$(sha256sum "$bundle/scripts/verify.sh" | awk '{print $1}')"
rollback_sha="$(sha256sum "$bundle/scripts/rollback.sh" | awk '{print $1}')"
printf '%s\n' "$files" | jq \
  --arg migration_id "$migration_id" \
  --arg apply "$apply_sha" --arg verify "$verify_sha" --arg rollback "$rollback_sha" \
  '{schema_version:1,migration_id:$migration_id,files:.,scripts:{apply:$apply,verify:$verify,rollback:$rollback}}' \
  > "$bundle/manifest.json"

jq -e . "$bundle/manifest.json" >/dev/null
printf '%s\n' "$bundle"
