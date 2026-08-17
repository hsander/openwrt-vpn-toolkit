#!/usr/bin/env bash
# Build and prepare the final removal of 192.168.1.0/24 from the home router.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPENWRT_SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
source "$OPENWRT_SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
source "$OPENWRT_SKILL_HOME/lib/ssh-runner.sh"

router=""
build_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --build-only) build_only=1; shift ;;
    -h|--help) echo "Usage: $0 --router home [--build-only]"; exit 0 ;;
    *) echo "prepare-home-lan-cleanup: unknown arg: $1" >&2; exit 13 ;;
  esac
done

resolve_router_config "$router"
migration_id="lan99-cleanup-$(date -u +%Y%m%d%H%M%S)"
remote_bundle="/tmp/vpn-kit-$migration_id.bundle"

ssh_run_remote_with_args "$SCRIPT_DIR/build-home-lan-cleanup-bundle-remote.sh" \
  "$migration_id" "$remote_bundle" >/dev/null

if [[ "$build_only" == 1 ]]; then
  ssh_run "jq '{migration_id,files:[.files[]|{path,staged,mode}],scripts:(.scripts|keys)}' '$remote_bundle/manifest.json'"
  ssh_run "uci -c '$remote_bundle/files' show network.lan; uci -c '$remote_bundle/files' show firewall.localbackend_8080; jq -c '[.inbounds[] | select(.listen == \"192.168.1.1\" or .listen == \"192.168.99.1\") | {tag,listen,listen_port}]' '$remote_bundle/files/sing-box-config.json'; jq -c '[.route.rules[] | select(((.source_ip // []) + (.source_ip_cidr // [])) | any(startswith(\"192.168.1.\") or startswith(\"192.168.99.\"))) | {source_ip,source_ip_cidr,outbound}]' '$remote_bundle/files/sing-box-config.json'; grep -n '192\.168\.1\.' '$remote_bundle/files/sing-box-tproxy' || true"
  printf 'migration_id=%s\nremote_bundle=%s\n' "$migration_id" "$remote_bundle"
  exit 0
fi

result="$(ssh_run "/usr/sbin/vpn-kit-lan-migrate prepare --migration-id '$migration_id' --bundle-dir '$remote_bundle'")"
printf '%s\n' "$result"
cat <<EOF

MIGRATION_ID=$migration_id
ROLLBACK FROM THIS MAC:
  bin/migrate-lan.sh --router $ROUTER_ALIAS --migration-id $migration_id --phase rollback --recovery-host 192.168.99.1
ROLLBACK FROM ROUTER CONSOLE:
  /usr/sbin/vpn-kit-lan-migrate rollback --migration-id $migration_id
EOF
