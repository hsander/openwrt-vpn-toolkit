#!/bin/sh
# notes-write.sh — CAS write of router-notes.md (markdown with frontmatter)
#
# Modes:
#   --mode append-section  --section "Heading"   # append/overwrite a '## Heading' section
#   --mode update-section  --section "Heading"   # replace body of existing section
#   --mode full-overwrite                        # body comes from stdin, replaces everything after frontmatter
#
# Required:
#   --expected-revision N     CAS revision
#   --writer <id>             writer ID
#
# Optional:
#   --writer-host <host>
#   stdin                     payload (section body for section modes; full body for full-overwrite)
#
# Exit: 0 ok, 11 stale, 12 lock, 13 validation

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

mode=""
section=""
expected_rev=""
writer=""
writer_host=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)              mode="$2"; shift 2 ;;
    --section)           section="$2"; shift 2 ;;
    --expected-revision) expected_rev="$2"; shift 2 ;;
    --writer)            writer="$2"; shift 2 ;;
    --writer-host)       writer_host="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "notes-write: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

if [ -z "$mode" ] || [ -z "$expected_rev" ] || [ -z "$writer" ]; then
  echo "notes-write: --mode, --expected-revision, --writer are required" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi
case "$expected_rev" in
  ''|*[!0-9]*) echo "notes-write: --expected-revision must be non-negative integer" >&2
               exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac
if ! vpn_kit_validate_writer_id "$writer"; then
  echo "notes-write: bad --writer" >&2; exit "$VPN_KIT_EXIT_VALIDATION"
fi
case "$mode" in
  append-section|update-section)
    if [ -z "$section" ]; then
      echo "notes-write: --section required for mode $mode" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    fi ;;
  full-overwrite) ;;
  *) echo "notes-write: invalid --mode: $mode" >&2
     exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac

payload="$(cat)"
if printf '%s' "$payload" | vpn_kit_contains_secret; then
  echo "notes-write: secret pattern detected in stdin payload, refusing to write" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

_current_revision() {
  if [ ! -f "$VPN_KIT_NOTES_FILE" ]; then
    echo 0
    return
  fi
  awk '
    NR==1 { if ($0 != "---") exit 1; next }
    /^---$/ { exit 0 }
    /^revision[[:space:]]*:/ { sub(/^revision[[:space:]]*:[[:space:]]*/,""); rev=$0 }
    END { if (rev=="") rev=0; print rev }
  ' "$VPN_KIT_NOTES_FILE"
}

_do_write() {
  _cur_rev="$(_current_revision)" || {
    echo "notes-write: current frontmatter malformed" >&2
    return "$VPN_KIT_EXIT_VALIDATION"
  }
  if [ "$_cur_rev" != "$expected_rev" ]; then
    echo "notes-write: STALE expected=$expected_rev current=$_cur_rev" >&2
    return "$VPN_KIT_EXIT_STALE"
  fi

  _next_rev=$((_cur_rev + 1))
  _now="$(vpn_kit_now_iso8601)"

  # Build new frontmatter
  _fm=""
  _fm=$(printf -- '---\nrevision: %s\nlast_writer: "%s"\n' "$_next_rev" "$writer")
  if [ -n "$writer_host" ]; then
    _fm=$(printf '%s\nlast_writer_host: "%s"' "$_fm" "$writer_host")
  fi
  _fm=$(printf '%s\nlast_updated_at: "%s"\n---' "$_fm" "$_now")

  # Compute current body (everything after frontmatter), or empty if file missing.
  if [ -f "$VPN_KIT_NOTES_FILE" ]; then
    _fm_end=$(awk 'NR==1{next} /^---$/{print NR; exit}' "$VPN_KIT_NOTES_FILE")
    _body=$(awk -v s="$((_fm_end + 1))" 'NR>=s' "$VPN_KIT_NOTES_FILE")
  else
    _body=""
  fi

  case "$mode" in
    full-overwrite)
      _new_body="$payload"
      ;;
    append-section)
      # Append a new '## <section>' followed by payload.
      # If the section already exists, behave like update-section
      # (idempotent merge semantics).
      if printf '%s\n' "$_body" | grep -qE "^## $(printf '%s' "$section" | sed 's/[][\\^$.*+?()|{}/]/\\&/g')\$"; then
        mode="update-section"
      else
        if [ -n "$_body" ]; then
          _new_body="$(printf '%s\n\n## %s\n\n%s\n' "$_body" "$section" "$payload")"
        else
          _new_body="$(printf '## %s\n\n%s\n' "$section" "$payload")"
        fi
      fi
      ;;
  esac

  if [ "$mode" = "update-section" ]; then
    # Replace contents of '## <section>' up to the next '## ' or EOF.
    _new_body=$(awk -v h="$section" -v repl="$payload" '
      BEGIN { printed=0; inside=0 }
      {
        if ($0 ~ /^## /) {
          ttl=$0; sub(/^## +/,"",ttl)
          if (inside) { inside=0 }
          if (ttl==h) {
            print "## " h
            print ""
            print repl
            inside=1
            printed=1
            next
          }
        }
        if (!inside) print
      }
      END { if (!printed) { print ""; print "## " h; print ""; print repl } }
    ' <<EOF
$_body
EOF
    )
  fi

  # Assemble final file.
  _out="$(printf '%s\n%s\n' "$_fm" "$_new_body")"
  printf '%s' "$_out" | vpn_kit_atomic_write "$VPN_KIT_NOTES_FILE" || return 1
  printf '%s\n' "$_next_rev"
  return 0
}

vpn_kit_with_lock notes _do_write
exit $?
