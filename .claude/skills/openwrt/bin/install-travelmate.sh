#!/usr/bin/env bash
# Install the official Travelmate backend and LuCI frontend without changing
# network or wireless configuration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  echo "Usage: bin/install-travelmate.sh --router <alias> [--ssh-alias <alias>]" >&2
  exit 64
}

router=""
ssh_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$router" ] || usage

resolve_router_config "$router"
if [ -n "$ssh_alias" ]; then
  [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
  ssh_cmd=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 "$ssh_alias")
else
  ssh_check_alive 5 || exit 2
  ssh_cmd=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -i "$ROUTER_SSH_KEY" -o HostKeyAlias="${ROUTER_HOST_KEY_ALIAS:-$ROUTER_HOST}" "$ROUTER_USER@$ROUTER_HOST")
fi

backup_args=(--router "$router" --label "before travelmate packages" --quiet)
[ -z "$ssh_alias" ] || backup_args+=(--ssh-alias "$ssh_alias")
snapshot_id="$($SCRIPT_DIR/backup-now.sh "${backup_args[@]}")"

"${ssh_cmd[@]}" 'sh -s' <<'REMOTE_SH'
set -eu

command -v apk >/dev/null 2>&1 || {
  echo "install-travelmate: apk package manager required" >&2
  exit 13
}

already_installed=0
if apk info -e luci-app-travelmate >/dev/null 2>&1 && apk info -e travelmate >/dev/null 2>&1; then
  already_installed=1
  echo "travelmate_packages=already_installed"
else
  apk update
  apk add luci-app-travelmate
fi

apk info -e luci-app-travelmate >/dev/null 2>&1
apk info -e travelmate >/dev/null 2>&1
command -v curl >/dev/null 2>&1
[ -x /etc/init.d/travelmate ]

# A fresh package installation must not seize control of the existing uplink.
# An idempotent re-run on an already configured travel router must preserve the
# service state instead of silently disabling a healthy setup.
if [ "$already_installed" = 0 ]; then
  /etc/init.d/travelmate stop >/dev/null 2>&1 || true
  /etc/init.d/travelmate disable >/dev/null 2>&1 || true
fi

echo "travelmate_packages=installed"
/etc/init.d/travelmate enabled >/dev/null 2>&1 && enabled=true || enabled=false
/etc/init.d/travelmate running >/dev/null 2>&1 && running=true || running=false
echo "travelmate_enabled=$enabled"
echo "travelmate_running=$running"
REMOTE_SH

memory_journal_append "$router" "travelmate_packages_installed"
echo "snapshot=$snapshot_id"
