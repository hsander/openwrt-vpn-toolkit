#!/usr/bin/env bats
# Tests for minimal profile preflight/detection scripts.

load helpers

setup() {
  setup_test_env
  setup_fake_openwrt_bin
}

teardown() { teardown_test_env; }

@test "detect-system: reports OpenWrt system facts from fake commands" {
  release_dir="$TEST_TMPDIR/etc"
  mkdir -p "$release_dir"
  cat > "$release_dir/openwrt_release" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.2'
DISTRIB_REVISION='r32802-f505120278'
DISTRIB_TARGET='x86/64'
DISTRIB_ARCH='x86_64'
DISTRIB_DESCRIPTION='OpenWrt 25.12.2 r32802-f505120278'
EOF

  # detect-system reads the real /etc/openwrt_release if present, so for local
  # tests we assert stable command-derived fields and parseability.
  run env PATH="$FAKE_BIN:/bin:/usr/bin:/usr/sbin:/sbin" "$SKILL_DIR/scripts/detect-system.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.package_manager == "apk" and .commands.procd == true and .commands.nft == true' >/dev/null
  echo "$output" | jq -e '.ram_mb >= 0 and .flash_free_mb == 12' >/dev/null
}

@test "detect-lan: derives LAN zone, iface and subnet from UCI" {
  run env PATH="$FAKE_BIN:/bin:/usr/bin:/usr/sbin:/sbin" "$SKILL_DIR/scripts/detect-lan.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.zones[] | select(.name == "lan" and (.networks | index("lan")))' >/dev/null
  echo "$output" | jq -e '.lan_ifaces[] | select(.network == "lan" and .iface == "br-lan")' >/dev/null
  echo "$output" | jq -e '.lan_subnets | index("192.168.1.1/24")' >/dev/null
}

@test "check-conflicts: blocks known overlapping services" {
  mkdir -p "$TEST_TMPDIR/etc/init.d"
  touch "$TEST_TMPDIR/etc/init.d/podkop"
  chmod +x "$TEST_TMPDIR/etc/init.d/podkop"
  run env PATH="$FAKE_BIN:/bin:/usr/bin:/usr/sbin:/sbin" VPN_KIT_TEST_ETC="$TEST_TMPDIR/etc" "$SKILL_DIR/scripts/check-conflicts.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "blocked" and (.conflicts[] | select(.id == "podkop"))' >/dev/null
}

@test "preflight-minimal: emits aggregate JSON" {
  run env PATH="$FAKE_BIN:/bin:/usr/bin:/usr/sbin:/sbin" "$SKILL_DIR/scripts/preflight-minimal.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.profile == "minimal" and (.system.package_manager == "apk") and (.lan.lan_ifaces | length >= 1)' >/dev/null
  echo "$output" | jq -e '.status == "ok" or .status == "blocked" or .status == "warnings"' >/dev/null
}
