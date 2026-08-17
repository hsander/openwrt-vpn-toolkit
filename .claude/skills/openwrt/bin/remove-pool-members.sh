#!/usr/bin/env bash
# Remove one or more existing outbound tags from a sing-box urltest pool while
# keeping the outbound definitions themselves intact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/remove-pool-members.sh --router <alias> --pool <tag> --member <tag> [--member <tag> ...] [--no-backup]

Removes members only from a urltest pool. Outbound definitions and route rules
are preserved. Refuses to leave the pool empty.
EOF
  exit 64
}

router=""
pool=""
no_backup=0
members=()

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --pool) pool="${2:-}"; shift 2 ;;
    --member) members+=("${2:-}"); shift 2 ;;
    --no-backup) no_backup=1; shift ;;
    -h|--help) usage ;;
    *) echo "remove-pool-members: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$router" ] || { echo "remove-pool-members: --router is required" >&2; usage; }
[ -n "$pool" ] || { echo "remove-pool-members: --pool is required" >&2; usage; }
[ "${#members[@]}" -gt 0 ] || { echo "remove-pool-members: at least one --member is required" >&2; usage; }

for value in "$pool" "${members[@]}"; do
  if ! printf '%s' "$value" | grep -qE '^[a-zA-Z0-9_-]{1,64}$'; then
    echo "remove-pool-members: invalid tag '$value'" >&2
    exit 13
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "remove-pool-members: local jq is required" >&2
  exit 13
fi

resolve_router_config "$router"
if ! ssh_check_alive 5; then
  echo "remove-pool-members: SSH unavailable for '$ROUTER_ALIAS' (host=$ROUTER_HOST)" >&2
  exit 2
fi

remote_cfg="/etc/sing-box/config.json"
remote_new="/tmp/openwrt-skill-config-new.$$.json"
local_cfg="$(mktemp -t openwrt-skill-pool.XXXXXX)"
local_new="$(mktemp -t openwrt-skill-pool-new.XXXXXX)"
members_json="$(printf '%s\n' "${members[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"

cleanup() {
  rm -f "$local_cfg" "$local_new" 2>/dev/null || true
  ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if ! scp_from "$remote_cfg" "$local_cfg" >/dev/null 2>&1; then
  echo "remove-pool-members: cannot download $remote_cfg" >&2
  exit 2
fi

if ! jq -e --arg pool "$pool" '.outbounds[]? | select(.type == "urltest" and .tag == $pool)' "$local_cfg" >/dev/null; then
  echo "remove-pool-members: urltest pool '$pool' not found" >&2
  exit 13
fi

current_json="$(jq -c --arg pool "$pool" '.outbounds[] | select(.tag == $pool) | (.outbounds // [])' "$local_cfg")"
removed_json="$(jq -cn --argjson current "$current_json" --argjson requested "$members_json" '$current | map(select(. as $m | $requested | index($m))) | unique')"
remaining_json="$(jq -cn --argjson current "$current_json" --argjson requested "$members_json" '$current | map(select(. as $m | ($requested | index($m) | not)))')"

if [ "$(jq 'length' <<<"$removed_json")" -eq 0 ]; then
  echo "remove-pool-members: requested members are already absent from '$pool'" >&2
  exit 0
fi
if [ "$(jq 'length' <<<"$remaining_json")" -eq 0 ]; then
  echo "remove-pool-members: refusing to leave pool '$pool' empty" >&2
  exit 13
fi

for member in "${members[@]}"; do
  if jq -e --arg member "$member" 'index($member) != null' <<<"$removed_json" >/dev/null && \
     ! jq -e --arg member "$member" '.outbounds[]? | select(.tag == $member)' "$local_cfg" >/dev/null; then
    echo "remove-pool-members: pool member '$member' has no outbound definition" >&2
    exit 13
  fi
done

snapshot_id=""
if [ "$no_backup" = "1" ]; then
  echo "remove-pool-members: --no-backup, skipping pre-backup (tests only)" >&2
else
  removed_csv="$(jq -r 'join(",")' <<<"$removed_json")"
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" --label "before remove $removed_csv from $pool" --quiet)"; then
    echo "remove-pool-members: backup failed; refusing to continue" >&2
    exit 2
  fi
fi

rollback_now() {
  local reason="$1"
  echo "remove-pool-members: $reason" >&2
  [ -n "$snapshot_id" ] || return 0
  ssh_run "set -eu
TAR=/etc/vpn-kit/snapshots/${snapshot_id}.tar.gz
[ -f \"\$TAR\" ]
tar -xzf \"\$TAR\" -C /
/etc/init.d/sing-box-tproxy restart
" >/dev/null 2>&1 || true
}

if ! jq --arg pool "$pool" --argjson remove "$members_json" '
  .outbounds |= map(
    if .type == "urltest" and .tag == $pool then
      .outbounds = ((.outbounds // []) | map(select(. as $m | ($remove | index($m) | not))))
      | if has("default") and (((.default // "") as $d | (.outbounds | index($d))) == null) then
          .default = .outbounds[0]
        else . end
    else . end
  )
' "$local_cfg" > "$local_new"; then
  rollback_now "local config update failed"
  exit 13
fi

if [ "$(jq '.outbounds | length' "$local_cfg")" != "$(jq '.outbounds | length' "$local_new")" ]; then
  rollback_now "guard failed: outbound definitions changed"
  exit 13
fi
if ! scp_to "$local_new" "$remote_new" >/dev/null 2>&1; then
  rollback_now "cannot upload candidate config"
  exit 2
fi
check_output=""
if ! check_output="$(ssh_run "sing-box check -c $remote_new" 2>&1)"; then
  rollback_now "sing-box check rejected candidate config"
  printf '%s\n' "$check_output" | sed -E 's#vless://[^[:space:]]+#[REDACTED]#g' >&2
  exit 20
fi
if ! ssh_run "chmod 600 $remote_new && mv -f $remote_new $remote_cfg && /etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1; then
  rollback_now "install or restart failed; restored snapshot"
  exit 20
fi
if ! ssh_check_alive 8 || ! ssh_run "/etc/init.d/sing-box-tproxy status >/dev/null 2>&1 || pgrep -f sing-box >/dev/null" >/dev/null 2>&1; then
  rollback_now "router or sing-box unhealthy after restart; restored snapshot"
  exit 20
fi

actual_json="$(ssh_run "jq -c --arg pool '$pool' '.outbounds[] | select(.tag == \$pool) | .outbounds' $remote_cfg" 2>/dev/null || true)"
if [ "$actual_json" != "$(jq -c . <<<"$remaining_json")" ]; then
  rollback_now "post-check mismatch; restored snapshot"
  exit 20
fi

cat >&2 <<EOF

remove-pool-members: done.
  router:    $ROUTER_ALIAS
  pool:      $pool
  removed:   $(jq -r 'join(", ")' <<<"$removed_json")
  remaining: $(jq -r 'join(", ")' <<<"$remaining_json")
  snapshot:  ${snapshot_id:-(skipped)}
EOF
