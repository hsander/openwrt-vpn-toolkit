#!/usr/bin/env bash
# bin/snapshot-list.sh — list snapshots stored on the router under
# /etc/vpn-kit/snapshots/. Emits a table by default or JSON with --json.
#
# Usage:
#   bin/snapshot-list.sh --router <alias> [--json]
#
# Exit codes:
#   0   ok (also if there are no snapshots — empty list is not an error)
#   2   router not found / SSH unreachable
#  64   bad CLI args

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/snapshot-list.sh --router <alias> [--json]

Печатает таблицу снимков /etc/vpn-kit/snapshots/*.meta.json роутера.

Options:
  --router <alias>   alias из memory/routers.yaml (обяз.)
  --json             вывести JSON-массив (для машин). По умолчанию таблица.
EOF
  exit 64
}

router=""
emit_json=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --json) emit_json=1; shift ;;
    -h|--help) usage ;;
    *) echo "snapshot-list: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "snapshot-list: --router обязателен" >&2; usage; }

resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
snapshot-list: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Проверь связь.
EOF
  exit 2
fi

# Remote: dump each meta.json on one line as "id|created|label|size_bytes".
# We rely on the meta values not containing pipe chars in label (we validate
# this in backup-now); fallback we strip pipes to be safe.
remote_script='
set -eu
SNAP_DIR="/etc/vpn-kit/snapshots"
[ -d "$SNAP_DIR" ] || exit 0
for M in "$SNAP_DIR"/*.meta.json; do
  [ -f "$M" ] || continue
  ID="$(basename "$M" .meta.json)"
  TAR="$SNAP_DIR/${ID}.tar.gz"
  SIZE="?"
  [ -f "$TAR" ] && SIZE="$(wc -c < "$TAR" 2>/dev/null | tr -d " ")"
  # Crude json field extraction (we wrote the file ourselves with a stable
  # layout, so naive grep is acceptable here; jq is not guaranteed on router).
  CREATED="$(grep -E "^  \"created\":" "$M" | head -n1 | sed -e "s/.*\"created\":[[:space:]]*\"//" -e "s/\".*//")"
  LABEL="$(grep -E "^  \"label\":" "$M" | head -n1 | sed -e "s/.*\"label\":[[:space:]]*\"//" -e "s/\".*//")"
  # Strip any stray pipes from label (parser safety).
  LABEL_SAFE="$(printf "%s" "$LABEL" | tr "|" "/")"
  printf "%s|%s|%s|%s\n" "$ID" "$CREATED" "$LABEL_SAFE" "$SIZE"
done
'

raw="$(ssh_run "$remote_script" 2>/dev/null || true)"

# Sort newest-first by ID (IDs are UTC timestamps).
sorted="$(printf '%s' "$raw" | grep -v '^$' | sort -r || true)"

if [ -z "$sorted" ]; then
  if [ "$emit_json" = "1" ]; then
    echo "[]"
  else
    cat <<EOF
snapshot-list: (нет снимков) для роутера '$ROUTER_ALIAS'.

Создай первый снимок:
  bin/backup-now.sh --router $ROUTER_ALIAS --label "initial"
EOF
  fi
  exit 0
fi

if [ "$emit_json" = "1" ]; then
  # Build JSON array safely (we have jq locally).
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$sorted" | awk -F'|' '
      BEGIN { print "[" }
      {
        if (NR>1) printf ",\n"
        # Escape backslash + double-quote for JSON strings.
        for (i=1; i<=NF; i++) {
          v = $i
          gsub(/\\/, "\\\\", v)
          gsub(/"/, "\\\"", v)
          arr[i] = v
        }
        printf "  {\"id\":\"%s\",\"created\":\"%s\",\"label\":\"%s\",\"size_bytes\":%s}", \
          arr[1], arr[2], arr[3], (arr[4]=="?" ? "null" : arr[4])
      }
      END { print "\n]" }
    ' | jq .
  else
    # No local jq — emit raw (still valid JSON).
    printf '%s\n' "$sorted" | awk -F'|' '
      BEGIN { print "[" }
      {
        if (NR>1) printf ",\n"
        for (i=1; i<=NF; i++) {
          v = $i
          gsub(/\\/, "\\\\", v)
          gsub(/"/, "\\\"", v)
          arr[i] = v
        }
        printf "  {\"id\":\"%s\",\"created\":\"%s\",\"label\":\"%s\",\"size_bytes\":%s}", \
          arr[1], arr[2], arr[3], (arr[4]=="?" ? "null" : arr[4])
      }
      END { print "\n]" }
    '
  fi
  exit 0
fi

# Default: human-friendly table.
# Compute widths from data, but cap label width.
{
  printf 'ID\tCreated (ISO)\tLabel\tSize\n'
  printf '%s\n' "$sorted" | awk -F'|' '
    function human(b) {
      if (b == "?" || b == "") return "?"
      if (b+0 < 1024) return b "B"
      if (b+0 < 1048576) return sprintf("%.1fK", b/1024)
      if (b+0 < 1073741824) return sprintf("%.1fM", b/1048576)
      return sprintf("%.1fG", b/1073741824)
    }
    {
      label = $3
      if (length(label) > 40) label = substr(label, 1, 37) "..."
      if (label == "") label = "(none)"
      printf "%s\t%s\t%s\t%s\n", $1, $2, label, human($4)
    }
  '
} | column -t -s $'\t' 2>/dev/null || {
  # Fallback if `column` not available.
  printf 'ID\tCreated\tLabel\tSize\n'
  printf '%s\n' "$sorted" | awk -F'|' '{print $1"\t"$2"\t"$3"\t"$4}'
}

exit 0
