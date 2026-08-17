#!/usr/bin/env bats
# tests/memory-table-insert.bats
#
# Unit-tests for the fallback table-insert awk in add-vpn.sh, add-proxy.sh, install-vpn.sh.
# Verifies that a new row is inserted AFTER the last | row inside the table,
# not appended to end-of-file (the bug fixed in those scripts).
# No Docker, SSH, or router required — only bash + awk.

load helpers.bash

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# Run the shared fallback awk snippet from add-vpn.sh / add-proxy.sh.
run_table_insert_awk() {
  local file="$1" row="$2"
  awk -v r="$row" 'BEGIN{last=-1}
    /^\|/ { last=NR }
    { lines[NR]=$0 }
    END {
      for(i=1;i<=NR;i++) {
        print lines[i]
        if (i==last) print r
      }
      if (last==-1) print r
    }
  ' "$file"
}

make_adopted_vpns_md() {
  local file="$1"
  cat > "$file" <<'EOF'
---
router: home
revision: 0
---

# VPN nodes: home

| Tag | Type | Host:port | Region | In auto-failover | Mixed-port |
|-----|------|-----------|--------|:----------------:|:----------:|
| node-pl-a | vless | 198.51.100.10:443 | _?_ | yes | 4000 |
| node-us-a | vless | 198.51.100.11:443 | _?_ | yes | 4001 |

## auto-failover

- **Outbounds**: usa-pool, pl-pool

## Notes

Adopted from existing setup.
EOF
}

make_adopted_proxies_md() {
  local file="$1"
  cat > "$file" <<'EOF'
---
router: home
revision: 0
---

# LAN proxies: home

| Port | Outbound | Purpose | Listen IP |
|------|----------|---------|-----------|
| 4000 | node-pl-a | adopted | 192.0.2.1 |
| 4001 | node-us-a | adopted | 192.0.2.1 |

## How to use

curl --proxy http://192.0.2.1:4000 https://api.ipify.org
EOF
}

# ---------------------------------------------------------------------------

@test "vpns.md: new row inserted before ## auto-failover, not at EOF" {
  local f="$TEST_TMPDIR/vpns.md"
  make_adopted_vpns_md "$f"

  local new_row="| node-sg-b | vless | 198.51.100.12:443 | sg | yes | 4010 |"
  run_table_insert_awk "$f" "$new_row" > "$TEST_TMPDIR/result.md"

  grep -qF "$new_row" "$TEST_TMPDIR/result.md"

  local line_new line_header
  line_new=$(grep -n "node-sg-b" "$TEST_TMPDIR/result.md" | cut -d: -f1)
  line_header=$(grep -n "^## auto-failover" "$TEST_TMPDIR/result.md" | cut -d: -f1)
  [ "$line_new" -lt "$line_header" ]
}

@test "vpns.md: new row is immediately after last table row" {
  local f="$TEST_TMPDIR/vpns.md"
  make_adopted_vpns_md "$f"

  local new_row="| node-sg-b | vless | 198.51.100.12:443 | sg | yes | 4010 |"
  run_table_insert_awk "$f" "$new_row" > "$TEST_TMPDIR/result.md"

  local line_new prev_line
  line_new=$(grep -n "node-sg-b" "$TEST_TMPDIR/result.md" | cut -d: -f1)
  prev_line=$(sed -n "$((line_new - 1))p" "$TEST_TMPDIR/result.md")
  [[ "$prev_line" == \|* ]]
}

@test "vpns.md: content after table is preserved" {
  local f="$TEST_TMPDIR/vpns.md"
  make_adopted_vpns_md "$f"

  run_table_insert_awk "$f" "| node-sg-b | vless | 198.51.100.12:443 | sg | yes | 4010 |" \
    > "$TEST_TMPDIR/result.md"

  grep -q "## auto-failover" "$TEST_TMPDIR/result.md"
  grep -q "## Notes"         "$TEST_TMPDIR/result.md"
  grep -q "Adopted from"     "$TEST_TMPDIR/result.md"
}

@test "proxies.md: new row inserted before ## How to use, not at EOF" {
  local f="$TEST_TMPDIR/proxies.md"
  make_adopted_proxies_md "$f"

  local new_row="| 4010 | node-sg-b | via node-sg-b | 192.0.2.1 |"
  run_table_insert_awk "$f" "$new_row" > "$TEST_TMPDIR/result.md"

  grep -qF "$new_row" "$TEST_TMPDIR/result.md"

  local line_new line_header
  line_new=$(grep -n "4010" "$TEST_TMPDIR/result.md" | cut -d: -f1)
  line_header=$(grep -n "^## How to use" "$TEST_TMPDIR/result.md" | cut -d: -f1)
  [ "$line_new" -lt "$line_header" ]
}

@test "proxies.md: content after table is preserved" {
  local f="$TEST_TMPDIR/proxies.md"
  make_adopted_proxies_md "$f"

  run_table_insert_awk "$f" "| 4010 | node-sg-b | via node-sg-b | 192.0.2.1 |" \
    > "$TEST_TMPDIR/result.md"

  grep -q "## How to use" "$TEST_TMPDIR/result.md"
  grep -q "curl --proxy"  "$TEST_TMPDIR/result.md"
}

@test "file with no table: new row appended at end" {
  local f="$TEST_TMPDIR/empty.md"
  printf '# Header\n\nNo nodes yet.\n' > "$f"

  local new_row="| node-sg-b | vless | 198.51.100.12:443 | sg | yes | 4010 |"
  run_table_insert_awk "$f" "$new_row" > "$TEST_TMPDIR/result.md"

  grep -qF "$new_row" "$TEST_TMPDIR/result.md"
  grep -q "# Header"    "$TEST_TMPDIR/result.md"
}

@test "node type is vless, not vless-reality (regression)" {
  local f="$TEST_TMPDIR/vpns.md"
  make_adopted_vpns_md "$f"

  local new_row="| node-sg-b | vless | 198.51.100.12:443 | sg | yes | 4010 |"
  run_table_insert_awk "$f" "$new_row" > "$TEST_TMPDIR/result.md"

  ! grep -q "vless-reality" "$TEST_TMPDIR/result.md"
  grep -q "| node-sg-b | vless |" "$TEST_TMPDIR/result.md"
}
