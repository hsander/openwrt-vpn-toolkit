#!/usr/bin/env bats

filter_legacy_source_rule() {
  local ip="$1"
  awk -v ip="$ip" '
    index($0, "ip saddr " ip " ") || index($0, "ip saddr " ip "/32 ") { next }
    { print }
  '
}

count_active_rows() {
  awk '
    BEGIN { n = 0; in_active = 0 }
    /^## Активные/ { in_active = 1; next }
    in_active && /^## / { in_active = 0 }
    !in_active { next }
    /^\|[[:space:]]*-+/ { next }
    /^\|[[:space:]]*:?-+/ { next }
    /^\| *Source +\| *Scope / { next }
    /^\|.*\(пока пусто/ { next }
    /^\|/ { n++ }
    END { print n }
  '
}

@test "legacy unpin removes exact source IP with and without /32" {
  input='nft "add rule inet t mangle_prerouting ip saddr 192.168.1.105 accept"
nft "add rule inet t mangle_prerouting ip saddr 192.168.1.105/32 accept"
nft "add rule inet t mangle_prerouting ip saddr 192.168.1.150/32 accept"
nft "add rule inet t mangle_prerouting ip saddr 192.168.1.1050 accept"'

  output="$(printf '%s\n' "$input" | filter_legacy_source_rule '192.168.1.105')"
  [[ "$output" != *"192.168.1.105 accept"* ]]
  [[ "$output" != *"192.168.1.105/32"* ]]
  [[ "$output" == *"192.168.1.150/32"* ]]
  [[ "$output" == *"192.168.1.1050"* ]]
}

@test "doctor count includes only rows from active table" {
  input='# Pin records

## Активные pin records

| Source | Scope | Outbound |
|--------|-------|----------|
| 192.168.1.139/32 | device | usa-4 |
| 192.168.1.150/32 | device | usa-pool |

## Files

| File | Purpose |
|------|---------|
| config.json | routes |
| init.d | persistence |'

  [ "$(printf '%s\n' "$input" | count_active_rows)" = "2" ]
}

@test "legacy fallback preserves init script mode before replacement" {
  run grep -F '[ -x \"\$INITD\" ] && INITD_MODE=755' \
    "$BATS_TEST_DIRNAME/../bin/unpin-device.sh"
  [ "$status" -eq 0 ]

  run grep -F 'chmod \"\$INITD_MODE\" /tmp/unpin-initd' \
    "$BATS_TEST_DIRNAME/../bin/unpin-device.sh"
  [ "$status" -eq 0 ]
}
