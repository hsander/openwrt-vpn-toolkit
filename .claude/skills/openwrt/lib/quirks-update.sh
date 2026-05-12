#!/bin/sh
# quirks-update.sh — CAS mutation of /etc/vpn-kit/journal/learned-quirks.yaml
#
# Because OpenWrt busybox lacks YAML tools, this script converts YAML→JSON
# (via yq) for mutation and back. yq is required on the host running this
# script; tests use the yq that macOS users install via `brew install yq`.
#
# Operations:
#   set <path> <value>   # set YAML path to literal string/number/bool/null
#   set-json <path> <raw-json>   # set path to parsed JSON (arrays/objects)
#   unset <path>         # delete path
#   init                 # create empty quirks file at revision 0→1 (expected-revision must be 0)
#
# Required flags:
#   --expected-revision N
#   --writer <id>
#
# Exit:
#   0 ok, 11 stale, 12 lock, 13 validation

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq yq

op=""
path=""
value=""
raw_json=""
expected_rev=""
writer=""
writer_host=""

while [ $# -gt 0 ]; do
  case "$1" in
    --expected-revision) expected_rev="$2"; shift 2 ;;
    --writer)            writer="$2"; shift 2 ;;
    --writer-host)       writer_host="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    set)       op="set";       path="$2"; value="$3"; shift 3 ;;
    set-json)  op="set-json";  path="$2"; raw_json="$3"; shift 3 ;;
    unset)     op="unset";     path="$2"; shift 2 ;;
    init)      op="init"; shift ;;
    *) echo "quirks-update: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

if [ -z "$op" ] || [ -z "$expected_rev" ] || [ -z "$writer" ]; then
  echo "quirks-update: op, --expected-revision, --writer are required" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi
case "$expected_rev" in
  ''|*[!0-9]*) echo "quirks-update: --expected-revision must be integer" >&2
               exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac
if ! vpn_kit_validate_writer_id "$writer"; then
  echo "quirks-update: bad --writer" >&2; exit "$VPN_KIT_EXIT_VALIDATION"
fi

# Path like "isp.working_zapret_strategy" or "hardware.known_quirks[0].id".
# We normalize to jq path; yq understands the same dot/bracket syntax so we
# pass through where possible.
case "$op" in
  set|set-json|unset)
    if [ -z "$path" ]; then
      echo "quirks-update: path required for $op" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    fi ;;
esac

_yaml_to_json() {
  # Convert current YAML file (or empty object if missing) to JSON on stdout.
  if [ -f "$VPN_KIT_QUIRKS_FILE" ]; then
    yq -o=json '.' "$VPN_KIT_QUIRKS_FILE"
  else
    echo '{}'
  fi
}

_json_to_yaml() {
  # stdin: JSON; stdout: YAML.
  yq -P eval -o=yaml -
}

_current_revision() {
  if [ ! -f "$VPN_KIT_QUIRKS_FILE" ]; then
    echo 0
    return
  fi
  yq '._revision // 0' "$VPN_KIT_QUIRKS_FILE"
}

_do_write() {
  _cur_rev="$(_current_revision)"
  if [ "$_cur_rev" != "$expected_rev" ]; then
    echo "quirks-update: STALE expected=$expected_rev current=$_cur_rev" >&2
    return "$VPN_KIT_EXIT_STALE"
  fi
  _next_rev=$((_cur_rev + 1))
  _now="$(vpn_kit_now_iso8601)"

  # Secret filter on any literal we are about to inject.
  case "$op" in
    set|set-json)
      _to_check="$value$raw_json"
      if printf '%s' "$_to_check" | vpn_kit_contains_secret; then
        echo "quirks-update: secret pattern detected in value, refusing" >&2
        return "$VPN_KIT_EXIT_VALIDATION"
      fi ;;
  esac

  _current_json="$(_yaml_to_json)"

  case "$op" in
    init)
      _new_json=$(printf '%s' "$_current_json" | jq 'if (. // {}) | length == 0 then {version: 1} else . end')
      ;;
    set)
      # Try to parse value as JSON scalar (number/bool/null); else treat as string.
      _is_scalar_json=0
      if printf '%s' "$value" | jq -e . >/dev/null 2>&1; then
        _vtype=$(printf '%s' "$value" | jq -r 'type' 2>/dev/null || echo string)
        case "$_vtype" in
          number|boolean|'null') _is_scalar_json=1 ;;
        esac
      fi
      if [ "$_is_scalar_json" = "1" ]; then
        _new_json=$(printf '%s' "$_current_json" | jq --argjson v "$value" --arg p "$path" 'setpath($p | split("."); $v)')
      else
        _new_json=$(printf '%s' "$_current_json" | jq --arg v "$value" --arg p "$path" 'setpath($p | split("."); $v)')
      fi
      ;;
    set-json)
      if ! printf '%s' "$raw_json" | jq -e . >/dev/null 2>&1; then
        echo "quirks-update: --raw-json is not valid JSON" >&2
        return "$VPN_KIT_EXIT_VALIDATION"
      fi
      _new_json=$(printf '%s' "$_current_json" | jq --argjson v "$raw_json" --arg p "$path" 'setpath($p | split("."); $v)')
      ;;
    unset)
      _new_json=$(printf '%s' "$_current_json" | jq --arg p "$path" 'delpaths([$p | split(".")])')
      ;;
  esac

  # Stamp CAS fields.
  _stamped=$(printf '%s' "$_new_json" | jq \
    --argjson rev "$_next_rev" \
    --arg writer "$writer" \
    --arg whost "$writer_host" \
    --arg now "$_now" \
    '. + {
       _revision: $rev,
       _last_writer: $writer,
       _last_updated_at: $now,
       version: (.version // 1)
     } + (if ($whost | length) > 0 then {_last_writer_host: $whost} else {} end)')

  # Convert back to YAML, atomically write.
  printf '%s' "$_stamped" | _json_to_yaml | vpn_kit_atomic_write "$VPN_KIT_QUIRKS_FILE" || return 1
  printf '%s\n' "$_next_rev"
  return 0
}

vpn_kit_with_lock quirks _do_write
exit $?
