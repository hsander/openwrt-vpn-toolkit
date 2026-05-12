#!/usr/bin/env bash
# bin/remove-domain.sh — remove a domain from /etc/sing-box/rules/vpn-domains.json.
# Mirror of bin/add-domain.sh.
#
# Usage:
#   bin/remove-domain.sh --router <alias> --domain <domain> [--no-backup]
#
# Exit codes:
#   0   ok (also if domain wasn't there — idempotent)
#   2   router not found / SSH unreachable
#  13   validation error
#  20   rollback fired
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
Usage: bin/remove-domain.sh --router <alias> --domain <domain> [--no-backup]

Удаляет домен из rule_set /etc/sing-box/rules/vpn-domains.json (v3),
валидирует, hot-reload sing-box. Снимок до изменения создаётся автоматически.

Options:
  --router <alias>   alias из memory/routers.yaml (обяз.)
  --domain <fqdn>    домен в нижнем регистре
  --no-backup        ⚠ только для тестов — пропустить pre-backup
EOF
  exit 64
}

router=""
domain=""
no_backup=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --domain) domain="${2:-}"; shift 2 ;;
    --no-backup) no_backup=1; shift ;;
    -h|--help) usage ;;
    *) echo "remove-domain: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "remove-domain: --router обязателен" >&2; usage; }
[ -z "$domain" ] && { echo "remove-domain: --domain обязателен" >&2; usage; }

# --- Validate domain (same rules as add-domain) -------------------------------
if printf '%s' "$domain" | grep -qE 'vless://|^[a-z]+://'; then
  echo "remove-domain: --domain выглядит как URL, нужен голый FQDN" >&2
  exit 13
fi
if ! printf '%s' "$domain" | grep -qE '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'; then
  echo "remove-domain: невалидный домен '$domain' (только [a-z0-9.-], нижний регистр)" >&2
  exit 13
fi
if printf '%s' "$domain" | grep -qE '\.\.|^\.|\.$|^-|-\.|\.-'; then
  echo "remove-domain: некорректная форма домена '$domain'" >&2
  exit 13
fi
case "$domain" in
  *.*) : ;;
  *) echo "remove-domain: '$domain' не содержит точки (нужен FQDN)" >&2; exit 13 ;;
esac

# --- Resolve router + SSH alive -----------------------------------------------
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  echo "remove-domain: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST)" >&2
  exit 2
fi

render_first_time_memory "$ROUTER_ALIAS" "$ROUTER_HOST"

TMP_LOCAL="$(mktemp -t openwrt-skill-rule.XXXXXX)"
TMP_LOCAL_NEW="$(mktemp -t openwrt-skill-rule.XXXXXX)"
cleanup() {
  rm -f "$TMP_LOCAL" "$TMP_LOCAL_NEW" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

REMOTE_RULESET="/etc/sing-box/rules/vpn-domains.json"
REMOTE_NEW="/tmp/openwrt-skill-vpn-domains-new.json"

# If the file doesn't exist on the router, the domain trivially isn't there.
if ! ssh_run "test -f $REMOTE_RULESET" >/dev/null 2>&1; then
  echo "remove-domain: $REMOTE_RULESET не существует — (уже отсутствует)" >&2
  exit 0
fi

if ! scp_from "$REMOTE_RULESET" "$TMP_LOCAL" >/dev/null 2>&1; then
  echo "remove-domain: не могу скачать $REMOTE_RULESET" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "remove-domain: локально нужен jq (brew install jq)" >&2
  exit 13
fi

if ! jq -e '.' "$TMP_LOCAL" >/dev/null 2>&1; then
  echo "remove-domain: $REMOTE_RULESET не валидный JSON" >&2
  exit 13
fi

# Idempotency: if domain absent across all rules — exit 0, no journal.
present="$(jq --arg d "$domain" '
  ((.rules // []) | [ .[]?.domain_suffix // [] ] | add // []) | index($d) != null
' "$TMP_LOCAL")"

if [ "$present" != "true" ]; then
  echo "remove-domain: '$domain' (уже отсутствует) — ничего не делаю" >&2
  exit 0
fi

# --- pre-backup ---------------------------------------------------------------
snapshot_id=""
if [ "$no_backup" = "1" ]; then
  echo "remove-domain: ⚠ --no-backup — пропускаю pre-backup. Только для тестов!" >&2
else
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
                        --label "before remove-domain $domain" --quiet)"; then
    echo "remove-domain: backup-now упал — отказываюсь продолжать" >&2
    exit 2
  fi
fi

rollback_now() {
  local reason="$1"
  if [ -z "$snapshot_id" ]; then
    echo "remove-domain: $reason; snapshot_id пуст — ручной откат" >&2
    return 1
  fi
  echo "remove-domain: $reason — восстанавливаю снимок $snapshot_id" >&2
  ssh_run "set -eu
SNAP_DIR=/etc/vpn-kit/snapshots
TAR=\"\$SNAP_DIR/${snapshot_id}.tar.gz\"
[ -f \"\$TAR\" ] || exit 1
tar -xzf \"\$TAR\" -C /
" >/dev/null 2>&1 || true
}

# --- Build new rule-set without the domain ------------------------------------
jq --arg d "$domain" '
  .rules = ((.rules // []) | map(
    if (.domain_suffix // null) != null then
      .domain_suffix = (.domain_suffix - [$d])
    else . end
  ))
  | .version = (.version // 3)
' "$TMP_LOCAL" > "$TMP_LOCAL_NEW"

if ! jq -e '.' "$TMP_LOCAL_NEW" >/dev/null 2>&1; then
  echo "remove-domain: после merge JSON битый" >&2
  exit 13
fi

# --- Push to /tmp, validate, atomic mv ---------------------------------------
if ! scp_to "$TMP_LOCAL_NEW" "$REMOTE_NEW" >/dev/null 2>&1; then
  echo "remove-domain: scp в $REMOTE_NEW не удался" >&2
  exit 2
fi

trap 'cleanup; ssh_run "rm -f $REMOTE_NEW" >/dev/null 2>&1 || true' EXIT INT TERM

if ! ssh_run "sing-box rule-set format $REMOTE_NEW >/dev/null" 2>&1; then
  echo "remove-domain: sing-box rule-set format отверг новый файл — откатываю" >&2
  rollback_now "невалидный rule-set"
  exit 20
fi

if ! ssh_run "mv -f $REMOTE_NEW $REMOTE_RULESET" >/dev/null 2>&1; then
  echo "remove-domain: не смог переместить rule-set — откатываю" >&2
  rollback_now "mv failed"
  exit 20
fi

if ! ssh_run "sing-box check -c /etc/sing-box/config.json" >/dev/null 2>&1; then
  echo "remove-domain: sing-box check отверг config — откатываю" >&2
  rollback_now "sing-box check failed"
  exit 20
fi

if ! ssh_run "pgrep -x sing-box >/dev/null" >/dev/null 2>&1; then
  ssh_run "/etc/init.d/sing-box-tproxy reload >/dev/null 2>&1 || /etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1 || {
    echo "remove-domain: sing-box не запущен и reload не помог — откатываю" >&2
    rollback_now "service reload failed"
    exit 20
  }
fi

# --- Update memory/<alias>/domains.md -----------------------------------------
DOMAINS_MD="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/domains.md"

if [ -f "$DOMAINS_MD" ]; then
  tmp_md="$(mktemp -t openwrt-skill-domains.XXXXXX)"
  # Drop any row whose first column matches `| $domain |`.
  # Then check if the table became empty; if so, insert _(пусто)_ marker.
  awk -v d="$domain" '
    BEGIN { in_table = 0; rows_kept = 0; saw_table = 0; printed_empty = 0 }
    /^\|[[:space:]]*-+/ { in_table = 1; saw_table = 1; print; next }
    in_table == 1 && /^\|/ {
      # Extract first cell value (trim).
      line = $0
      # First "|" is at start; find the next "|" to delimit cell 1.
      n = index(substr(line, 2), "|")
      if (n > 0) {
        cell1 = substr(line, 2, n - 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell1)
        if (cell1 == d) { next }   # skip
      }
      rows_kept++
      print
      next
    }
    # Leaving the table.
    in_table == 1 && !/^\|/ {
      in_table = 0
      if (rows_kept == 0 && printed_empty == 0) {
        print "_(пусто)_"
        printed_empty = 1
      }
      print
      next
    }
    { print }
    END {
      if (in_table == 1 && rows_kept == 0 && printed_empty == 0) {
        print "_(пусто)_"
      }
    }
  ' "$DOMAINS_MD" > "$tmp_md"
  mv "$tmp_md" "$DOMAINS_MD"
fi

# --- Journal ------------------------------------------------------------------
if ! memory_journal_append "$ROUTER_ALIAS" "remove_domain" \
       "domain=$domain" \
       "snapshot_before=${snapshot_id:-(skipped)}"; then
  echo "remove-domain: журнал не записан (не критично)" >&2
fi

cat >&2 <<EOF

remove-domain: готово.
  router:    $ROUTER_ALIAS
  domain:    $domain
  snapshot:  ${snapshot_id:-(skipped)}
  rule-set:  $REMOTE_RULESET (validated + hot-reloaded)
EOF

exit 0
