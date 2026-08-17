#!/usr/bin/env bash
# Build and prepare the 192.168.1.0/24 -> 192.168.99.0/24 home migration.
# No network configuration is applied by this command.

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
    -h|--help) echo "Usage: bin/prepare-home-lan-migration.sh --router <alias>"; exit 0 ;;
    *) echo "prepare-home-lan-migration: unknown arg: $1" >&2; exit 13 ;;
  esac
done

resolve_router_config "$router"
migration_id="lan99-$(date -u +%Y%m%d%H%M%S)"
remote_bundle="/tmp/vpn-kit-$migration_id.bundle"

ssh_run_remote_with_args "$OPENWRT_SKILL_HOME/lib/build-home-lan-bundle-remote.sh" \
  "$migration_id" 192.168.1 192.168.99 "$remote_bundle" >/dev/null

if [[ "$build_only" == 1 ]]; then
  ssh_run "jq '{migration_id,files:[.files[]|{path,staged,mode}],scripts:(.scripts|keys)}' '$remote_bundle/manifest.json'"
  ssh_run "uci -c '$remote_bundle/files' show network.lan; uci -c '$remote_bundle/files' show dhcp.lan; uci -c '$remote_bundle/files' show dhcp | grep -E \"=host|\\.name=|\\.mac=|\\.ip='192\\.168\\.99\\.\"; uci -c '$remote_bundle/files' show firewall | grep -E \"=redirect|\\.name=|\\.src_dport=|\\.dest_ip='192\\.168\\.99\\.\"; jq -c '[.inbounds[] | select(.listen == \"192.168.99.1\") | {tag,listen,listen_port}]' '$remote_bundle/files/sing-box-config.json'; jq -c '[.route.rules[] | select(((.source_ip // []) + (.source_ip_cidr // [])) | any(startswith(\"192.168.99.\"))) | {source_ip,source_ip_cidr,outbound}]' '$remote_bundle/files/sing-box-config.json'; grep -nE '192\\.168\\.99\\.(139|150|191)' '$remote_bundle/files/sing-box-tproxy'"
  printf 'remote_bundle=%s\n' "$remote_bundle"
  exit 0
fi

result="$(ssh_run "/usr/sbin/vpn-kit-lan-migrate prepare --migration-id '$migration_id' --bundle-dir '$remote_bundle'")"
printf '%s\n' "$result"
cat <<EOF

MIGRATION_ID=$migration_id

ROLLBACK FROM THIS MAC:
  bin/migrate-lan.sh --router $ROUTER_ALIAS --migration-id $migration_id --phase rollback --recovery-host 192.168.99.1 --recovery-host 192.168.1.1

ROLLBACK FROM ROUTER CONSOLE:
  /usr/sbin/vpn-kit-lan-migrate rollback --migration-id $migration_id
EOF
