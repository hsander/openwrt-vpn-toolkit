#!/usr/bin/env bash
# Read-only SSH login proof for a configured local SSH alias.

set -euo pipefail

alias_name=""
expected_ip=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-alias) alias_name="${2:-}"; shift 2 ;;
    --expected-ip) expected_ip="${2:-}"; shift 2 ;;
    *) echo "Usage: bin/verify-ssh-endpoint.sh --ssh-alias <alias> --expected-ip <ip>" >&2; exit 64 ;;
  esac
done

[[ "$alias_name" =~ ^[A-Za-z0-9_.-]+$ ]] || exit 13
[[ "$expected_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 13

resolved_host="$(ssh -G "$alias_name" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
if [ "$resolved_host" != "$expected_ip" ]; then
  echo "ssh_alias_target_ok=false"
  exit 1
fi
echo "ssh_alias_target_ok=true"

result="$(ssh \
  -o BatchMode=yes \
  -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 \
  "$alias_name" \
  'printf "remote_hostname=%s\nuptime_seconds=%s\n" "$(uci -q get system.@system[0].hostname || hostname)" "$(cut -d. -f1 /proc/uptime)"')"
printf '%s\n' "$result"
echo "ssh_login=ok"
