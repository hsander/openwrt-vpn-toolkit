#!/usr/bin/env bash
# Install only the autonomous rollback/LAN migration runtime. No network reload.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPENWRT_SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
source "$OPENWRT_SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
source "$OPENWRT_SKILL_HOME/lib/ssh-runner.sh"

router=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: bin/install-lan-migration-runtime.sh --router <alias>"; exit 0 ;;
    *) echo "install-lan-migration-runtime: unknown arg: $1" >&2; exit 13 ;;
  esac
done

resolve_router_config "$router"

snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" --label "before LAN migration runtime" --quiet)"
[[ -n "$snapshot_id" ]] || { echo "runtime install: backup did not return snapshot id" >&2; exit 13; }

stage="/tmp/vpn-kit-lan-runtime"
tar -C "$OPENWRT_SKILL_HOME" -cf - \
  lib/vpn-kit-common.sh \
  lib/journal-append.sh \
  lib/state-write.sh \
  lib/snapshot-gc.sh \
  lib/rollback-snapshot.sh \
  lib/vpn-kit-rollback.sh \
  lib/lan-migrate-runtime.sh \
  openwrt/init.d/vpn-kit-rollback \
  | ssh $(_ssh_key_arg) $(_ssh_common_opts | xargs) -o ConnectTimeout=15 "$(_ssh_target)" \
      "rm -rf '$stage'; mkdir -p '$stage'; tar -C '$stage' -xf -"

ssh_run_remote_with_args /dev/stdin "$stage" <<'SH'
set -eu
stage="$1"
for file in "$stage"/lib/*.sh "$stage"/openwrt/init.d/vpn-kit-rollback; do
  sh -n "$file"
done
command -v jq >/dev/null
mkdir -p /usr/lib/vpn-kit /usr/sbin /etc/vpn-kit/rollback.d /etc/vpn-kit/snapshots /etc/vpn-kit/journal /etc/init.d
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="/etc/vpn-kit/runtime-backups/$stamp"
mkdir -p "$backup"
for path in /usr/lib/vpn-kit/vpn-kit-common.sh /usr/lib/vpn-kit/journal-append.sh \
  /usr/lib/vpn-kit/state-write.sh /usr/lib/vpn-kit/snapshot-gc.sh \
  /usr/lib/vpn-kit/rollback-snapshot.sh /usr/lib/vpn-kit/vpn-kit-rollback.sh \
  /usr/lib/vpn-kit/lan-migrate-runtime.sh /etc/init.d/vpn-kit-rollback \
  /usr/sbin/vpn-kit-rollback /usr/sbin/vpn-kit-lan-migrate; do
  [ -e "$path" ] && cp "$path" "$backup/$(echo "$path" | sed 's#[^A-Za-z0-9._-]#_#g')"
done
for src in "$stage"/lib/*.sh; do
  dst="/usr/lib/vpn-kit/$(basename "$src")"
  cp "$src" "$dst.new"
  chmod 0755 "$dst.new"
  mv -f "$dst.new" "$dst"
done
cp "$stage"/openwrt/init.d/vpn-kit-rollback /etc/init.d/vpn-kit-rollback.new
chmod 0755 /etc/init.d/vpn-kit-rollback.new
mv -f /etc/init.d/vpn-kit-rollback.new /etc/init.d/vpn-kit-rollback
printf '%s\n' '#!/bin/sh' 'exec /usr/lib/vpn-kit/vpn-kit-rollback.sh "$@"' > /usr/sbin/vpn-kit-rollback
printf '%s\n' '#!/bin/sh' 'exec /usr/lib/vpn-kit/lan-migrate-runtime.sh "$@"' > /usr/sbin/vpn-kit-lan-migrate
chmod 0755 /usr/sbin/vpn-kit-rollback /usr/sbin/vpn-kit-lan-migrate
/etc/init.d/vpn-kit-rollback enable
/etc/init.d/vpn-kit-rollback restart
sleep 1
/etc/init.d/vpn-kit-rollback running
/usr/sbin/vpn-kit-rollback --once
printf 'runtime_backup=%s\n' "$backup"
printf 'runtime_status=running\n'
SH

printf 'snapshot_id=%s\n' "$snapshot_id"
