#!/usr/bin/env bash
# Finalize non-routing LAN metadata after 192.168.1.0/24 removal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPENWRT_SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
source "$OPENWRT_SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
source "$OPENWRT_SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/install-state-remote.sh
source "$OPENWRT_SKILL_HOME/lib/install-state-remote.sh"

router=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: $0 --router <alias>"; exit 0 ;;
    *) echo "finalize-lan99-metadata: unknown arg: $1" >&2; exit 13 ;;
  esac
done

resolve_router_config "$router"
snapshot="$($OPENWRT_SKILL_HOME/bin/backup-now.sh --router "$ROUTER_ALIAS" \
  --label 'before final LAN99 metadata cleanup' --quiet)"
printf 'snapshot=%s\n' "$snapshot"

ensure_router_lib_deployed
revision="$(remote_read_revision)"
state_json="$(remote_read_state_json)"
payload="$(printf '%s' "$state_json" | jq '
  del(._revision, ._last_writer, ._last_writer_host, ._last_updated_at)
  | .dynamic_additions = [(.dynamic_additions // [])[]
      | if ((.value // "") | startswith("192.168.1."))
        then .value |= sub("^192\\.168\\.1\\."; "192.168.99.")
        else . end]
')"
new_revision="$(remote_cas_write codex@lan99-finalize "$revision" "$payload")"
printf 'install_state_revision=%s\n' "$new_revision"

ssh_run_remote <<'SH'
set -eu
path='/usr/bin/polsha-fallback-watchdog.sh'
if [ -f "$path" ] && grep -q '192\.168\.1\.' "$path"; then
  sed 's/192\.168\.1\./192.168.99./g' "$path" > "$path.new"
  sh -n "$path.new"
  chmod 0755 "$path.new"
  mv -f "$path.new" "$path"
fi

! jq -e '.. | strings | select(contains("192.168.1."))' \
  /etc/vpn-kit/install-state.json >/dev/null
if [ -f "$path" ]; then
  ! grep -q '192\.168\.1\.' "$path"
fi
echo metadata_cleanup=ok
SH
