#!/usr/bin/env bats
# Tests for lib/state-read.sh and lib/state-write.sh (CAS).

load helpers

setup()    { setup_test_env; }
teardown() { teardown_test_env; }

@test "state-read: missing file returns exit 2" {
  run "$LIB/state-read.sh"
  [ "$status" -eq 2 ]
}

@test "state-write: initial write from revision 0 creates file at revision 1" {
  run bash -c 'echo "{\"version\":1,\"profile\":\"minimal\"}" | "$LIB"/state-write.sh --expected-revision 0 --writer claude-code@t1'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ -f "$VPN_KIT_STATE_FILE" ]
  rev="$("$LIB/state-read.sh" --revision)"
  [ "$rev" = "1" ]
  writer="$("$LIB/state-read.sh" --field _last_writer)"
  [ "$writer" = "claude-code@t1" ]
}

@test "state-write: STALE when expected revision != current" {
  echo '{"version":1}' | "$LIB/state-write.sh" --expected-revision 0 --writer claude-code@t1 >/dev/null
  run bash -c 'echo "{\"version\":1,\"profile\":\"standard\"}" | "$LIB"/state-write.sh --expected-revision 0 --writer claude-code@t2'
  [ "$status" -eq 11 ]
}

@test "state-write: successive writes bump revision monotonically" {
  echo '{"version":1}' | "$LIB/state-write.sh" --expected-revision 0 --writer claude-code@t1 >/dev/null
  echo '{"version":1,"a":1}' | "$LIB/state-write.sh" --expected-revision 1 --writer claude-code@t1 >/dev/null
  echo '{"version":1,"a":2}' | "$LIB/state-write.sh" --expected-revision 2 --writer claude-code@t1 >/dev/null
  [ "$("$LIB/state-read.sh" --revision)" = "3" ]
  [ "$("$LIB/state-read.sh" --field a)" = "2" ]
}

@test "state-write: rejects malformed JSON with VALIDATION" {
  run bash -c 'echo "not-json" | "$LIB"/state-write.sh --expected-revision 0 --writer claude-code@t1'
  [ "$status" -eq 13 ]
}

@test "state-write: rejects malformed --writer with VALIDATION" {
  run bash -c 'echo "{}" | "$LIB"/state-write.sh --expected-revision 0 --writer "BAD WRITER"'
  [ "$status" -eq 13 ]
}

@test "state-write: rejects non-object stdin with VALIDATION" {
  run bash -c 'echo "[1,2,3]" | "$LIB"/state-write.sh --expected-revision 0 --writer claude-code@t1'
  [ "$status" -eq 13 ]
}

@test "state-write: CAS fields are overwritten, not trusted from input" {
  # Caller tries to set _revision=99; script overwrites with expected+1.
  run bash -c 'echo "{\"_revision\":99,\"_last_writer\":\"evil@evil\",\"version\":1}" | "$LIB"/state-write.sh --expected-revision 0 --writer claude-code@t1'
  [ "$status" -eq 0 ]
  [ "$("$LIB/state-read.sh" --revision)" = "1" ]
  [ "$("$LIB/state-read.sh" --field _last_writer)" = "claude-code@t1" ]
}

@test "state-write: two sequential writers with retry pattern succeed" {
  # Simulate two-writer race resolved by the retry loop specified in PROPOSAL §9.3.
  echo '{"version":1,"a":0}' | "$LIB/state-write.sh" --expected-revision 0 --writer claude-code@a >/dev/null

  # Writer B reads revision 1 and tries to write 2 — succeeds.
  rev="$("$LIB/state-read.sh" --revision)"
  echo '{"version":1,"a":1}' | "$LIB/state-write.sh" --expected-revision "$rev" --writer tg-bot@home >/dev/null

  # Writer A still thinks it's at rev 1 — STALE. Then re-reads and retries.
  run bash -c 'echo "{\"version\":1,\"a\":9}" | "$LIB"/state-write.sh --expected-revision 1 --writer claude-code@a'
  [ "$status" -eq 11 ]
  rev2="$("$LIB/state-read.sh" --revision)"
  echo '{"version":1,"a":9}' | "$LIB/state-write.sh" --expected-revision "$rev2" --writer claude-code@a >/dev/null
  [ "$("$LIB/state-read.sh" --revision)" = "3" ]
  [ "$("$LIB/state-read.sh" --field a)" = "9" ]
}

@test "state-read: --field extracts nested path via jq" {
  echo '{"version":1,"router_identity":{"name":"r1"}}' | "$LIB/state-write.sh" --expected-revision 0 --writer claude-code@t1 >/dev/null
  out="$("$LIB/state-read.sh" --field .router_identity.name)"
  [ "$out" = "r1" ]
}

@test "state-read: corrupt JSON file returns exit 13" {
  echo "not json" > "$VPN_KIT_STATE_FILE"
  run "$LIB/state-read.sh"
  [ "$status" -eq 13 ]
}
