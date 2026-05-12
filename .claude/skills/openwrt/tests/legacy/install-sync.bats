#!/usr/bin/env bats
# Tests for safety installer, session sync, and adopt flow.

load helpers

setup()    { setup_test_env; }
teardown() { teardown_test_env; }

@test "install-safety: installs runtime into target root and writes state" {
  target="$TEST_TMPDIR/router-root"

  run "$SKILL_DIR/scripts/install-safety.sh" --root "$target" --writer claude-code@installer
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok"' >/dev/null

  [ -x "$target/usr/lib/vpn-kit/staged-apply.sh" ]
  [ -x "$target/usr/lib/vpn-kit/vpn-kit-rollback.sh" ]
  [ -x "$target/usr/sbin/vpn-kit-rollback" ]
  [ -x "$target/etc/init.d/vpn-kit-rollback" ]
  [ -f "$target/etc/vpn-kit/install-state.json" ]
  [ "$(jq -r '._revision' "$target/etc/vpn-kit/install-state.json")" = "1" ]
}

@test "session-sync: pull caches state and check-owned-files detects drift" {
  target="$TEST_TMPDIR/router-root"
  "$SKILL_DIR/scripts/install-safety.sh" --root "$target" --writer claude-code@installer >/dev/null

  export VPN_KIT_STATE_FILE="$target/etc/vpn-kit/install-state.json"
  export VPN_KIT_JOURNAL_FILE="$target/etc/vpn-kit/journal/events.jsonl"
  export VPN_KIT_NOTES_FILE="$target/etc/vpn-kit/journal/router-notes.md"
  export VPN_KIT_QUIRKS_FILE="$target/etc/vpn-kit/journal/learned-quirks.yaml"

  cache="$TEST_TMPDIR/cache"
  run "$SKILL_DIR/scripts/session-sync.sh" pull --cache-dir "$cache"
  [ "$status" -eq 0 ]
  [ -f "$cache/install-state.json" ]
  [ "$(jq -r '._sync_base_revision' "$cache/sync-meta.json")" = "1" ]

  run "$SKILL_DIR/scripts/session-sync.sh" check-owned-files
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok"' >/dev/null

  echo "# manual change" >> "$target/usr/lib/vpn-kit/vpn-kit-rollback.sh"
  run "$SKILL_DIR/scripts/session-sync.sh" check-owned-files
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "drift" and (.drift | length == 1)' >/dev/null
}

@test "adopt-safety-state: reconstructs state when runtime exists but state is missing" {
  target="$TEST_TMPDIR/router-root"
  "$SKILL_DIR/scripts/install-safety.sh" --root "$target" --writer claude-code@installer >/dev/null
  rm -f "$target/etc/vpn-kit/install-state.json"

  run "$SKILL_DIR/scripts/adopt-safety-state.sh" --root "$target" --writer claude-code@adopt
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "adopted"' >/dev/null
  [ -f "$target/etc/vpn-kit/install-state.json" ]
  jq -e '(.committed_steps // []) | any(.step_id == "adopt-safety-state")' "$target/etc/vpn-kit/install-state.json" >/dev/null
}
