#!/usr/bin/env bats
# Tests for staged apply, rollback timer, reachability, and snapshot GC.

load helpers

setup()    { setup_test_env; }
teardown() { teardown_test_env; }

@test "reachability-check: all commands must pass" {
  run "$LIB/reachability-check.sh" --command "true" --command "test -d '$TEST_TMPDIR'"
  [ "$status" -eq 0 ]

  run "$LIB/reachability-check.sh" --command "false"
  [ "$status" -eq 13 ]
}

@test "preflight-safety: reports ok when required primitives exist" {
  mkdir -p "$TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/bin/procd"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/bin/start-stop-daemon"
  chmod +x "$TEST_TMPDIR/bin/procd" "$TEST_TMPDIR/bin/start-stop-daemon"
  run env PATH="$TEST_TMPDIR/bin:$PATH" "$LIB/preflight-safety.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok"' >/dev/null
}

@test "staged-apply: successful apply commits state and daemon cleans timer/snapshot" {
  write_minimal_state
  config="$TEST_TMPDIR/router-config"
  echo "old" > "$config"
  new_state="$TEST_TMPDIR/new-state.json"
  minimal_state_payload > "$new_state"

  run "$LIB/staged-apply.sh" \
    --step-id install-safety \
    --expected-revision 1 \
    --writer claude-code@safety \
    --new-state "$new_state" \
    --snapshot-path "$config" \
    --apply "printf '%s\n' new > '$config'" \
    --verify "grep -q '^new$' '$config'" \
    --timeout-seconds 30

  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  [ "$(cat "$config")" = "new" ]
  [ "$(jq -r '.committed_steps[0].step_id' "$VPN_KIT_STATE_FILE")" = "install-safety" ]
  [ -f "$VPN_KIT_ROLLBACK_DIR/install-safety.timer" ]
  snapshot="$(jq -r '.snapshot_path' "$VPN_KIT_ROLLBACK_DIR/install-safety.timer")"
  [ -d "$snapshot" ]

  run "$LIB/vpn-kit-rollback.sh" --once
  [ "$status" -eq 0 ]
  [ ! -f "$VPN_KIT_ROLLBACK_DIR/install-safety.timer" ]
  [ ! -d "$snapshot" ]
}

@test "staged-apply: failed verify restores files and records rollback" {
  write_minimal_state
  config="$TEST_TMPDIR/router-config"
  echo "old" > "$config"
  new_state="$TEST_TMPDIR/new-state.json"
  minimal_state_payload > "$new_state"

  run "$LIB/staged-apply.sh" \
    --step-id install-bad-config \
    --expected-revision 1 \
    --writer claude-code@safety \
    --new-state "$new_state" \
    --snapshot-path "$config" \
    --apply "printf '%s\n' bad > '$config'" \
    --verify "grep -q '^new$' '$config'" \
    --timeout-seconds 1

  [ "$status" -eq 13 ]
  [ "$(cat "$config")" = "old" ]
  [ ! -f "$VPN_KIT_ROLLBACK_DIR/install-bad-config.timer" ]
  [ "$(jq '(.committed_steps // []) | length' "$VPN_KIT_STATE_FILE")" = "0" ]
  grep -q '"type":"staged_apply_rolled_back"' "$VPN_KIT_JOURNAL_FILE"
}

@test "staged-apply: rollback-command runs after restoring files" {
  write_minimal_state
  config="$TEST_TMPDIR/router-config"
  marker="$TEST_TMPDIR/rollback-marker"
  echo "old" > "$config"
  new_state="$TEST_TMPDIR/new-state.json"
  minimal_state_payload > "$new_state"

  run "$LIB/staged-apply.sh" \
    --step-id install-runtime-rollback \
    --expected-revision 1 \
    --writer claude-code@safety \
    --new-state "$new_state" \
    --snapshot-path "$config" \
    --apply "printf '%s\n' bad > '$config'" \
    --verify "false" \
    --rollback-command "cat '$config' > '$marker'" \
    --timeout-seconds 1

  [ "$status" -eq 13 ]
  [ "$(cat "$config")" = "old" ]
  [ "$(cat "$marker")" = "old" ]
}

@test "vpn-kit-rollback: expired timer restores snapshot without staged-apply process" {
  write_minimal_state
  config="$TEST_TMPDIR/router-config"
  echo "old" > "$config"
  snapshot="$VPN_KIT_SNAPSHOT_DIR/manual-expired"
  mkdir -p "$snapshot/files"
  cp "$config" "$snapshot/files/0-router-config"
  cp "$VPN_KIT_STATE_FILE" "$snapshot/state-before.json"
  cat > "$snapshot/meta.json" <<JSON
{"step_id":"manual-expired","created_at":"2026-04-21T14:00:00Z","state_revision_before":1,"files":[{"path":"$config","backup":"files/0-router-config","existed":true}]}
JSON
  echo "new" > "$config"
  cat > "$VPN_KIT_ROLLBACK_DIR/manual-expired.timer" <<JSON
{"step_id":"manual-expired","deadline_unix":0,"snapshot_path":"$snapshot","state_revision_before":1}
JSON

  run "$LIB/vpn-kit-rollback.sh" --once
  [ "$status" -eq 0 ]
  [ "$(cat "$config")" = "old" ]
  [ ! -f "$VPN_KIT_ROLLBACK_DIR/manual-expired.timer" ]
  [ -d "$VPN_KIT_SNAPSHOT_DIR/rolled-back/manual-expired" ]
}

@test "snapshot-gc: refuses to delete snapshots referenced by active timers" {
  snapshot="$VPN_KIT_SNAPSHOT_DIR/active"
  mkdir -p "$snapshot"
  cat > "$VPN_KIT_ROLLBACK_DIR/active.timer" <<JSON
{"step_id":"active","deadline_unix":9999999999,"snapshot_path":"$snapshot","state_revision_before":0}
JSON

  run "$LIB/snapshot-gc.sh" --delete-success "$snapshot"
  [ "$status" -eq 12 ]
  [ -d "$snapshot" ]

  rm -f "$VPN_KIT_ROLLBACK_DIR/active.timer"
  run "$LIB/snapshot-gc.sh" --delete-success "$snapshot"
  [ "$status" -eq 0 ]
  [ ! -d "$snapshot" ]
}
