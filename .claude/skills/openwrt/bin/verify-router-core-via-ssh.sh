#!/usr/bin/env bash
# Read-only core health proof through an arbitrary trusted SSH alias.

set -euo pipefail

ssh_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    *) echo "Usage: bin/verify-router-core-via-ssh.sh --ssh-alias <alias>" >&2; exit 64 ;;
  esac
done
[[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13

ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 \
  "$ssh_alias" 'sh -s' <<'REMOTE_SH'
set -eu

echo "default_route=$(ip -4 route show default | head -n 1)"

if [ -f /etc/sing-box/config.json ] && command -v sing-box >/dev/null 2>&1; then
  if sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
    echo "singbox_config_valid=true"
  else
    echo "singbox_config_valid=false"
    exit 1
  fi
  if /etc/init.d/sing-box-tproxy status >/dev/null 2>&1 || pgrep -f sing-box >/dev/null 2>&1; then
    echo "singbox_running=true"
  else
    echo "singbox_running=false"
    exit 1
  fi
else
  echo "singbox_config_valid=not_installed"
  echo "singbox_running=not_installed"
fi

zapret_service=""
for candidate in zapret2 zapret; do
  [ -x "/etc/init.d/$candidate" ] && { zapret_service="$candidate"; break; }
done
if [ -n "$zapret_service" ]; then
  if "/etc/init.d/$zapret_service" status >/dev/null 2>&1 || pgrep -f '[n]fqws' >/dev/null 2>&1; then
    echo "zapret_running=true"
  else
    echo "zapret_running=false"
    exit 1
  fi
else
  echo "zapret_running=not_installed"
fi
REMOTE_SH
