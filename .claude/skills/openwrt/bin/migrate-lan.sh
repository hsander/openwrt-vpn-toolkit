#!/usr/bin/env bash
# migrate-lan.sh — safe client for router-local LAN migration transactions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPENWRT_SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
source "$OPENWRT_SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
source "$OPENWRT_SKILL_HOME/lib/ssh-runner.sh"

usage() {
  cat <<'EOF'
Usage:
  bin/migrate-lan.sh --router <alias> --phase prepare --bundle <dir>
  bin/migrate-lan.sh --router <alias> --phase cutover|confirm|rollback|status|logs --migration-id <id>
    [--recovery-host <host> ...] [--timeout-seconds <n>]

prepare validates and uploads a pre-rendered bundle but applies no network changes.
cutover starts a detached router-local job and leaves rollback armed until confirm.
EOF
}

router=""
phase=""
bundle=""
migration_id=""
timeout_seconds=900
recovery_hosts=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --phase) phase="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --migration-id) migration_id="${2:-}"; shift 2 ;;
    --timeout-seconds) timeout_seconds="${2:-}"; shift 2 ;;
    --recovery-host) recovery_hosts+=("${2:-}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "migrate-lan: unknown arg: $1" >&2; usage >&2; exit 13 ;;
  esac
done

[[ "$phase" =~ ^(prepare|cutover|confirm|rollback|status|logs)$ ]] || {
  echo "migrate-lan: invalid or missing --phase" >&2
  exit 13
}
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( timeout_seconds >= 60 )) || {
  echo "migrate-lan: timeout must be an integer >= 60" >&2
  exit 13
}

resolve_router_config "$router"

use_recovery_host() {
  local host="$1"
  [[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
  ROUTER_HOST="$host"
  ROUTER_SSH_ALIAS=""
  export ROUTER_HOST ROUTER_SSH_ALIAS
}

run_with_recovery() {
  local command="$1" host
  if ((${#recovery_hosts[@]} == 0)); then
    ssh_run "$command"
    return
  fi
  for host in "${recovery_hosts[@]}"; do
    use_recovery_host "$host" || continue
    if ssh_run "$command"; then return 0; fi
  done
  echo "migrate-lan: no recovery host was reachable" >&2
  return 20
}

if [[ "$phase" == prepare ]]; then
  [[ -d "$bundle" && -f "$bundle/manifest.json" ]] || {
    echo "migrate-lan: prepare requires --bundle with manifest.json" >&2
    exit 13
  }
  migration_id="$(jq -r '.migration_id // ""' "$bundle/manifest.json")"
  [[ "$migration_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    echo "migrate-lan: bundle has invalid migration_id" >&2
    exit 13
  }
  remote_bundle="/tmp/vpn-kit-$migration_id.bundle"
  # Archive contents, not the directory itself; no filenames are interpolated remotely.
  tar -C "$bundle" -cf - . | ssh $(_ssh_key_arg) $(_ssh_common_opts | xargs) \
    -o ConnectTimeout=15 "$(_ssh_target)" "rm -rf '$remote_bundle'; mkdir -p '$remote_bundle'; tar -C '$remote_bundle' -xf -"
  result="$(ssh_run "/usr/sbin/vpn-kit-lan-migrate prepare --migration-id '$migration_id' --bundle-dir '$remote_bundle'")"
  printf '%s\n' "$result"
  cat <<EOF

RECOVERY COMMANDS — save before cutover:
  bin/migrate-lan.sh --router $ROUTER_ALIAS --migration-id $migration_id --phase rollback --recovery-host 192.168.99.1 --recovery-host 192.168.1.1
  /usr/sbin/vpn-kit-lan-migrate rollback --migration-id $migration_id
EOF
  exit 0
fi

[[ "$migration_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
  echo "migrate-lan: valid --migration-id is required" >&2
  exit 13
}

case "$phase" in
  cutover)
    ssh_run "/usr/sbin/vpn-kit-lan-migrate cutover --migration-id '$migration_id' --timeout-seconds '$timeout_seconds'"
    ;;
  confirm|rollback|status)
    run_with_recovery "/usr/sbin/vpn-kit-lan-migrate '$phase' --migration-id '$migration_id'"
    ;;
  logs)
    run_with_recovery "tail -n 200 '/etc/vpn-kit/lan-migrations/$migration_id/cutover.log'"
    ;;
esac
