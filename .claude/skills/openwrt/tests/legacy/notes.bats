#!/usr/bin/env bats
# Tests for lib/notes-read.sh and lib/notes-write.sh.

load helpers

setup()    { setup_test_env; }
teardown() { teardown_test_env; }

@test "notes-read: missing file returns exit 2" {
  run "$LIB/notes-read.sh"
  [ "$status" -eq 2 ]
}

@test "notes-write: full-overwrite from empty creates file at revision 1" {
  run bash -c 'echo -e "# Router notes\n\nHello world" | "$LIB"/notes-write.sh --mode full-overwrite --expected-revision 0 --writer claude-code@t1'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ -f "$VPN_KIT_NOTES_FILE" ]
  [ "$("$LIB/notes-read.sh" --revision)" = "1" ]
}

@test "notes-write: full-overwrite STALE when revision mismatch" {
  echo "# initial" | "$LIB/notes-write.sh" --mode full-overwrite --expected-revision 0 --writer claude-code@t1 >/dev/null
  run bash -c 'echo "# second" | "$LIB"/notes-write.sh --mode full-overwrite --expected-revision 0 --writer claude-code@t1'
  [ "$status" -eq 11 ]
}

@test "notes-write: append-section adds a new section" {
  echo "# Router notes" | "$LIB/notes-write.sh" --mode full-overwrite --expected-revision 0 --writer claude-code@t1 >/dev/null
  echo "Detected Kyivstar Home" | "$LIB/notes-write.sh" --mode append-section --section "ISP" --expected-revision 1 --writer claude-code@t1 >/dev/null
  [ "$("$LIB/notes-read.sh" --revision)" = "2" ]
  body="$("$LIB/notes-read.sh" --body)"
  case "$body" in
    *"## ISP"*"Kyivstar Home"*) pass=1 ;;
    *) pass=0 ;;
  esac
  [ "$pass" = "1" ]
}

@test "notes-write: append-section on existing section is idempotent via update" {
  echo "# start" | "$LIB/notes-write.sh" --mode full-overwrite --expected-revision 0 --writer claude-code@t1 >/dev/null
  echo "version 1" | "$LIB/notes-write.sh" --mode append-section --section "ISP" --expected-revision 1 --writer claude-code@t1 >/dev/null
  echo "version 2" | "$LIB/notes-write.sh" --mode append-section --section "ISP" --expected-revision 2 --writer claude-code@t1 >/dev/null
  section="$("$LIB/notes-read.sh" --section "ISP")"
  case "$section" in
    *"version 2"*) pass=1 ;;
    *) pass=0 ;;
  esac
  [ "$pass" = "1" ]
  # Should not contain old body "version 1".
  case "$section" in
    *"version 1"*) dup=1 ;;
    *) dup=0 ;;
  esac
  [ "$dup" = "0" ]
}

@test "notes-write: update-section on non-existent section creates it" {
  echo "# start" | "$LIB/notes-write.sh" --mode full-overwrite --expected-revision 0 --writer claude-code@t1 >/dev/null
  echo "contents" | "$LIB/notes-write.sh" --mode update-section --section "New" --expected-revision 1 --writer claude-code@t1 >/dev/null
  section="$("$LIB/notes-read.sh" --section "New")"
  case "$section" in
    *"contents"*) pass=1 ;;
    *) pass=0 ;;
  esac
  [ "$pass" = "1" ]
}

@test "notes-write: secret in payload is rejected" {
  echo "# start" | "$LIB/notes-write.sh" --mode full-overwrite --expected-revision 0 --writer claude-code@t1 >/dev/null
  run bash -c 'echo "here is vless://uuid@host:443" | "$LIB"/notes-write.sh --mode full-overwrite --expected-revision 1 --writer claude-code@t1'
  [ "$status" -eq 13 ]
}

@test "notes-write: bad writer is VALIDATION" {
  run bash -c 'echo "body" | "$LIB"/notes-write.sh --mode full-overwrite --expected-revision 0 --writer "BAD"'
  [ "$status" -eq 13 ]
}

@test "notes-read: --section extracts one section only" {
  echo "# start" | "$LIB/notes-write.sh" --mode full-overwrite --expected-revision 0 --writer claude-code@t1 >/dev/null
  echo "data-a" | "$LIB/notes-write.sh" --mode append-section --section "A" --expected-revision 1 --writer claude-code@t1 >/dev/null
  echo "data-b" | "$LIB/notes-write.sh" --mode append-section --section "B" --expected-revision 2 --writer claude-code@t1 >/dev/null
  out="$("$LIB/notes-read.sh" --section "A")"
  case "$out" in
    *"data-a"*) pass=1 ;;
    *) pass=0 ;;
  esac
  [ "$pass" = "1" ]
  case "$out" in
    *"data-b"*) dup=1 ;;
    *) dup=0 ;;
  esac
  [ "$dup" = "0" ]
}

@test "notes-read: --revision extracts revision from frontmatter" {
  echo "body" | "$LIB/notes-write.sh" --mode full-overwrite --expected-revision 0 --writer claude-code@t1 >/dev/null
  echo "body" | "$LIB/notes-write.sh" --mode full-overwrite --expected-revision 1 --writer claude-code@t1 >/dev/null
  [ "$("$LIB/notes-read.sh" --revision)" = "2" ]
}
