#!/usr/bin/env bash
# Read-only inspection of SSH listeners and firewall zones. No key material.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$SKILL_HOME/memory}"
. "$SKILL_HOME/lib/router-config.sh"
. "$SKILL_HOME/lib/ssh-runner.sh"

[ "${1:-}" = "--router" ] && [ -n "${2:-}" ] && [ $# -eq 2 ] || {
  echo "Usage: bin/inspect-management-access.sh --router <alias>" >&2
  exit 64
}
resolve_router_config "$2"
ssh_check_alive 5 || exit 2

ssh_run_remote <<'REMOTE_SH'
set -u
echo "dropbear_config_begin"
uci -q show dropbear 2>/dev/null | grep -E '\.(Interface|Port|PasswordAuth|RootPasswordAuth)=' || true
echo "dropbear_config_end"
echo "tcp_listeners_begin"
ss -ltn 2>/dev/null | grep -E '(^|[.:])22[[:space:]]' || netstat -ltn 2>/dev/null | grep -E '(^|[.:])22[[:space:]]' || true
echo "tcp_listeners_end"
echo "firewall_zones_begin"
for zone in $(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)=zone$/\1/p"); do
  name="$(uci -q get firewall."$zone".name || true)"
  input="$(uci -q get firewall."$zone".input || true)"
  networks="$(uci -q get firewall."$zone".network || true)"
  echo "zone=$zone name=$name input=$input networks=$networks"
done
echo "firewall_zones_end"
REMOTE_SH
