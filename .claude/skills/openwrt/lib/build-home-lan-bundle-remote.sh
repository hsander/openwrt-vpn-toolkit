#!/bin/sh
# Build a home-router migration bundle entirely on the router so VPN secrets
# never leave it. This script does not apply or reload any configuration.

set -eu

migration_id="${1:-}"
old_prefix="${2:-192.168.1}"
new_prefix="${3:-192.168.99}"
bundle="${4:-/tmp/vpn-kit-$migration_id.bundle}"

printf '%s' "$migration_id" | grep -qE '^[a-z0-9][a-z0-9-]*$'
[ "$old_prefix" = 192.168.1 ]
[ "$new_prefix" = 192.168.99 ]

for command_name in awk grep ip jq netstat nslookup ping sed sha256sum sing-box ubus uci; do
  command -v "$command_name" >/dev/null || {
    echo "bundle: required command is missing: $command_name" >&2
    exit 13
  }
done

rm -rf "$bundle"
mkdir -p "$bundle/files" "$bundle/scripts"

for name in network dhcp firewall; do
  cp "/etc/config/$name" "$bundle/files/$name"
done
cp /etc/sing-box/config.json "$bundle/files/sing-box-config.json"
cp /etc/init.d/sing-box-tproxy "$bundle/files/sing-box-tproxy"

# Dual-address LAN. New address is primary; old address remains compatible.
uci -c "$bundle/files" -q delete network.lan.ipaddr || true
uci -c "$bundle/files" -q delete network.lan.netmask || true
uci -c "$bundle/files" add_list network.lan.ipaddr="$new_prefix.1/24"
uci -c "$bundle/files" add_list network.lan.ipaddr="$old_prefix.1/24"
uci -c "$bundle/files" commit network

# Non-overlapping dynamic pool. Existing static reservations keep last octet.
uci -c "$bundle/files" set dhcp.lan.start='200'
uci -c "$bundle/files" set dhcp.lan.limit='50'
uci -c "$bundle/files" show dhcp \
  | sed -n "s/^\([^=]*\.ip\)='$old_prefix\.\([0-9][0-9]*\)'$/\1 \2/p" \
  | while read -r key octet; do
      uci -c "$bundle/files" set "$key=$new_prefix.$octet"
    done

add_reservation() {
  _old_ip="$1" _new_ip="$2" _name="$3"
  _mac="$(awk -v ip="$_old_ip" '$3 == ip {print $2}' /tmp/dhcp.leases | tail -n 1)"
  [ -n "$_mac" ] || { echo "bundle: missing active MAC for $_old_ip" >&2; exit 13; }
  _section="$(uci -c "$bundle/files" add dhcp host)"
  uci -c "$bundle/files" set "dhcp.$_section.name=$_name"
  uci -c "$bundle/files" set "dhcp.$_section.mac=$_mac"
  uci -c "$bundle/files" set "dhcp.$_section.ip=$_new_ip"
}

add_reservation "$old_prefix.150" "$new_prefix.150" 'LGwebOSTV-lan99'
add_reservation "$old_prefix.165" "$new_prefix.165" 'WORK-21135970-lan99'
uci -c "$bundle/files" commit dhcp

# Move home-server redirects immediately because the server already owns
# lan99. Keep the Mac :8080 redirect on its compatibility address until the
# Mac renews into lan99 after commit.
uci -c "$bundle/files" show firewall \
  | sed -n "s/^\([^=]*\.dest_ip\)='$old_prefix\.\(50\)'$/\1 \2/p" \
  | while read -r key octet; do
      uci -c "$bundle/files" set "$key=$new_prefix.$octet"
    done
uci -c "$bundle/files" commit firewall

# Duplicate LAN proxy listeners and their inbound routing rules. Source pins
# retain old entries and gain equivalent lan99 entries.
jq --arg old "$old_prefix.1" --arg new "$new_prefix.1" \
   --arg old_prefix "$old_prefix." --arg new_prefix "$new_prefix." '
  def dual_sources($old_prefix; $new_prefix):
    if type == "array" then
      reduce .[] as $value ([];
        . + [$value]
          + (if ($value | type == "string" and startswith($old_prefix))
             then [$new_prefix + ($value[($old_prefix | length):])]
             else [] end)) | unique
    else . end;
  (.inbounds | map(select(.listen == $old) | {old:.tag,new:(.tag + "-lan99")})) as $maps
  | .inbounds += [.inbounds[] | select(.listen == $old) | .tag += "-lan99" | .listen = $new]
  | .route.rules += [
      .route.rules[] as $rule
      | $maps[] as $mapping
      | select(($rule.inbound // []) | type == "array" and any(. == $mapping.old))
      | $rule
      | .inbound |= map(if . == $mapping.old then $mapping.new else . end)
    ]
  | .route.rules |= map(
      if .source_ip then .source_ip |= dual_sources($old_prefix; $new_prefix) else . end
      | if .source_ip_cidr then .source_ip_cidr |= dual_sources($old_prefix; $new_prefix) else . end)
' /etc/sing-box/config.json > "$bundle/files/sing-box-config.json.tmp"
mv "$bundle/files/sing-box-config.json.tmp" "$bundle/files/sing-box-config.json"
sing-box check -c "$bundle/files/sing-box-config.json"

# Persistent tproxy entries for the compatibility subnet gain lan99 twins.
awk -v old="$old_prefix." -v new="$new_prefix." '
  { print }
  $0 ~ /192\.168\.1\.(139|150|191)(\/32)?/ {
    line=$0
    gsub(old, new, line)
    print line
  }
' /etc/init.d/sing-box-tproxy > "$bundle/files/sing-box-tproxy.tmp"
mv "$bundle/files/sing-box-tproxy.tmp" "$bundle/files/sing-box-tproxy"
sh -n "$bundle/files/sing-box-tproxy"

cat > "$bundle/scripts/apply.sh" <<'SH'
#!/bin/sh
set -eu
wan_uptime_before="$(ubus call network.interface.wan status | jq -r '.uptime // 0')"
printf '%s\n' "$wan_uptime_before" > "$VPN_KIT_MIGRATION_DIR/wan-uptime-before"
printf 'apply_wan_uptime_before=%s\n' "$wan_uptime_before"
ip -4 address show dev br-lan | grep -q '192\.168\.99\.1/24' \
  || ip address add 192.168.99.1/24 dev br-lan
ip -4 address show dev br-lan | sed -n '/inet /p'
/etc/init.d/dnsmasq restart
echo 'apply_dnsmasq=ok'
/etc/init.d/firewall reload
echo 'apply_firewall=ok'
/etc/init.d/sing-box-tproxy restart
echo 'apply_sing_box_tproxy=ok'
wan_uptime_after="$(ubus call network.interface.wan status | jq -r '.uptime // 0')"
[ "$wan_uptime_after" -ge "$wan_uptime_before" ]
printf 'apply_wan_uptime_after=%s\n' "$wan_uptime_after"
SH

cat > "$bundle/scripts/verify.sh" <<'SH'
#!/bin/sh
set -eu
verify_fail() {
  printf 'verify_failed=%s\n' "$1" >&2
  echo 'verify_diagnostic_addresses:' >&2
  ip -4 address show dev br-lan | sed -n '/inet /p' >&2 || true
  echo 'verify_diagnostic_listeners:' >&2
  netstat -lnt 2>/dev/null | grep -E ':(22|53|400[0-9]|4010)[[:space:]]' >&2 || true
  echo 'verify_diagnostic_sing_box_pid:' >&2
  pidof sing-box >&2 || true
  echo 'verify_diagnostic_wan:' >&2
  ubus call network.interface.wan status 2>/dev/null \
    | jq -c '{up,pending,available,uptime,l3_device,proto}' >&2 || true
  exit 13
}

verify_ok() { printf 'verify_ok=%s\n' "$1"; }

ip -4 address show dev br-lan | grep -q '192\.168\.99\.1/24' || verify_fail lan99_address
verify_ok lan99_address
ip -4 address show dev br-lan | grep -q '192\.168\.1\.1/24' || verify_fail compatibility_address
verify_ok compatibility_address
[ "$(uci -q get dhcp.lan.start)" = 200 ] || verify_fail dhcp_start
[ "$(uci -q get dhcp.lan.limit)" = 50 ] || verify_fail dhcp_limit
verify_ok dhcp_pool
sing-box check -c /etc/sing-box/config.json || verify_fail sing_box_config
verify_ok sing_box_config
listener_attempt=0
while ! netstat -lnt 2>/dev/null | grep -q '192\.168\.99\.1:4002'; do
  listener_attempt=$((listener_attempt + 1))
  [ "$listener_attempt" -lt 10 ] || verify_fail proxy_4002_listener
  sleep 1
done
verify_ok proxy_4002_listener
ip -4 route show default | grep -q . || verify_fail default_route
verify_ok default_route
ubus call network.interface.wan status | jq -e '.up == true' >/dev/null || verify_fail wan_up
verify_ok wan_up
ping -c 1 -W 2 192.168.99.50 >/dev/null || verify_fail home_server
verify_ok home_server
nslookup openwrt.org 127.0.0.1 >/dev/null || verify_fail dns
verify_ok dns
SH

cat > "$bundle/scripts/rollback.sh" <<'SH'
#!/bin/sh
set -eu
ip -4 address show dev br-lan | grep -q '192\.168\.99\.1/24' \
  && ip address del 192.168.99.1/24 dev br-lan \
  || true
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
add_file /etc/config/dhcp files/dhcp 0644
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
