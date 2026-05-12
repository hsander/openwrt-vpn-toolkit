#!/usr/bin/env bats
# Tests for lib/quirks-update.sh.

load helpers

setup()    { setup_test_env; }
teardown() { teardown_test_env; }

@test "quirks: init creates file at revision 1" {
  run "$LIB/quirks-update.sh" init --expected-revision 0 --writer claude-code@t1
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ -f "$VPN_KIT_QUIRKS_FILE" ]
  rev="$(yq '._revision' "$VPN_KIT_QUIRKS_FILE")"
  [ "$rev" = "1" ]
}

@test "quirks: set isp.working_zapret_strategy stores string value" {
  "$LIB/quirks-update.sh" init --expected-revision 0 --writer claude-code@t1 >/dev/null
  "$LIB/quirks-update.sh" set isp.working_zapret_strategy "fakedsplit+badsum" --expected-revision 1 --writer claude-code@t1 >/dev/null
  val="$(yq '.isp.working_zapret_strategy' "$VPN_KIT_QUIRKS_FILE")"
  [ "$val" = "fakedsplit+badsum" ]
  [ "$(yq '._revision' "$VPN_KIT_QUIRKS_FILE")" = "2" ]
}

@test "quirks: set with numeric value is typed as number" {
  "$LIB/quirks-update.sh" init --expected-revision 0 --writer claude-code@t1 >/dev/null
  "$LIB/quirks-update.sh" set hardware.ram_mb 256 --expected-revision 1 --writer claude-code@t1 >/dev/null
  v="$(yq -o=json '.hardware.ram_mb' "$VPN_KIT_QUIRKS_FILE")"
  [ "$v" = "256" ]
}

@test "quirks: set with boolean value is typed as bool" {
  "$LIB/quirks-update.sh" init --expected-revision 0 --writer claude-code@t1 >/dev/null
  "$LIB/quirks-update.sh" set isp.dpi_behavior.tspu_like true --expected-revision 1 --writer claude-code@t1 >/dev/null
  v="$(yq -o=json '.isp.dpi_behavior.tspu_like' "$VPN_KIT_QUIRKS_FILE")"
  [ "$v" = "true" ]
}

@test "quirks: STALE when expected-revision mismatches" {
  "$LIB/quirks-update.sh" init --expected-revision 0 --writer claude-code@t1 >/dev/null
  run "$LIB/quirks-update.sh" set foo.bar "x" --expected-revision 0 --writer claude-code@t1
  [ "$status" -eq 11 ]
}

@test "quirks: set-json stores structured array" {
  "$LIB/quirks-update.sh" init --expected-revision 0 --writer claude-code@t1 >/dev/null
  "$LIB/quirks-update.sh" set-json isp.dpi_behavior.blocks_sni '["youtube.com","rutracker.org"]' --expected-revision 1 --writer claude-code@t1 >/dev/null
  count="$(yq '.isp.dpi_behavior.blocks_sni | length' "$VPN_KIT_QUIRKS_FILE")"
  [ "$count" = "2" ]
}

@test "quirks: unset removes a key" {
  "$LIB/quirks-update.sh" init --expected-revision 0 --writer claude-code@t1 >/dev/null
  "$LIB/quirks-update.sh" set foo.bar "x" --expected-revision 1 --writer claude-code@t1 >/dev/null
  "$LIB/quirks-update.sh" unset foo.bar --expected-revision 2 --writer claude-code@t1 >/dev/null
  v="$(yq '.foo.bar // "MISSING"' "$VPN_KIT_QUIRKS_FILE")"
  [ "$v" = "MISSING" ]
}

@test "quirks: secret-like value is rejected" {
  "$LIB/quirks-update.sh" init --expected-revision 0 --writer claude-code@t1 >/dev/null
  run "$LIB/quirks-update.sh" set telegram.bot_token "bot1234567890:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef" --expected-revision 1 --writer claude-code@t1
  [ "$status" -eq 13 ]
  [ "$(yq '._revision' "$VPN_KIT_QUIRKS_FILE")" = "1" ]
}

@test "quirks: bad writer id is VALIDATION" {
  run "$LIB/quirks-update.sh" init --expected-revision 0 --writer "BAD"
  [ "$status" -eq 13 ]
}

@test "quirks: CAS fields _revision/_last_writer/_last_updated_at present" {
  "$LIB/quirks-update.sh" init --expected-revision 0 --writer claude-code@session-xyz >/dev/null
  writer="$(yq '._last_writer' "$VPN_KIT_QUIRKS_FILE")"
  [ "$writer" = "claude-code@session-xyz" ]
  has_ts="$(yq '._last_updated_at | length > 0' "$VPN_KIT_QUIRKS_FILE")"
  [ "$has_ts" = "true" ]
}
