#!/usr/bin/env bats
# Tests for minimal profile renderer and installer.

load helpers

setup()    { setup_test_env; }
teardown() { teardown_test_env; }

sample_vless_url() {
  printf '%s\n' 'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxyzABCDEFGH&sid=abcd&type=tcp&flow=xtls-rprx-vision#node'
}

@test "render-minimal-config: renders valid sing-box JSON from VLESS Reality URL" {
  out="$TEST_TMPDIR/config.json"
  run "$SKILL_DIR/scripts/render-minimal-config.sh" \
    --vless-url "$(sample_vless_url)" \
    --node-name test-node \
    --listen 0.0.0.0 \
    --port 4000 \
    --output "$out"
  [ "$status" -eq 0 ]
  jq -e '.inbounds[0].type == "mixed" and .inbounds[0].listen_port == 4000' "$out" >/dev/null
  jq -e '.outbounds[0].server == "example.com" and .outbounds[0].uuid == "11111111-1111-1111-1111-111111111111"' "$out" >/dev/null
}

@test "render-minimal-config: test direct outbound keeps proxy plumbing without real VLESS traffic" {
  out="$TEST_TMPDIR/config-direct.json"
  run "$SKILL_DIR/scripts/render-minimal-config.sh" \
    --vless-url "$(sample_vless_url)" \
    --node-name test-node \
    --port 4000 \
    --test-direct-outbound \
    --output "$out"
  [ "$status" -eq 0 ]
  jq -e '.route.final == "direct" and (.outbounds | length == 1) and .outbounds[0].tag == "direct"' "$out" >/dev/null
}

@test "install-minimal: installs file set into target root and updates state" {
  target="$TEST_TMPDIR/router-root"
  run "$SKILL_DIR/scripts/install-minimal.sh" \
    --root "$target" \
    --writer claude-code@minimal \
    --vless-url "$(sample_vless_url)" \
    --node-name test-node \
    --port 4000
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .profile == "minimal" and .proxy_port == 4000' >/dev/null

  [ -s "$target/etc/sing-box/config.json" ]
  [ -x "$target/etc/init.d/sing-box-tproxy" ]
  [ -x "$target/usr/bin/dns-watchdog.sh" ]
  [ -x "$target/usr/bin/vpn-nodes-watchdog.sh" ]
  [ -f "$target/etc/vpn-kit/firewall/lan-proxy-4000.uci" ]
  [ -f "$target/etc/vpn-kit/cron/minimal.crontab" ]

  jq -e '.components["sing-box"].config_sha256 | test("^[0-9a-f]{64}$")' "$target/etc/vpn-kit/install-state.json" >/dev/null
  jq -e '.proxy_ports[] | select(.port == 4000 and .type == "mixed")' "$target/etc/vpn-kit/install-state.json" >/dev/null
  jq -e '.files_owned_by_skill | index("'"$target"'/etc/sing-box/config.json")' "$target/etc/vpn-kit/install-state.json" >/dev/null
}

@test "install-minimal: --activate records rootfs activation plan without host service changes" {
  target="$TEST_TMPDIR/router-root"
  run "$SKILL_DIR/scripts/install-minimal.sh" \
    --root "$target" \
    --activate \
    --writer claude-code@minimal \
    --vless-url "$(sample_vless_url)" \
    --node-name test-node \
    --port 4000
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .activated == 1 and .revision == 3' >/dev/null

  [ -f "$target/etc/vpn-kit/activation/minimal.commands.log" ]
  grep -F "apk add sing-box jq curl ca-bundle" "$target/etc/vpn-kit/activation/minimal.commands.log" >/dev/null
  grep -F "sing-box check -c \"$target/etc/sing-box/config.json\"" "$target/etc/vpn-kit/activation/minimal.commands.log" >/dev/null
  grep -F "uci set firewall.vpn_kit_lan_proxy_4000=rule" "$target/etc/vpn-kit/activation/minimal.commands.log" >/dev/null
  grep -F "/etc/init.d/sing-box-tproxy restart" "$target/etc/vpn-kit/activation/minimal.commands.log" >/dev/null

  jq -e '.components["sing-box"].activated == true and .components["sing-box"].activation_mode == "rootfs-simulated"' "$target/etc/vpn-kit/install-state.json" >/dev/null
  jq -e '.activation.services | index("sing-box-tproxy") and index("cron")' "$target/etc/vpn-kit/install-state.json" >/dev/null
}
