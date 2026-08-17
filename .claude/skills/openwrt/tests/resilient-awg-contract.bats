#!/usr/bin/env bats

setup() {
  SKILL_HOME="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/bin"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "resilient AWG scripts are syntactically valid" {
  for script in \
    audit-vps-awg-hub.sh \
    install-vps-awg-hub.sh \
    rollback-vps-awg-hub.sh \
    add-vps-awg-peer.sh \
    rollback-vps-awg-peer.sh \
    configure-backup-awg-client.sh \
    install-awg-route-failover.sh \
    remove-resilient-awg.sh \
    verify-resilient-awg.sh; do
    run bash -n "$SKILL_HOME/bin/$script"
    [ "$status" -eq 0 ]
  done
  run sh -n "$SKILL_HOME/openwrt/resilient-awg-failover"
  [ "$status" -eq 0 ]
  run sh -n "$SKILL_HOME/openwrt/init.d/resilient-awg-failover"
  [ "$status" -eq 0 ]
}

@test "router snapshots include resilient AWG state" {
  snapshot="$SKILL_HOME/bin/backup-now.sh"
  run grep -F '/etc/resilient-awg-failover.d' "$snapshot"
  [ "$status" -eq 0 ]
  run grep -F '/etc/init.d/resilient-awg-failover' "$snapshot"
  [ "$status" -eq 0 ]
  run grep -F '/usr/libexec/resilient-awg-failover' "$snapshot"
  [ "$status" -eq 0 ]
}

@test "home watchdog supports independent 001 and 002 route instances" {
  init="$SKILL_HOME/openwrt/init.d/resilient-awg-failover"
  installer="$SKILL_HOME/bin/install-awg-route-failover.sh"
  run grep -F 'for conf in "$CONFIG_DIR"/*.conf' "$init"
  [ "$status" -eq 0 ]
  run grep -F 'procd_open_instance "$name"' "$init"
  [ "$status" -eq 0 ]
  run grep -F "config_name=\"\$(printf '%s' \"\$target_cidr\" | tr './' '__')\"" "$installer"
  [ "$status" -eq 0 ]
  run grep -F -- '--keep-client' "$SKILL_HOME/bin/remove-resilient-awg.sh"
  [ "$status" -eq 0 ]
}

@test "client and failover workflows forbid a backup default route" {
  run grep -F '[ "$cidr" != 0.0.0.0/0 ]' "$SKILL_HOME/bin/configure-backup-awg-client.sh"
  [ "$status" -eq 0 ]
  run grep -F '[ "$target_cidr" != 0.0.0.0/0 ]' "$SKILL_HOME/bin/install-awg-route-failover.sh"
  [ "$status" -eq 0 ]
  run grep -F 'ip -4 route replace "$TARGET_CIDR"' "$SKILL_HOME/openwrt/resilient-awg-failover"
  [ "$status" -eq 0 ]
  run grep -E 'route replace .*default|route add .*default' "$SKILL_HOME/openwrt/resilient-awg-failover"
  [ "$status" -eq 1 ]
}

@test "firewall ownership checks do not add unsupported fw4 options" {
  client="$SKILL_HOME/bin/configure-backup-awg-client.sh"
  run grep -F "uci set firewall.awg_relay.openwrt_skill" "$client"
  [ "$status" -eq 1 ]
  run grep -F 'uci -q delete firewall."$section".openwrt_skill' "$client"
  [ "$status" -eq 0 ]
  run grep -F '[ "$(uci -q get firewall."$section")" = forwarding ]' "$client"
  [ "$status" -eq 0 ]
  run grep -F "uci set firewall.awg_relay.input='ACCEPT'" "$client"
  [ "$status" -eq 0 ]
}

@test "VPS audit records the existing TCP 443 owner without reading secrets" {
  audit="$SKILL_HOME/bin/audit-vps-awg-hub.sh"
  run grep -F 'tcp443_owner_begin' "$audit"
  [ "$status" -eq 0 ]
  run grep -F 'tcp443_listener=present' "$audit"
  [ "$status" -eq 0 ]
  run grep -F 'sed -E' "$audit"
  [ "$status" -eq 0 ]
}

@test "failover can probe an actual LAN target" {
  daemon="$SKILL_HOME/openwrt/resilient-awg-failover"
  installer="$SKILL_HOME/bin/install-awg-route-failover.sh"
  run grep -F 'TARGET_PROBE_IP' "$daemon"
  [ "$status" -eq 0 ]
  run grep -F -- '--target-probe-ip' "$installer"
  [ "$status" -eq 0 ]
}

@test "route daemon fails over and returns after hysteresis" {
  printf '%s\n' awg1 >"$TEST_TMPDIR/route-state"
  : >"$TEST_TMPDIR/actions"
  printf '0\n' >"$TEST_TMPDIR/primary-count"

  cat >"$TEST_TMPDIR/bin/ip" <<'SH'
#!/bin/sh
set -eu
[ "${1:-}" != -4 ] || shift
case "${1:-} ${2:-}" in
  "link show") exit 0 ;;
  "route show")
    target="${3:-}"
    printf '%s dev %s metric 10\n' "$target" "$(cat "$TEST_TMPDIR/route-state")"
    ;;
  "route replace")
    target="$3"; interface="$5"
    printf '%s\n' "$interface" >"$TEST_TMPDIR/route-state"
    printf '%s %s\n' "$target" "$interface" >>"$TEST_TMPDIR/actions"
    ;;
  *) exit 1 ;;
esac
SH
  cat >"$TEST_TMPDIR/bin/ping" <<'SH'
#!/bin/sh
set -eu
eval "address=\${$#}"
if [ "$address" = 10.67.0.1 ]; then
  count="$(cat "$TEST_TMPDIR/primary-count")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$TEST_TMPDIR/primary-count"
  [ "$count" -gt 2 ]
else
  [ "$address" = 10.69.0.2 ]
fi
SH
  cat >"$TEST_TMPDIR/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
  cat >"$TEST_TMPDIR/bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$TEST_TMPDIR/bin/"*

  cat >"$TEST_TMPDIR/failover.conf" <<EOF
TARGET_CIDR='192.168.99.0/24'
PRIMARY_INTERFACE='awg1'
PRIMARY_PROBE_IP='10.67.0.1'
BACKUP_INTERFACE='awg2'
BACKUP_PROBE_IP='10.69.0.2'
INTERVAL_SECONDS='1'
FAIL_THRESHOLD='2'
RECOVER_THRESHOLD='2'
STATE_FILE='$TEST_TMPDIR/mode'
EOF

  run env PATH="$TEST_TMPDIR/bin:$PATH" TEST_TMPDIR="$TEST_TMPDIR" \
    RESILIENT_AWG_MAX_LOOPS=4 \
    "$SKILL_HOME/openwrt/resilient-awg-failover" --config "$TEST_TMPDIR/failover.conf"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/route-state")" = awg1 ]
  [ "$(sed -n '1p' "$TEST_TMPDIR/actions")" = '192.168.99.0/24 awg2' ]
  [ "$(sed -n '2p' "$TEST_TMPDIR/actions")" = '192.168.99.0/24 awg1' ]
  [ "$(wc -l <"$TEST_TMPDIR/actions" | tr -d ' ')" = 2 ]
}

@test "VPS rollback avoids live peer teardown" {
  run grep -F 'runtime_state=blocked_until_reboot' "$SKILL_HOME/bin/rollback-vps-awg-hub.sh"
  [ "$status" -eq 0 ]
  run grep -F 'awg set "$interface" peer "$peer_public_key" remove' "$SKILL_HOME/bin/rollback-vps-awg-hub.sh"
  [ "$status" -eq 1 ]
  run grep -F 'packages_retained=true' "$SKILL_HOME/bin/rollback-vps-awg-hub.sh"
  [ "$status" -eq 0 ]
  run grep -F 'reboot_required=true' "$SKILL_HOME/bin/rollback-vps-awg-peer.sh"
  [ "$status" -eq 0 ]
  run grep -E 'awg set .* peer .* remove' "$SKILL_HOME/bin/rollback-vps-awg-peer.sh"
  [ "$status" -eq 1 ]
}

@test "optional VPS paired LAN survives SSH argument transport" {
  peer="$SKILL_HOME/bin/add-vps-awg-peer.sh"
  run grep -F 'paired_arg="${paired_lan:--}"' "$peer"
  [ "$status" -eq 0 ]
  run grep -F '[ "$paired_lan" != - ] || paired_lan=""' "$peer"
  [ "$status" -eq 0 ]
}

@test "VPS installer pins package hashes and preserves TCP 443" {
  installer="$SKILL_HOME/bin/install-vps-awg-hub.sh"
  run grep -F '2c924076be2ba217eea04f9693291f01c5307a9be5aeee60d04525a50ff2804f' "$installer"
  [ "$status" -eq 0 ]
  run grep -F 'e4dae7515dbb35d5a900f79c04f0a5551449d2bf2e4872a3d08fd22c858aa078' "$installer"
  [ "$status" -eq 0 ]
  run grep -F "sudo ufw allow 443/udp" "$installer"
  [ "$status" -eq 0 ]
  run grep -E 'ufw allow 443/tcp|ListenPort = 443/tcp' "$installer"
  [ "$status" -eq 1 ]
}

@test "VPS rollback output uses the caller-provided SSH alias" {
  run grep -F -- '--ssh-alias $ssh_alias --snapshot $backup_id' "$SKILL_HOME/bin/install-vps-awg-hub.sh"
  [ "$status" -eq 0 ]
  run grep -F -- '--ssh-alias $ssh_alias --snapshot $backup_id' "$SKILL_HOME/bin/add-vps-awg-peer.sh"
  [ "$status" -eq 0 ]
  forbidden_alias="$(printf '%s%s' vpn-usa -7)"
  run grep -F "$forbidden_alias" "$SKILL_HOME/bin/install-vps-awg-hub.sh" "$SKILL_HOME/bin/add-vps-awg-peer.sh"
  [ "$status" -eq 1 ]
}

@test "public skill docs contain no project-specific VPS or router literals" {
  for file in \
    "$SKILL_HOME/SKILL.md" \
    "$SKILL_HOME/runbooks/13-resilient-travel-failover.md" \
    "$SKILL_HOME/../../../README.md" \
    "$SKILL_HOME/../../../README.ru.md"; do
    forbidden_values=(
      "vpn-""usa-7"
      "smartbox-""turbo"
      "openwrt-""smartbox"
      "192.255.""136.74"
      "remna""node"
      "iPhone""Sander"
      "horu""zhenko"
    )
    forbidden_re="$(IFS='|'; printf '%s' "${forbidden_values[*]}")"
    run grep -E "$forbidden_re" "$file"
    [ "$status" -eq 1 ]
  done
}
