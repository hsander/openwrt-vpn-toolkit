#!/usr/bin/env bash
# Mac-side verifier for final removal of 192.168.1.0/24 from the home router.

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

router=""
migration_id=""
timeout_seconds=600
foreground=0
log_dir="${TMPDIR:-/tmp}/vpn-kit-lan-supervisor"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --migration-id) migration_id="${2:-}"; shift 2 ;;
    --timeout-seconds) timeout_seconds="${2:-}"; shift 2 ;;
    --foreground) foreground=1; shift ;;
    -h|--help)
      echo "Usage: $0 --router home --migration-id <id> [--foreground]"
      exit 0 ;;
    *) echo "cleanup supervisor: unknown arg: $1" >&2; exit 13 ;;
  esac
done

[[ "$migration_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || exit 13
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] && ((timeout_seconds >= 120)) || exit 13

mkdir -p "$log_dir"
log_file="$log_dir/$migration_id.log"

if [[ "$foreground" == 0 ]]; then
  launch_label="com.vpnkit.$migration_id"
  launchctl remove "$launch_label" >/dev/null 2>&1 || true
  launchctl submit -l "$launch_label" -o "$log_file" -e "$log_file" -- \
    "$SELF_PATH" --router "$router" --migration-id "$migration_id" \
    --timeout-seconds "$timeout_seconds" --foreground
  printf 'supervisor_label=%s\nsupervisor_log=%s\n' "$launch_label" "$log_file"
  exit 0
fi

cleanup_launch_job() {
  launchctl remove "com.vpnkit.$migration_id" >/dev/null 2>&1 || true
}
if command -v launchctl >/dev/null 2>&1; then
  trap cleanup_launch_job EXIT
fi

printf '[%s] cleanup supervisor started migration=%s\n' "$(date -u +%FT%TZ)" "$migration_id"

default_route="$(route -n get default 2>/dev/null || true)"
printf '%s\n' "$default_route" | grep -q 'gateway: 192.168.99.1' || exit 13
printf '%s\n' "$default_route" | grep -q 'interface: en0' || exit 13
[[ "$(ipconfig getifaddr en0 2>/dev/null || true)" == 192.168.99.* ]] || exit 13

deadline=$(( $(date +%s) + timeout_seconds ))
successes=0

probe_all() {
  ping -c 1 -W 1000 192.168.99.1 >/dev/null
  ping -c 1 -W 1000 192.168.99.50 >/dev/null
  ping -c 1 -W 1000 192.168.99.150 >/dev/null
  nc -z -G 2 192.168.99.50 22
  nc -z -G 2 192.168.99.50 443
  dig +time=2 +tries=1 @192.168.99.1 openwrt.org A >/dev/null
  curl -fsS --max-time 8 https://api.ipify.org >/dev/null
  curl -fsS --max-time 10 --proxy http://192.168.99.1:4002 https://api.ipify.org >/dev/null
  curl -fsSI --max-time 10 https://panel.rasplet.ru >/dev/null
  status="$($SCRIPT_DIR/migrate-lan.sh --router "$router" --phase status \
    --migration-id "$migration_id" --recovery-host 192.168.99.1)"
  [[ "$(jq -r '.state' <<<"$status")" == applied_unconfirmed ]]
}

while (( $(date +%s) < deadline )); do
  if probe_all; then
    successes=$((successes + 1))
    printf '[%s] full cleanup probe success %s/3\n' "$(date -u +%FT%TZ)" "$successes"
    if ((successes >= 3)); then
      "$SCRIPT_DIR/migrate-lan.sh" --router "$router" --phase confirm \
        --migration-id "$migration_id" --recovery-host 192.168.99.1
      printf '[%s] cleanup migration confirmed\n' "$(date -u +%FT%TZ)"
      exit 0
    fi
  else
    successes=0
    printf '[%s] cleanup probe incomplete; rollback remains armed\n' "$(date -u +%FT%TZ)"
  fi
  sleep 5
done

printf '[%s] timeout without confirm; router timer will rollback\n' "$(date -u +%FT%TZ)"
exit 20
