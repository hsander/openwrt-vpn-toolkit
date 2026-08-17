#!/usr/bin/env bats

load helpers

setup() {
  setup_test_env
  export VPN_KIT_TARGET_ROOT="$TEST_TMPDIR/root"
  export VPN_KIT_LAN_MIGRATION_DIR="/etc/vpn-kit/lan-migrations"
  mkdir -p "$VPN_KIT_TARGET_ROOT/etc/config" "$TEST_TMPDIR/bundle/files" "$TEST_TMPDIR/bundle/scripts"
  echo old > "$VPN_KIT_TARGET_ROOT/etc/config/network"
  echo new > "$TEST_TMPDIR/bundle/files/network"
  before="$(sha256sum "$VPN_KIT_TARGET_ROOT/etc/config/network" | awk '{print $1}')"
  staged="$(sha256sum "$TEST_TMPDIR/bundle/files/network" | awk '{print $1}')"
  cat > "$TEST_TMPDIR/bundle/manifest.json" <<JSON
{"schema_version":1,"migration_id":"lan-test","files":[{"path":"/etc/config/network","staged":"files/network","mode":"0644","before_sha256":"$before","staged_sha256":"$staged"}]}
JSON
  cat > "$TEST_TMPDIR/bundle/scripts/apply.sh" <<'SH'
#!/bin/sh
echo apply >> "$VPN_KIT_MIGRATION_DIR/actions"
SH
  cat > "$TEST_TMPDIR/bundle/scripts/verify.sh" <<'SH'
#!/bin/sh
test "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = new
SH
  cat > "$TEST_TMPDIR/bundle/scripts/rollback.sh" <<'SH'
#!/bin/sh
echo rollback >> "$VPN_KIT_MIGRATION_DIR/actions"
SH
  apply_sha="$(sha256sum "$TEST_TMPDIR/bundle/scripts/apply.sh" | awk '{print $1}')"
  verify_sha="$(sha256sum "$TEST_TMPDIR/bundle/scripts/verify.sh" | awk '{print $1}')"
  rollback_sha="$(sha256sum "$TEST_TMPDIR/bundle/scripts/rollback.sh" | awk '{print $1}')"
  jq --arg apply "$apply_sha" --arg verify "$verify_sha" --arg rollback "$rollback_sha" \
    '.scripts = {apply:$apply,verify:$verify,rollback:$rollback}' \
    "$TEST_TMPDIR/bundle/manifest.json" > "$TEST_TMPDIR/bundle/manifest.tmp"
  mv "$TEST_TMPDIR/bundle/manifest.tmp" "$TEST_TMPDIR/bundle/manifest.json"
}

teardown() { teardown_test_env; }

runtime() {
  "$LIB/lan-migrate-runtime.sh" "$@"
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

@test "prepare snapshots but does not apply" {
  run runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle"
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = old ]
  echo "$output" | jq -e '.state == "prepared"' >/dev/null
  [ ! -e "$VPN_KIT_ROLLBACK_DIR/lan-test.timer" ]
}

@test "cutover stays unconfirmed and rollback restores files" {
  chmod 0600 "$VPN_KIT_TARGET_ROOT/etc/config/network"
  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  run runtime cutover --migration-id lan-test --timeout-seconds 60 --foreground
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = new ]
  [ "$(mode_of "$VPN_KIT_TARGET_ROOT/etc/config/network")" = 644 ]
  echo "$output" | jq -e '.state == "applied_unconfirmed"' >/dev/null
  [ -f "$VPN_KIT_ROLLBACK_DIR/lan-test.timer" ]

  run runtime rollback --migration-id lan-test
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = old ]
  [ "$(mode_of "$VPN_KIT_TARGET_ROOT/etc/config/network")" = 600 ]
  echo "$output" | jq -e '.state == "rolled_back"' >/dev/null
}

@test "confirm removes timer only after verify" {
  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  runtime cutover --migration-id lan-test --timeout-seconds 60 --foreground >/dev/null
  run runtime confirm --migration-id lan-test
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state == "committed"' >/dev/null
  [ ! -e "$VPN_KIT_ROLLBACK_DIR/lan-test.timer" ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = new ]
}

@test "prepare fails closed on stale source checksum" {
  echo drift > "$VPN_KIT_TARGET_ROOT/etc/config/network"
  run runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle"
  [ "$status" -eq 11 ]
  [ ! -e "$VPN_KIT_TARGET_ROOT/etc/vpn-kit/lan-migrations/lan-test" ]
}

@test "cutover fails closed if a prepared script drifts" {
  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  migration_dir="$VPN_KIT_TARGET_ROOT/etc/vpn-kit/lan-migrations/lan-test"
  echo '# drift' >> "$migration_dir/scripts/apply.sh"
  run runtime cutover --migration-id lan-test --timeout-seconds 60 --foreground
  [ "$status" -eq 11 ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = old ]
  [ ! -e "$VPN_KIT_ROLLBACK_DIR/lan-test.timer" ]
}

@test "expired timer restores without caller" {
  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  runtime cutover --migration-id lan-test --timeout-seconds 60 --foreground >/dev/null
  jq '.deadline_unix = 0' "$VPN_KIT_ROLLBACK_DIR/lan-test.timer" > "$VPN_KIT_ROLLBACK_DIR/lan-test.timer.tmp"
  mv "$VPN_KIT_ROLLBACK_DIR/lan-test.timer.tmp" "$VPN_KIT_ROLLBACK_DIR/lan-test.timer"
  run "$LIB/vpn-kit-rollback.sh" --once
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = old ]
  status_file="$VPN_KIT_TARGET_ROOT/etc/vpn-kit/lan-migrations/lan-test/status.json"
  [ "$(jq -r '.state' "$status_file")" = rolled_back ]
}

@test "rollback preempts a stuck transition owner" {
  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  runtime cutover --migration-id lan-test --timeout-seconds 60 --foreground >/dev/null
  fake_bin="$TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/setsid" <<'SH'
#!/bin/sh
exec python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
SH
  chmod +x "$fake_bin/setsid"
  PATH="$fake_bin:$PATH" env VPN_KIT_TEST_HOLD_LOCK_SECONDS=60 setsid \
    "$LIB/lan-migrate-runtime.sh" status --migration-id lan-test >/dev/null 2>&1 &
  stuck_pid=$!
  lock="$VPN_KIT_LOCK_DIR/vpn-kit-lan-lan-test.lock.owner.json"
  for _ in 1 2 3 4 5; do
    [ -f "$lock" ] && break
    sleep 1
  done
  [ -f "$lock" ]

  run runtime rollback --migration-id lan-test
  [ "$status" -eq 0 ]
  ! kill -0 "$stuck_pid" 2>/dev/null
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = old ]
  status_file="$VPN_KIT_TARGET_ROOT/etc/vpn-kit/lan-migrations/lan-test/status.json"
  [ "$(jq -r '.state' "$status_file")" = rolled_back ]
}

@test "detached cutover acknowledges only after rollback timer exists" {
  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  run runtime cutover --migration-id lan-test --timeout-seconds 60
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.rollback_armed == true' >/dev/null
  [ -f "$VPN_KIT_ROLLBACK_DIR/lan-test.timer" ]
}

@test "rollback from prepared cancels without restoring later file changes" {
  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  echo later > "$VPN_KIT_TARGET_ROOT/etc/config/network"
  run runtime rollback --migration-id lan-test
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = later ]
  status_file="$VPN_KIT_TARGET_ROOT/etc/vpn-kit/lan-migrations/lan-test/status.json"
  [ "$(jq -r '.state' "$status_file")" = cancelled ]
}

@test "rollback rejects a committed migration" {
  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  runtime cutover --migration-id lan-test --timeout-seconds 60 --foreground >/dev/null
  runtime confirm --migration-id lan-test >/dev/null
  run runtime rollback --migration-id lan-test
  [ "$status" -eq 11 ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = new ]
}

@test "LAN rollback does not restore unrelated install state" {
  write_minimal_state
  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  runtime cutover --migration-id lan-test --timeout-seconds 60 --foreground >/dev/null
  jq '.unrelated_change = true' "$VPN_KIT_STATE_FILE" > "$VPN_KIT_STATE_FILE.tmp"
  mv "$VPN_KIT_STATE_FILE.tmp" "$VPN_KIT_STATE_FILE"
  runtime rollback --migration-id lan-test >/dev/null
  [ "$(jq -r '.unrelated_change' "$VPN_KIT_STATE_FILE")" = true ]
}

@test "rollback kills the detached apply process group before restore" {
  fake_bin="$TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/setsid" <<'SH'
#!/bin/sh
exec python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
SH
  chmod +x "$fake_bin/setsid"
  export PATH="$fake_bin:$PATH"
  marker="$TEST_TMPDIR/orphan-marker"
  cat > "$TEST_TMPDIR/bundle/scripts/apply.sh" <<SH
#!/bin/sh
trap '' TERM
sleep 5
echo orphan > '$marker'
SH
  apply_sha="$(sha256sum "$TEST_TMPDIR/bundle/scripts/apply.sh" | awk '{print $1}')"
  jq --arg apply "$apply_sha" '.scripts.apply = $apply' "$TEST_TMPDIR/bundle/manifest.json" \
    > "$TEST_TMPDIR/bundle/manifest.tmp"
  mv "$TEST_TMPDIR/bundle/manifest.tmp" "$TEST_TMPDIR/bundle/manifest.json"

  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  runtime cutover --migration-id lan-test --timeout-seconds 60 >/dev/null
  runtime rollback --migration-id lan-test >/dev/null
  sleep 6
  [ ! -e "$marker" ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = old ]
}

@test "rollback kills a hanging confirm verify process group" {
  fake_bin="$TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/setsid" <<'SH'
#!/bin/sh
exec python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
SH
  chmod +x "$fake_bin/setsid"
  export PATH="$fake_bin:$PATH"
  marker="$TEST_TMPDIR/confirm-orphan-marker"
  cat > "$TEST_TMPDIR/bundle/scripts/verify.sh" <<SH
#!/bin/sh
if [ -f "\$VPN_KIT_MIGRATION_DIR/hang-confirm" ]; then
  trap '' TERM
  sleep 5
  echo escaped > '$marker'
fi
test "\$(cat "\$VPN_KIT_TARGET_ROOT/etc/config/network")" = new
SH
  verify_sha="$(sha256sum "$TEST_TMPDIR/bundle/scripts/verify.sh" | awk '{print $1}')"
  jq --arg verify "$verify_sha" '.scripts.verify = $verify' "$TEST_TMPDIR/bundle/manifest.json" \
    > "$TEST_TMPDIR/bundle/manifest.tmp"
  mv "$TEST_TMPDIR/bundle/manifest.tmp" "$TEST_TMPDIR/bundle/manifest.json"

  runtime prepare --migration-id lan-test --bundle-dir "$TEST_TMPDIR/bundle" >/dev/null
  runtime cutover --migration-id lan-test --timeout-seconds 60 --foreground >/dev/null
  migration_dir="$VPN_KIT_TARGET_ROOT/etc/vpn-kit/lan-migrations/lan-test"
  touch "$migration_dir/hang-confirm"
  VPN_KIT_FORCE_SESSION=1 runtime confirm --migration-id lan-test >/dev/null 2>&1 &
  confirm_pid=$!
  owner="$VPN_KIT_LOCK_DIR/vpn-kit-lan-lan-test.lock.owner.json"
  for _ in 1 2 3 4 5; do [ -f "$owner" ] && break; sleep 1; done
  [ -f "$owner" ]

  runtime rollback --migration-id lan-test >/dev/null
  wait "$confirm_pid" 2>/dev/null || true
  sleep 6
  [ ! -e "$marker" ]
  [ "$(cat "$VPN_KIT_TARGET_ROOT/etc/config/network")" = old ]
}
