#!/usr/bin/env bash
# bin/add-domain.sh — append a domain to the sing-box rule_set used by the VPN
# routing path. Single edit point: /etc/sing-box/rules/vpn-domains.json (rule_set v3).
#
# Flow:
#   1. Resolve router + SSH alive.
#   2. Validate domain shape (lowercase / dots / hyphens; no IPs; no `vless://`).
#   3. Pre-backup via bin/backup-now.sh — capture snapshot ID for rollback.
#   4. SCP rule-set file down (or seed minimal v3 if absent). Merge domain into
#      the first rule's `domain_suffix` array. Validate JSON locally.
#   5. SCP back to /tmp on router. Validate via `sing-box rule-set format`.
#      Atomic mv to /etc/sing-box/rules/vpn-domains.json + sing-box check on
#      the main config. Hot-reload (rule_set auto-reloads); if process not
#      running, fall back to `service sing-box-tproxy reload`.
#   6. On failure after the SCP step — restore the snapshot.
#   7. Update memory/<alias>/domains.md (defensive table edit).
#   8. Journal: `add_domain`.
#
# Usage:
#   bin/add-domain.sh --router <alias> --domain <domain> [--outbound <tag>] [--no-backup]
#
# Exit codes:
#   0   ok (or no-op idempotent skip — also ok)
#   2   router not found / SSH unreachable
#  13   validation error (bad domain, secret in label)
#  20   rollback fired — operation reverted
#  64   bad CLI args

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
Usage: bin/add-domain.sh --router <alias> --domain <domain> [--outbound <tag>] [--no-backup]

Добавляет домен в rule_set /etc/sing-box/rules/vpn-domains.json (v3),
валидирует, hot-reload sing-box. Снимок до изменения создаётся автоматически.

Options:
  --router <alias>   alias из memory/routers.yaml (обяз.)
  --domain <fqdn>    домен в нижнем регистре (буквы, цифры, точки, дефис). IP не годится.
  --outbound <tag>   outbound-tag (по умолчанию auto-failover)
  --no-backup        ⚠ только для тестов — пропустить pre-backup
EOF
  exit 64
}

router=""
domain=""
outbound="auto-failover"
no_backup=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --domain) domain="${2:-}"; shift 2 ;;
    --outbound) outbound="${2:-}"; shift 2 ;;
    --no-backup) no_backup=1; shift ;;
    -h|--help) usage ;;
    *) echo "add-domain: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "add-domain: --router обязателен" >&2; usage; }
[ -z "$domain" ] && { echo "add-domain: --domain обязателен" >&2; usage; }

# --- Validate domain shape -----------------------------------------------------
# Lowercase ascii letters/digits/dots/hyphens. No `vless://`-looking content
# (which would suggest someone pasted a VPN URL). Reject IPs (use add-ip.sh).
if printf '%s' "$domain" | grep -qE 'vless://|^[a-z]+://'; then
  echo "add-domain: --domain выглядит как URL, нужен голый FQDN" >&2
  exit 13
fi

if ! printf '%s' "$domain" | grep -qE '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'; then
  echo "add-domain: невалидный домен '$domain' (только [a-z0-9.-], нижний регистр)" >&2
  exit 13
fi

# Reject double-dot / leading-dot / trailing-dot / leading-hyphen patterns.
if printf '%s' "$domain" | grep -qE '\.\.|^\.|\.$|^-|-\.|\.-'; then
  echo "add-domain: некорректная форма домена '$domain'" >&2
  exit 13
fi

# Reject IPv4: dotted quad of 1-3 digit octets.
if printf '%s' "$domain" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
  echo "add-domain: '$domain' — IP-адрес, не домен. Используй bin/add-ip.sh" >&2
  exit 13
fi

# Must contain at least one dot (TLD requirement).
case "$domain" in
  *.*) : ;;
  *) echo "add-domain: '$domain' не содержит точки (нужен FQDN)" >&2; exit 13 ;;
esac

# Outbound tag shape: alphanumeric + _- only, max 32 chars (defense in depth
# even though V1 only accepts a fixed value).
if ! printf '%s' "$outbound" | grep -qE '^[a-zA-Z0-9_-]{1,32}$'; then
  echo "add-domain: невалидный --outbound '$outbound' (только [A-Za-z0-9_-], max 32)" >&2
  exit 13
fi

# --- Resolve router + SSH alive ------------------------------------------------
# Done BEFORE the "auto-failover only" gate so an unreachable-host error
# (exit 2) takes precedence over the V1-scope refusal (exit 13). Without this
# ordering, a CI mock against a fake router would fail with the wrong code.
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
add-domain: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
EOF
  exit 2
fi

# V1 scope decision: this script ONLY supports the default auto-failover
# outbound. Per-tag pinning (rule-set /etc/sing-box/rules/pin-<tag>.json plus
# a matching route.rules entry in config.json) is planned for V1.1 but not
# yet implemented. Failing fast prevents the outbound-blind idempotency bug
# where requesting --outbound foo silently added the domain to the auto-
# failover rule-set anyway.
if [ "$outbound" != "auto-failover" ]; then
  cat >&2 <<EOF
add-domain: V1 поддерживает только --outbound auto-failover.
Per-tag pinning (например, --outbound vpn-de или --outbound proxy-ru) запланирован
на V1.1: он требует отдельного rule_set /etc/sing-box/rules/pin-${outbound}.json
+ соответствующего route.rules в /etc/sing-box/config.json. Сейчас этот путь
не реализован, и я отказываюсь делать вид, что он работает.

Workaround: добавь домен в auto-failover (--outbound auto-failover — это default),
или открой задачу на pinning в memory/<alias>/decisions.md.
EOF
  exit 13
fi

# Make sure memory exists so we can journal afterwards.
render_first_time_memory "$ROUTER_ALIAS" "$ROUTER_HOST"

# --- Temp files (clean up on exit) --------------------------------------------
TMP_LOCAL="$(mktemp -t openwrt-skill-rule.XXXXXX)"
TMP_LOCAL_NEW="$(mktemp -t openwrt-skill-rule.XXXXXX)"
cleanup() {
  rm -f "$TMP_LOCAL" "$TMP_LOCAL_NEW" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Step 1: pre-backup (capture snapshot id) ----------------------------------
snapshot_id=""
if [ "$no_backup" = "1" ]; then
  echo "add-domain: ⚠ --no-backup — пропускаю pre-backup. Используй только в тестах!" >&2
else
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
                        --label "before add-domain $domain" --quiet)"; then
    echo "add-domain: backup-now упал — отказываюсь продолжать" >&2
    exit 2
  fi
fi

# Helper: restore from snapshot in case anything fails after we changed files.
rollback_now() {
  local reason="$1"
  if [ -z "$snapshot_id" ]; then
    echo "add-domain: $reason; но snapshot_id пуст (--no-backup), ручной откат" >&2
    return 1
  fi
  echo "add-domain: $reason — восстанавливаю снимок $snapshot_id" >&2
  ssh_run "set -eu
SNAP_DIR=/etc/vpn-kit/snapshots
TAR=\"\$SNAP_DIR/${snapshot_id}.tar.gz\"
[ -f \"\$TAR\" ] || exit 1
tar -xzf \"\$TAR\" -C /
" >/dev/null 2>&1 || {
    echo "add-domain: rollback ssh не отработал — состояние неизвестно" >&2
  }
}

# --- Step 2: pull current rule-set (or seed empty v3) -------------------------
REMOTE_RULESET="/etc/sing-box/rules/vpn-domains.json"
REMOTE_NEW="/tmp/openwrt-skill-vpn-domains-new.json"

# Use grep -q over ssh_run to detect presence robustly.
if ssh_run "test -f $REMOTE_RULESET" >/dev/null 2>&1; then
  if ! scp_from "$REMOTE_RULESET" "$TMP_LOCAL" >/dev/null 2>&1; then
    echo "add-domain: не могу скачать $REMOTE_RULESET" >&2
    exit 2
  fi
else
  # Seed minimal rule_set v3.
  cat > "$TMP_LOCAL" <<'SEED'
{
  "version": 3,
  "rules": [
    {
      "domain_suffix": []
    }
  ]
}
SEED
fi

# Local validation: must parse as JSON.
if ! command -v jq >/dev/null 2>&1; then
  echo "add-domain: локально нужен jq (brew install jq)" >&2
  exit 13
fi

if ! jq -e '.' "$TMP_LOCAL" >/dev/null 2>&1; then
  echo "add-domain: $REMOTE_RULESET не валидный JSON, отказываюсь" >&2
  exit 13
fi

# Idempotency check + merge via jq.
# V1 only operates on /etc/sing-box/rules/vpn-domains.json (auto-failover).
# The (domain, outbound) idempotency key collapses to just `domain` here —
# we're guaranteed by the validation above that outbound == "auto-failover".
# When V1.1 adds per-tag pin-<tag>.json files, this script will need to
# select the correct rule_set path and re-check idempotency there.
already_present="$(jq --arg d "$domain" '
  (.rules // []) as $r
  | [ $r[]?.domain_suffix // [] ] | add // []
  | index($d) != null
' "$TMP_LOCAL")"

if [ "$already_present" = "true" ]; then
  cat >&2 <<EOF
add-domain: домен '$domain' уже в rule-set'е — ничего не меняю.
EOF
  # Idempotent: do not journal duplicate, just exit 0.
  exit 0
fi

# Merge: if rules[] is empty or no rule has domain_suffix, create one.
jq --arg d "$domain" '
  if (.rules | length) == 0 then
    .rules = [{"domain_suffix": [$d]}]
  else
    # Find the index of the first rule that has domain_suffix.
    (
      [ .rules | to_entries[] | select(.value.domain_suffix != null) | .key ] as $idxs
      | if ($idxs | length) > 0 then
          .rules[$idxs[0]].domain_suffix = ((.rules[$idxs[0]].domain_suffix // []) + [$d] | unique)
        else
          .rules[0].domain_suffix = [$d]
        end
    )
  end
  | .version = (.version // 3)
' "$TMP_LOCAL" > "$TMP_LOCAL_NEW"

if ! jq -e '.' "$TMP_LOCAL_NEW" >/dev/null 2>&1; then
  echo "add-domain: после merge JSON битый — отказываюсь" >&2
  exit 13
fi

# --- Step 3: push to /tmp, validate via sing-box, atomic mv -------------------
if ! scp_to "$TMP_LOCAL_NEW" "$REMOTE_NEW" >/dev/null 2>&1; then
  echo "add-domain: scp в $REMOTE_NEW не удался" >&2
  exit 2
fi

# Always clean up remote temp.
trap 'cleanup; ssh_run "rm -f $REMOTE_NEW" >/dev/null 2>&1 || true' EXIT INT TERM

# Validate v3 schema via sing-box.
if ! ssh_run "sing-box rule-set format $REMOTE_NEW >/dev/null" 2>&1; then
  echo "add-domain: sing-box rule-set format отверг новый файл — откатываю" >&2
  rollback_now "невалидный rule-set"
  exit 20
fi

# Atomic mv into place. NB: literal path, not $(dirname …) — the latter
# would expand on the AGENT side, not on the router (cosmetic but misleading
# in case REMOTE_RULESET ever changes).
if ! ssh_run "mkdir -p /etc/sing-box/rules && mv -f $REMOTE_NEW $REMOTE_RULESET" >/dev/null 2>&1; then
  echo "add-domain: не смог переместить rule-set на месте — откатываю" >&2
  rollback_now "mv failed"
  exit 20
fi

# Full config check.
if ! ssh_run "sing-box check -c /etc/sing-box/config.json" >/dev/null 2>&1; then
  echo "add-domain: sing-box check отверг config после изменения — откатываю" >&2
  rollback_now "sing-box check failed"
  exit 20
fi

# Hot reload trick: sing-box re-reads local rule_set on file change. Confirm
# sing-box is alive; if not, attempt a controlled reload (NOT restart).
if ! ssh_run "pgrep -x sing-box >/dev/null" >/dev/null 2>&1; then
  ssh_run "/etc/init.d/sing-box-tproxy reload >/dev/null 2>&1 || /etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1 || {
    echo "add-domain: sing-box не запущен и reload не помог — откатываю" >&2
    rollback_now "service reload failed"
    exit 20
  }
fi

# --- Step 4: update memory/<alias>/domains.md (defensive) ---------------------
DOMAINS_MD="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/domains.md"
iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
new_row="| $domain | $outbound | $iso | claude-code |"

if [ ! -f "$DOMAINS_MD" ]; then
  echo "add-domain: $DOMAINS_MD отсутствует — запусти doctor.sh" >&2
else
  if grep -qF '{{DOMAIN_TABLE_ROWS}}' "$DOMAINS_MD"; then
    # Just-initialised template: replace placeholder with new row + placeholder
    # (so the next add appends correctly above the placeholder).
    tmp_md="$(mktemp -t openwrt-skill-domains.XXXXXX)"
    awk -v row="$new_row" '
      /\{\{DOMAIN_TABLE_ROWS\}\}/ {
        print row
        print
        next
      }
      { print }
    ' "$DOMAINS_MD" > "$tmp_md"
    mv "$tmp_md" "$DOMAINS_MD"
  elif grep -qF "_(пока пусто — добавь через bin/add-domain.sh)_" "$DOMAINS_MD"; then
    # Rendered template's "empty" placeholder.
    tmp_md="$(mktemp -t openwrt-skill-domains.XXXXXX)"
    awk -v row="$new_row" '
      /_\(пока пусто — добавь через bin\/add-domain\.sh\)_/ {
        print row
        next
      }
      { print }
    ' "$DOMAINS_MD" > "$tmp_md"
    mv "$tmp_md" "$DOMAINS_MD"
  else
    # Has real rows. Insert after the last row of the markdown table.
    # A table row starts with "| " and contains "|"; we want to append after
    # the last consecutive row in the "Активные правила" table.
    tmp_md="$(mktemp -t openwrt-skill-domains.XXXXXX)"
    awk -v row="$new_row" '
      BEGIN { in_table = 0; inserted = 0 }
      # Detect entering the table by separator row "|---|---|...".
      /^\|[[:space:]]*-+/ { in_table = 1; print; next }
      # Table row.
      in_table == 1 && /^\|/ { last_table_line = NR; print; next }
      # First non-table line after entering table — insert before it.
      in_table == 1 && !/^\|/ && inserted == 0 {
        print row
        inserted = 1
        in_table = 0
        print
        next
      }
      { print }
      END {
        if (in_table == 1 && inserted == 0) print row
      }
    ' "$DOMAINS_MD" > "$tmp_md"
    mv "$tmp_md" "$DOMAINS_MD"
  fi
fi

# --- Step 5: journal ----------------------------------------------------------
if ! memory_journal_append "$ROUTER_ALIAS" "add_domain" \
       "domain=$domain" "outbound=$outbound" \
       "snapshot_before=${snapshot_id:-(skipped)}"; then
  echo "add-domain: журнал не записан (не критично)" >&2
fi

cat >&2 <<EOF

add-domain: готово.
  router:    $ROUTER_ALIAS
  domain:    $domain
  outbound:  $outbound
  snapshot:  ${snapshot_id:-(skipped)}
  rule-set:  $REMOTE_RULESET (validated + hot-reloaded)
EOF

exit 0
