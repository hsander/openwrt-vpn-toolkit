#!/usr/bin/env bash
# Check staged additions for secrets and project-specific infrastructure data.
# This is intentionally a deny-list for known leaked values plus generic secret
# shapes. It is a guardrail, not a substitute for review or secret rotation.

set -euo pipefail

usage() {
  echo "Usage: bin/check-public-data.sh --staged" >&2
  exit 64
}

[ "${1:-}" = --staged ] && [ "$#" -eq 1 ] || usage
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/openwrt-public-data.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

# Parse only added lines. Existing legacy history is not rewritten by this
# guard, while any newly introduced copy of a known value is rejected.
git diff --cached --no-ext-diff --unified=0 --diff-filter=ACMR -- . |
  awk '
    /^\+\+\+ b\// { file=substr($0, 7); next }
    /^@@ / {
      if (match($0, /\+[0-9]+/)) {
        start=substr($0, RSTART + 1)
        sub(/,.*/, "", start)
        next_line=start + 0
      }
      next
    }
    /^\+[^+]/ {
      print file "\t" next_line "\t" substr($0, 2)
      next_line++
    }
  ' >"$tmp_file"

# Keep known values split so this checker does not trip over its own policy
# strings when the checker itself is staged.
known_values=(
  "horu""zhenko"
  "iPhone""Sander"
  "vpn-usa""-7"
  "smartbox""-turbo-plus"
  "openwrt-""smartbox"
  "192.255.""136.74"
  "remna""node"
  "26.3"".27"
  "45.84.""0.174"
  "107.174.""85.239"
  "83.147.""234.220"
  "149.154.""167.220"
  "08428cd5""-3e84-37ae-9112-8b9863e956aa"
  "53486aa4""-d172-4d85-b29a-4f5f83ba8df8"
  "usa-""4"
  "usa-""6-dev"
  "usa-""4-crip"
  "pol""sha"
  "redshield-""sg"
)

vless_scheme='vless:'"//"
generic_secret_re="(-----BEGIN [A-Z0-9 ]+ PRIVATE KEY-----|bot[0-9]{6,}:[A-Za-z0-9_-]{20,}|(TG_TOKEN|BOT_TOKEN)=[^[:space:]]+|${vless_scheme}[^[:space:]\"<>]+@[^[:space:]\"<>]+)"

failed=0
while IFS=$'\t' read -r file line content; do
  [ -n "${file:-}" ] || continue

  for value in "${known_values[@]}"; do
    if [[ "$content" == *"$value"* ]]; then
      printf 'public-data-check: blocked %s:%s (known private infrastructure marker)\n' "$file" "$line" >&2
      failed=1
      break
    fi
  done

  if printf '%s\n' "$content" | grep -Eq "$generic_secret_re"; then
    printf 'public-data-check: blocked %s:%s (secret-shaped value)\n' "$file" "$line" >&2
    failed=1
  fi
done <"$tmp_file"

if [ "$failed" -ne 0 ]; then
  echo 'public-data-check: remove the value or replace it with a documented placeholder before committing.' >&2
  exit 1
fi

echo 'public-data-check: staged additions are clean'
