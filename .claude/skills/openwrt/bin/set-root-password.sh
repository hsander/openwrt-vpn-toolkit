#!/usr/bin/env bash
# Change the OpenWrt root/LuCI password without printing or journaling it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  echo "Usage: bin/set-root-password.sh --password-stdin --router <alias> [--ssh-alias <alias>]" >&2
  exit 64
}

router=""
ssh_alias=""
password_stdin=0
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --password-stdin) password_stdin=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$router" ] && [ "$password_stdin" = 1 ] || usage
if [ -n "$ssh_alias" ]; then
  [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
fi

printf 'New root password: ' >&2
IFS= read -r -s password
printf '\n' >&2
[ "${#password}" -ge 8 ] && [ "${#password}" -le 127 ] || {
  echo "set-root-password: password must be 8..127 characters" >&2
  exit 13
}
if printf '%s' "$password" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  echo "set-root-password: control characters are not allowed" >&2
  exit 13
fi

resolve_router_config "$router"
backup_args=(--router "$router" --label "before root password change" --quiet)
[ -n "$ssh_alias" ] && backup_args+=(--ssh-alias "$ssh_alias")
snapshot_id="$($SCRIPT_DIR/backup-now.sh "${backup_args[@]}")"

password_hex="$(printf '%s' "$password" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
unset password

if [ -n "$ssh_alias" ]; then
  ssh_target="$ssh_alias"
  ssh_extra=(-o BatchMode=yes)
else
  ssh_target="$ROUTER_USER@$ROUTER_HOST"
  ssh_extra=(-o BatchMode=yes -i "$ROUTER_SSH_KEY" -o "HostKeyAlias=${ROUTER_HOST_KEY_ALIAS:-$ROUTER_HOST}")
fi

set +e
result="$(ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 \
  "${ssh_extra[@]}" \
  "$ssh_target" \
  "sh -s -- '$password_hex'" <<'REMOTE_SH'
set -eu
password_hex="$1"

hex_decode() {
  hex="$1"
  while [ -n "$hex" ]; do
    byte="$(printf '%.2s' "$hex")"
    hex="${hex#??}"
    printf "\\x$byte"
  done
}

password="$(hex_decode "$password_hex")"
shadow_backup="$(mktemp /tmp/shadow.before-password.XXXXXX)"
cp /etc/shadow "$shadow_backup"
chmod 600 "$shadow_backup"
old_hash="$(awk -F: '$1=="root" {print $2}' /etc/shadow)"
success=0

rollback() {
  [ "$success" = 1 ] && return 0
  cp "$shadow_backup" /etc/shadow
  chmod 600 /etc/shadow
}
cleanup() {
  rollback
  rm -f "$shadow_backup"
  unset password old_hash new_hash
}
trap cleanup EXIT INT TERM HUP

[ -n "$old_hash" ]
printf '%s\n%s\n' "$password" "$password" | passwd root >/dev/null 2>&1
new_hash="$(awk -F: '$1=="root" {print $2}' /etc/shadow)"
[ -n "$new_hash" ]
[ "$new_hash" != '!' ] && [ "$new_hash" != '*' ]
[ "$new_hash" != "$old_hash" ]
/etc/init.d/rpcd running >/dev/null 2>&1
/etc/init.d/uhttpd running >/dev/null 2>&1
JSON_PREFIX=""
set +u
. /usr/share/libubox/jshn.sh
json_init
json_add_string username root
json_add_string password "$password"
auth_payload="$(json_dump)"
auth_result="$(ubus call session login "$auth_payload" 2>/dev/null || true)"
auth_session="$(printf '%s' "$auth_result" | jsonfilter -e '@.ubus_rpc_session' 2>/dev/null || true)"
[ -n "$auth_session" ]
unset auth_payload auth_result auth_session
set -u

success=1
echo "root_password_changed=true"
echo "luci_authentication=verified"
REMOTE_SH
)"
rc=$?
set -e
unset password_hex

if [ "$rc" -ne 0 ]; then
  echo "set-root-password: change failed and /etc/shadow was restored (snapshot=$snapshot_id)" >&2
  exit 20
fi

printf '%s\n' "$result"
echo "snapshot=$snapshot_id"
memory_journal_append "$router" "root_password_changed"
