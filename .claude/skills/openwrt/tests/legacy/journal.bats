#!/usr/bin/env bats
# Tests for lib/journal-append.sh.

load helpers

setup()    { setup_test_env; }
teardown() { teardown_test_env; }

@test "journal-append: basic kv mode produces one JSONL line" {
  run "$LIB/journal-append.sh" setup_started profile=minimal
  [ "$status" -eq 0 ]
  [ -f "$VPN_KIT_JOURNAL_FILE" ]
  lines="$(wc -l < "$VPN_KIT_JOURNAL_FILE" | tr -d ' ')"
  [ "$lines" = "1" ]
  type="$(jq -r .type < "$VPN_KIT_JOURNAL_FILE")"
  [ "$type" = "setup_started" ]
  profile="$(jq -r .profile < "$VPN_KIT_JOURNAL_FILE")"
  [ "$profile" = "minimal" ]
  ts="$(jq -r .ts < "$VPN_KIT_JOURNAL_FILE")"
  [ -n "$ts" ] && [ "$ts" != "null" ]
}

@test "journal-append: --json accepts pre-built JSON" {
  run "$LIB/journal-append.sh" --json '{"ts":"2026-04-21T12:00:00Z","type":"setup_completed","duration_s":42}'
  [ "$status" -eq 0 ]
  type="$(jq -r .type < "$VPN_KIT_JOURNAL_FILE")"
  [ "$type" = "setup_completed" ]
  dur="$(jq -r .duration_s < "$VPN_KIT_JOURNAL_FILE")"
  [ "$dur" = "42" ]
}

@test "journal-append: --stdin accepts JSON via stdin" {
  run bash -c 'echo "{\"ts\":\"2026-04-21T12:00:00Z\",\"type\":\"dynamic_add\",\"kind\":\"domain\"}" | "$LIB"/journal-append.sh --stdin'
  [ "$status" -eq 0 ]
  [ "$(jq -r .kind < "$VPN_KIT_JOURNAL_FILE")" = "domain" ]
}

@test "journal-append: rejects secret-like content (vless URL)" {
  run "$LIB/journal-append.sh" setup_started note=vless://uuid@host:443
  [ "$status" -eq 13 ]
  [ ! -f "$VPN_KIT_JOURNAL_FILE" ] || [ "$(wc -l < "$VPN_KIT_JOURNAL_FILE" | tr -d ' ')" = "0" ]
}

@test "journal-append: rejects secret-like content (bot token)" {
  run "$LIB/journal-append.sh" setup_started note="bot1234567890:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
  [ "$status" -eq 13 ]
}

@test "journal-append: --json with bot_token key is refused" {
  run "$LIB/journal-append.sh" --json '{"ts":"2026-04-21T12:00:00Z","type":"setup_started","bot_token":"xxx"}'
  [ "$status" -eq 13 ]
}

@test "journal-append: missing 'type' in --json is VALIDATION" {
  run "$LIB/journal-append.sh" --json '{"ts":"2026-04-21T12:00:00Z"}'
  [ "$status" -eq 13 ]
}

@test "journal-append: sequential appends produce multiple lines" {
  "$LIB/journal-append.sh" a_event i=1
  "$LIB/journal-append.sh" b_event i=2
  "$LIB/journal-append.sh" c_event i=3
  lines="$(wc -l < "$VPN_KIT_JOURNAL_FILE" | tr -d ' ')"
  [ "$lines" = "3" ]
}

@test "journal-append: rotation kicks in after size threshold" {
  export VPN_KIT_JOURNAL_MAX_BYTES=200
  # Write several lines to exceed 200 bytes.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    "$LIB/journal-append.sh" test_event index=$i payload=abcdefghijklmnop
  done
  [ -f "$VPN_KIT_JOURNAL_FILE" ]
  [ -f "${VPN_KIT_JOURNAL_FILE}.1" ]
}

@test "journal-append: invalid key name is rejected" {
  run "$LIB/journal-append.sh" test_event "bad-key=x"
  [ "$status" -eq 13 ]
}

@test "journal-append: k=v with spaces in value preserved correctly" {
  "$LIB/journal-append.sh" test_event text="hello world with spaces"
  txt="$(jq -r .text < "$VPN_KIT_JOURNAL_FILE")"
  [ "$txt" = "hello world with spaces" ]
}
