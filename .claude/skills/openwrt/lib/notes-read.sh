#!/bin/sh
# notes-read.sh — read /etc/vpn-kit/journal/router-notes.md
#
# Usage:
#   notes-read.sh                 # print the whole markdown (including frontmatter)
#   notes-read.sh --revision      # print only the revision from frontmatter
#   notes-read.sh --body          # print body only (no frontmatter)
#   notes-read.sh --section "Heading"   # print one '##' section by heading title
#
# Exit:
#   0  ok
#   2  file missing
#   13 frontmatter malformed

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

mode="full"
section=""

case "${1:-}" in
  --revision) mode="revision"; shift ;;
  --body)     mode="body"; shift ;;
  --section)  mode="section"; section="${2:-}"; shift 2 ;;
  -h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) echo "notes-read: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac

if [ ! -f "$VPN_KIT_NOTES_FILE" ]; then
  exit 2
fi

# Frontmatter: lines between initial '---' and next '---'.
# Require valid frontmatter.
first_line="$(head -n 1 "$VPN_KIT_NOTES_FILE")"
if [ "$first_line" != "---" ]; then
  echo "notes-read: frontmatter missing (expected '---' on line 1)" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

# Find the closing '---' line number.
fm_end=$(awk 'NR==1{next} /^---$/{print NR; exit}' "$VPN_KIT_NOTES_FILE")
if [ -z "$fm_end" ]; then
  echo "notes-read: frontmatter not closed" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

case "$mode" in
  full)
    cat "$VPN_KIT_NOTES_FILE" ;;
  revision)
    awk -v end="$fm_end" 'NR>1 && NR<end' "$VPN_KIT_NOTES_FILE" \
      | awk -F: '/^revision[[:space:]]*:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}'
    ;;
  body)
    awk -v start="$((fm_end + 1))" 'NR>=start' "$VPN_KIT_NOTES_FILE"
    ;;
  section)
    if [ -z "$section" ]; then
      echo "notes-read: --section requires a heading title" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    fi
    # Print from '## <title>' up to the next '## ' (exclusive) or EOF.
    awk -v h="$section" '
      BEGIN { inside=0 }
      /^## / {
        title=$0; sub(/^## +/,"",title)
        if (inside) { exit }
        if (title==h) { inside=1 }
      }
      { if (inside) print }
    ' "$VPN_KIT_NOTES_FILE"
    ;;
esac
