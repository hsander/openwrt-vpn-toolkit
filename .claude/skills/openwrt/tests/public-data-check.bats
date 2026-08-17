#!/usr/bin/env bats

setup() {
  SKILL_HOME="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_TMPDIR="$(mktemp -d)"
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" config user.email test@example.invalid
  git -C "$TEST_TMPDIR" config user.name test
}

teardown() { rm -rf "$TEST_TMPDIR"; }

stage_and_check() {
  printf '%s\n' "$2" >"$TEST_TMPDIR/$1"
  git -C "$TEST_TMPDIR" add "$1"
  run bash -c "cd '$TEST_TMPDIR' && '$SKILL_HOME/bin/check-public-data.sh' --staged"
}

@test "staged personal infrastructure marker is rejected" {
  leak_value="$(printf '%s%s' iPhone Sander)"
  stage_and_check leak.txt "ssid=$leak_value"
  [ "$status" -eq 1 ]
  [[ "$output" == *"known private infrastructure marker"* ]]
}

@test "staged secret-shaped value is rejected" {
  scheme="$(printf '%s%s' vless ://)"
  leak_url="${scheme}11111111-1111-1111-1111-111111111111@${USER:-example}.invalid:443"
  stage_and_check leak.txt "url=$leak_url"
  [ "$status" -eq 1 ]
  [[ "$output" == *"secret-shaped value"* ]]
}

@test "documented placeholders are accepted" {
  stage_and_check example.txt 'endpoint=<vps-public-ip-or-host> ssh_alias=<vps-ssh-alias>'
  [ "$status" -eq 0 ]
}

@test "empty staged diff is accepted" {
  run bash -c "cd '$TEST_TMPDIR' && '$SKILL_HOME/bin/check-public-data.sh' --staged"
  [ "$status" -eq 0 ]
}
