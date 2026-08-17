#!/usr/bin/env bash
# bin/set-rule-set-outbound.sh - point existing sing-box route rule_set rules
# at another outbound tag. This is a narrow safe operation for already-wired
# rule_sets such as telegram/tg-pin.
#
# Usage:
#   bin/set-rule-set-outbound.sh --router <alias> --rule-set <tag> --outbound <tag> [--no-backup]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"
# shellcheck source=../lib/template-render.sh
. "$SKILL_HOME/lib/template-render.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/set-rule-set-outbound.sh --router <alias> --rule-set <tag> --outbound <tag> [--no-backup]

Changes the outbound of existing route.rules that reference a rule_set tag.

Options:
  --router <alias>    alias from memory/routers.yaml
  --rule-set <tag>    route rule_set tag to find
  --outbound <tag>    existing outbound tag to use
  --no-backup         tests only - skip pre-backup
EOF
  exit 64
}

router=""
rule_set=""
outbound=""
no_backup=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --rule-set) rule_set="${2:-}"; shift 2 ;;
    --outbound) outbound="${2:-}"; shift 2 ;;
    --no-backup) no_backup=1; shift ;;
    -h|--help) usage ;;
    *) echo "set-rule-set-outbound: unknown argument: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "set-rule-set-outbound: --router is required" >&2; usage; }
[ -z "$rule_set" ] && { echo "set-rule-set-outbound: --rule-set is required" >&2; usage; }
[ -z "$outbound" ] && { echo "set-rule-set-outbound: --outbound is required" >&2; usage; }

if ! printf '%s' "$rule_set" | grep -qE '^[a-zA-Z0-9_-]{1,64}$'; then
  echo "set-rule-set-outbound: invalid --rule-set '$rule_set'" >&2
  exit 13
fi
if ! printf '%s' "$outbound" | grep -qE '^[a-zA-Z0-9_-]{1,64}$'; then
  echo "set-rule-set-outbound: invalid --outbound '$outbound'" >&2
  exit 13
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "set-rule-set-outbound: local jq is required" >&2
  exit 13
fi

resolve_router_config "$router"

if ! ssh_check_alive 5; then
  echo "set-rule-set-outbound: SSH unavailable for '$ROUTER_ALIAS' (host=$ROUTER_HOST)" >&2
  exit 2
fi

render_first_time_memory "$ROUTER_ALIAS" "$ROUTER_HOST"

REMOTE_CONFIG="/etc/sing-box/config.json"
REMOTE_NEW="/tmp/openwrt-skill-config-new.json"

if ! ssh_run "jq -e --arg t '$outbound' '.outbounds[]? | select(.tag == \$t)' $REMOTE_CONFIG >/dev/null 2>&1"; then
  echo "set-rule-set-outbound: outbound '$outbound' not found in config.json" >&2
  exit 13
fi

match_count="$(ssh_run "jq -r --arg rs '$rule_set' '
  def has_rs:
    (.rule_set? // null) as \$v
    | if \$v == null then false
      elif (\$v | type) == \"array\" then any(\$v[]; . == \$rs)
      elif (\$v | type) == \"string\" then \$v == \$rs
      else false end;
  [ .route.rules[]? | select(has_rs) ] | length
' $REMOTE_CONFIG" 2>/dev/null || true)"

if ! printf '%s' "$match_count" | grep -qE '^[0-9]+$' || [ "$match_count" -eq 0 ]; then
  echo "set-rule-set-outbound: no route.rules reference rule_set '$rule_set'" >&2
  exit 13
fi

snapshot_id=""
if [ "$no_backup" = "1" ]; then
  echo "set-rule-set-outbound: --no-backup, skipping pre-backup. Tests only." >&2
else
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
                        --label "before set-rule-set-outbound $rule_set to $outbound" --quiet)"; then
    echo "set-rule-set-outbound: backup-now failed, refusing to continue" >&2
    exit 2
  fi
fi

rollback_now() {
  local reason="$1"
  if [ -z "$snapshot_id" ]; then
    echo "set-rule-set-outbound: $reason; no snapshot_id, manual rollback required" >&2
    return 1
  fi
  echo "set-rule-set-outbound: $reason - restoring snapshot $snapshot_id" >&2
  ssh_run "set -eu
SNAP_DIR=/etc/vpn-kit/snapshots
TAR=\"\$SNAP_DIR/${snapshot_id}.tar.gz\"
[ -f \"\$TAR\" ] || exit 1
tar -xzf \"\$TAR\" -C /
" >/dev/null 2>&1 || true
}

TMP_CONFIG="$(mktemp -t openwrt-skill-config.XXXXXX)"
TMP_CONFIG_NEW="$(mktemp -t openwrt-skill-config-new.XXXXXX)"
cleanup() {
  rm -f "$TMP_CONFIG" "$TMP_CONFIG_NEW" 2>/dev/null || true
  ssh_run "rm -f $REMOTE_NEW" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if ! scp_from "$REMOTE_CONFIG" "$TMP_CONFIG" >/dev/null 2>&1; then
  echo "set-rule-set-outbound: cannot download $REMOTE_CONFIG" >&2
  rollback_now "scp failed"
  exit 2
fi

before_rules_count="$(jq -r '.route.rules | length' "$TMP_CONFIG")"

if ! jq --arg rs "$rule_set" --arg outbound "$outbound" '
  def has_rs:
    (.rule_set? // null) as $v
    | if $v == null then false
      elif ($v | type) == "array" then any($v[]; . == $rs)
      elif ($v | type) == "string" then $v == $rs
      else false end;
  .route.rules |= map(if has_rs then .outbound = $outbound else . end)
' "$TMP_CONFIG" > "$TMP_CONFIG_NEW"; then
  echo "set-rule-set-outbound: jq update failed" >&2
  rollback_now "local jq failed"
  exit 13
fi

after_rules_count="$(jq -r '.route.rules | length' "$TMP_CONFIG_NEW")"
if [ "$before_rules_count" != "$after_rules_count" ]; then
  echo "set-rule-set-outbound: internal guard failed: route.rules count changed ($before_rules_count -> $after_rules_count)" >&2
  rollback_now "route.rules count changed"
  exit 13
fi

updated_count="$(jq -r --arg rs "$rule_set" --arg outbound "$outbound" '
  def has_rs:
    (.rule_set? // null) as $v
    | if $v == null then false
      elif ($v | type) == "array" then any($v[]; . == $rs)
      elif ($v | type) == "string" then $v == $rs
      else false end;
  [ .route.rules[]? | select(has_rs and .outbound == $outbound) ] | length
' "$TMP_CONFIG_NEW")"
if [ "$updated_count" != "$match_count" ]; then
  echo "set-rule-set-outbound: internal guard failed: updated $updated_count of $match_count matching rule(s)" >&2
  rollback_now "matching rules not updated"
  exit 13
fi

if ! scp_to "$TMP_CONFIG_NEW" "$REMOTE_NEW" >/dev/null 2>&1; then
  echo "set-rule-set-outbound: cannot upload new config" >&2
  rollback_now "scp to /tmp failed"
  exit 2
fi

check_output=""
if ! check_output="$(ssh_run "sing-box check -c $REMOTE_NEW" 2>&1)"; then
  echo "set-rule-set-outbound: sing-box check rejected new config" >&2
  printf '%s\n' "$check_output" | sed -E 's#vless://[^[:space:]]+#[REDACTED]#g' >&2
  rollback_now "sing-box check failed"
  exit 20
fi

if ! ssh_run "mv -f $REMOTE_NEW $REMOTE_CONFIG" >/dev/null 2>&1; then
  echo "set-rule-set-outbound: cannot install new config" >&2
  rollback_now "mv failed"
  exit 20
fi

if ! ssh_run "/etc/init.d/sing-box-tproxy reload >/dev/null 2>&1 || /etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1; then
  echo "set-rule-set-outbound: service reload failed" >&2
  rollback_now "service reload failed"
  exit 20
fi

# FakeIP cache maps domain -> real IP -> outbound. A bare reload keeps serving
# already-resolved domains through the OLD outbound until the cache entry
# expires, silently undoing the switch we just made. Must clear + restart
# every time, not just on hot-reload.
if ! ssh_run "rm -f /usr/share/sing-box/cache.db && /etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1; then
  echo "set-rule-set-outbound: FakeIP cache reset failed — переключение применено, но старые соединения могут ещё идти через прежний outbound. Сбрось вручную: rm -f /usr/share/sing-box/cache.db && /etc/init.d/sing-box-tproxy restart" >&2
fi

if ! memory_journal_append "$ROUTER_ALIAS" "set_rule_set_outbound" \
       "rule_set=$rule_set" \
       "outbound=$outbound" \
       "changed_rules=$match_count" \
       "snapshot_before=${snapshot_id:-(skipped)}"; then
  echo "set-rule-set-outbound: journal not written (non-critical)" >&2
fi

cat >&2 <<EOF

set-rule-set-outbound: done.
  router:        $ROUTER_ALIAS
  rule_set:      $rule_set
  outbound:      $outbound
  changed_rules: $match_count
  snapshot:      ${snapshot_id:-(skipped)}
  config:        validated + hot-reloaded
EOF

exit 0
