#!/usr/bin/env bash
# bin/add-domain.sh — append a domain to the sing-box rule_set used by the VPN
# routing path.
#
# For --outbound auto-failover:
#   Writes to /etc/sing-box/rules/vpn-domains.json (tag: vpn-domains).
#
# For --outbound <tag>:
#   Writes to /etc/sing-box/rules/user-<tag>-domains.json (tag: user-<tag>).
#   Creates the file if absent, and wires rule_set + dns.rules fakeip +
#   route.rules into config.json automatically (insert before auto-failover).
#   Requires the outbound tag to already exist in config.json (add it first
#   via bin/add-vpn.sh).
#
# Flow:
#   1. Resolve router + SSH alive.
#   2. Validate domain shape.
#   3. Pre-backup via bin/backup-now.sh.
#   4. Pull rule-set file (or seed minimal v3). Merge domain. Validate JSON.
#   5. Push to /tmp on router. Validate via sing-box rule-set format.
#      Atomic mv. Ensure config.json routes the rule_set correctly.
#      sing-box check. Hot-reload.
#   6. On failure after SCP — restore snapshot.
#   7. Update memory/<alias>/domains.md.
#   8. Journal: add_domain.
#
# Usage:
#   bin/add-domain.sh --router <alias> --domain <domain> [--outbound <tag>] [--no-backup]
#
# Exit codes:
#   0   ok (or no-op idempotent skip)
#   2   router not found / SSH unreachable
#  13   validation error (bad domain, unknown outbound, secret in label)
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
Usage: bin/add-domain.sh --router <alias> --domain <domain> [--outbound <tag>] [--no-backup]

Добавляет домен в rule_set для указанного outbound.

  --outbound auto-failover  → /etc/sing-box/rules/vpn-domains.json (default)
  --outbound <tag>          → /etc/sing-box/rules/user-<tag>-domains.json
                              (файл + маршрут создаются автоматически;
                               outbound должен уже быть в config.json)

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

# --- Validate domain shape ----------------------------------------------------
if printf '%s' "$domain" | grep -qE 'vless://|^[a-z]+://'; then
  echo "add-domain: --domain выглядит как URL, нужен голый FQDN" >&2
  exit 13
fi

if ! printf '%s' "$domain" | grep -qE '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'; then
  echo "add-domain: невалидный домен '$domain' (только [a-z0-9.-], нижний регистр)" >&2
  exit 13
fi

if printf '%s' "$domain" | grep -qE '\.\.|^\.|\.$|^-|-\.|\.-'; then
  echo "add-domain: некорректная форма домена '$domain'" >&2
  exit 13
fi

if printf '%s' "$domain" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
  echo "add-domain: '$domain' — IP-адрес, не домен. Используй bin/add-ip.sh" >&2
  exit 13
fi

case "$domain" in
  *.*) : ;;
  *) echo "add-domain: '$domain' не содержит точки (нужен FQDN)" >&2; exit 13 ;;
esac

if ! printf '%s' "$outbound" | grep -qE '^[a-zA-Z0-9_-]{1,32}$'; then
  echo "add-domain: невалидный --outbound '$outbound' (только [A-Za-z0-9_-], max 32)" >&2
  exit 13
fi

# --- Resolve router + SSH alive -----------------------------------------------
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
add-domain: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
EOF
  exit 2
fi

# --- Compute rule-set file and tag based on outbound -------------------------
REMOTE_CONFIG="/etc/sing-box/config.json"
REMOTE_CONFIG_NEW="/tmp/openwrt-skill-config-new.json"

if [ "$outbound" = "auto-failover" ]; then
  REMOTE_RULESET="/etc/sing-box/rules/vpn-domains.json"
  RULESET_TAG="vpn-domains"
else
  REMOTE_RULESET="/etc/sing-box/rules/user-${outbound}-domains.json"
  RULESET_TAG="user-${outbound}"
fi

REMOTE_NEW="/tmp/openwrt-skill-vpn-domains-new.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "add-domain: локально нужен jq (brew install jq)" >&2
  exit 13
fi

# For non-auto-failover outbounds, verify the outbound tag exists in config.
if [ "$outbound" != "auto-failover" ]; then
  if ! ssh_run "jq -e --arg t '$outbound' '.outbounds[]? | select(.tag == \$t)' $REMOTE_CONFIG >/dev/null 2>&1"; then
    cat >&2 <<EOF
add-domain: outbound '$outbound' не найден в config.json.
Добавь VPN-ноду сначала через bin/add-vpn.sh, затем повтори.
EOF
    exit 13
  fi
fi

render_first_time_memory "$ROUTER_ALIAS" "$ROUTER_HOST"

# --- Temp files ---------------------------------------------------------------
TMP_LOCAL="$(mktemp -t openwrt-skill-rule.XXXXXX)"
TMP_LOCAL_NEW="$(mktemp -t openwrt-skill-rule.XXXXXX)"
TMP_CONFIG="$(mktemp -t openwrt-skill-config.XXXXXX)"
TMP_CONFIG_NEW="$(mktemp -t openwrt-skill-config-new.XXXXXX)"
cleanup() {
  rm -f "$TMP_LOCAL" "$TMP_LOCAL_NEW" "$TMP_CONFIG" "$TMP_CONFIG_NEW" 2>/dev/null || true
}
trap 'cleanup; ssh_run "rm -f $REMOTE_NEW $REMOTE_CONFIG_NEW" >/dev/null 2>&1 || true' EXIT INT TERM

# --- Step 1: pre-backup -------------------------------------------------------
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

rollback_now() {
  local reason="$1"
  if [ -z "$snapshot_id" ]; then
    echo "add-domain: $reason; snapshot_id пуст (--no-backup), ручной откат" >&2
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

# --- ensure_auto_failover_route: wire vpn-domains into auto-failover rule ----
# (original ensure_vpn_domains_route logic, unchanged)
config_route_changed=0

ensure_auto_failover_route() {
  if ssh_run "jq -e '
    any(.route.rule_set[]?; .tag == \"vpn-domains\" and .path == \"$REMOTE_RULESET\")
    and any(.route.rules[]?; .outbound == \"auto-failover\" and ((.rule_set // []) | index(\"vpn-domains\")))
  ' $REMOTE_CONFIG >/dev/null" >/dev/null 2>&1; then
    return 0
  fi

  if ! scp_from "$REMOTE_CONFIG" "$TMP_CONFIG" >/dev/null 2>&1; then
    echo "add-domain: не могу скачать $REMOTE_CONFIG для проверки маршрута" >&2
    return 1
  fi

  jq --arg ruleset "$REMOTE_RULESET" '
    .route.rule_set = ((.route.rule_set // []) as $rs
      | if any($rs[]?; .tag == "vpn-domains") then $rs
        else $rs + [{"type":"local","tag":"vpn-domains","format":"source","path":$ruleset}]
        end)
    | .route.rules = ((.route.rules // []) | map(
        if .outbound == "auto-failover" and ((.rule_set // []) | index("user-vpn")) then
          .rule_set = ((.rule_set + ["vpn-domains"]) | unique)
        else . end
      ))
  ' "$TMP_CONFIG" > "$TMP_CONFIG_NEW"

  if ! jq -e --arg ruleset "$REMOTE_RULESET" '
    any(.route.rule_set[]?; .tag == "vpn-domains" and .path == $ruleset)
    and any(.route.rules[]?; .outbound == "auto-failover" and ((.rule_set // []) | index("vpn-domains")))
  ' "$TMP_CONFIG_NEW" >/dev/null; then
    echo "add-domain: не нашёл auto-failover rule с user-vpn, не могу привязать vpn-domains" >&2
    return 1
  fi

  if ! scp_to "$TMP_CONFIG_NEW" "$REMOTE_CONFIG_NEW" >/dev/null 2>&1; then
    echo "add-domain: scp в $REMOTE_CONFIG_NEW не удался" >&2
    return 1
  fi

  if ! ssh_run "set -eu
sing-box check -c $REMOTE_CONFIG_NEW >/dev/null
mv -f $REMOTE_CONFIG_NEW $REMOTE_CONFIG
" >/dev/null 2>&1; then
    echo "add-domain: не смог валидно привязать vpn-domains к auto-failover" >&2
    return 1
  fi

  config_route_changed=1
}

# --- ensure_tag_route: wire user-<tag>-domains into per-tag route ------------
ensure_tag_route() {
  if ! scp_from "$REMOTE_CONFIG" "$TMP_CONFIG" >/dev/null 2>&1; then
    echo "add-domain: не могу скачать $REMOTE_CONFIG" >&2
    return 1
  fi

  # Check if already fully wired (rule_set entry + dns fakeip + route rule).
  if jq -e --arg tag "$RULESET_TAG" --arg path "$REMOTE_RULESET" --arg out "$outbound" '
    any(.route.rule_set[]?; .tag == $tag and .path == $path)
    and ((.dns.rules // []) | any(.server == "fakeip-dns" and ((.rule_set // []) | any(. == $tag))))
    and any(.route.rules[]?; ((.rule_set // []) | any(. == $tag)) and .outbound == $out)
  ' "$TMP_CONFIG" >/dev/null 2>&1; then
    return 0
  fi

  # Wire rule_set entry + dns fakeip + route rule.
  jq --arg tag "$RULESET_TAG" --arg path "$REMOTE_RULESET" --arg out "$outbound" '
    .route.rule_set = ((.route.rule_set // []) as $rs
      | if any($rs[]?; .tag == $tag) then $rs
        else $rs + [{"type":"local","tag":$tag,"format":"source","path":$path}]
        end)
    | .dns.rules = ((.dns.rules // []) | map(
        if .server == "fakeip-dns" then
          .rule_set = ((.rule_set // []) + [$tag] | unique | sort)
        else . end
      ))
    | if any(.route.rules[]?; ((.rule_set // []) | any(. == $tag)) and .outbound == $out)
      then .
      else
        .route.rules = (
          (.route.rules // []) | to_entries |
          (map(select(.value.outbound == "auto-failover")) | .[0].key // -1) as $idx |
          if $idx >= 0 then
            (.[:$idx] | map(.value))
            + [{"inbound":"tproxy-in","rule_set":[$tag],"outbound":$out}]
            + (.[$idx:] | map(.value))
          else
            map(.value) + [{"inbound":"tproxy-in","rule_set":[$tag],"outbound":$out}]
          end
        )
      end
  ' "$TMP_CONFIG" > "$TMP_CONFIG_NEW"

  if ! scp_to "$TMP_CONFIG_NEW" "$REMOTE_CONFIG_NEW" >/dev/null 2>&1; then
    echo "add-domain: scp в $REMOTE_CONFIG_NEW не удался" >&2
    return 1
  fi

  if ! ssh_run "set -eu
sing-box check -c $REMOTE_CONFIG_NEW >/dev/null
mv -f $REMOTE_CONFIG_NEW $REMOTE_CONFIG
" >/dev/null 2>&1; then
    echo "add-domain: sing-box check отверг config с новым маршрутом для $RULESET_TAG" >&2
    return 1
  fi

  config_route_changed=1
}

ensure_outbound_route() {
  if [ "$outbound" = "auto-failover" ]; then
    ensure_auto_failover_route
  else
    ensure_tag_route
  fi
}

# --- Step 2: pull current rule-set (or seed empty v3) ------------------------
if ssh_run "test -f $REMOTE_RULESET" >/dev/null 2>&1; then
  if ! scp_from "$REMOTE_RULESET" "$TMP_LOCAL" >/dev/null 2>&1; then
    echo "add-domain: не могу скачать $REMOTE_RULESET" >&2
    exit 2
  fi
else
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

if ! jq -e '.' "$TMP_LOCAL" >/dev/null 2>&1; then
  echo "add-domain: $REMOTE_RULESET не валидный JSON, отказываюсь" >&2
  exit 13
fi

# Idempotency check via grep (works for JSONC too).
if grep -qF "\"$domain\"" "$TMP_LOCAL" 2>/dev/null; then
  already_present="true"
else
  already_present="false"
fi

if [ "$already_present" = "true" ]; then
  if ! ensure_outbound_route; then
    rollback_now "outbound route binding failed"
    exit 20
  fi

  if [ "$config_route_changed" = "1" ]; then
    ssh_run "/etc/init.d/sing-box-tproxy reload >/dev/null 2>&1 || /etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1 || {
      echo "add-domain: config изменён, но reload не помог — откатываю" >&2
      rollback_now "service reload failed"
      exit 20
    }
  fi

  cat >&2 <<EOF
add-domain: домен '$domain' уже в rule-set'е — ничего не меняю.
EOF
  exit 0
fi

# Merge: add domain to first rule with domain_suffix (plain JSON only).
jq --arg d "$domain" '
  if (.rules | length) == 0 then
    .rules = [{"domain_suffix": [$d]}]
  else
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

# --- Step 3: push to /tmp, validate via sing-box, atomic mv ------------------
if ! scp_to "$TMP_LOCAL_NEW" "$REMOTE_NEW" >/dev/null 2>&1; then
  echo "add-domain: scp в $REMOTE_NEW не удался" >&2
  exit 2
fi

if ! ssh_run "sing-box rule-set format $REMOTE_NEW >/dev/null" 2>&1; then
  echo "add-domain: sing-box rule-set format отверг новый файл — откатываю" >&2
  rollback_now "невалидный rule-set"
  exit 20
fi

if ! ssh_run "mkdir -p /etc/sing-box/rules && mv -f $REMOTE_NEW $REMOTE_RULESET" >/dev/null 2>&1; then
  echo "add-domain: не смог переместить rule-set на месте — откатываю" >&2
  rollback_now "mv failed"
  exit 20
fi

if ! ensure_outbound_route; then
  echo "add-domain: не смог привязать $RULESET_TAG к $outbound — откатываю" >&2
  rollback_now "outbound route binding failed"
  exit 20
fi

if ! ssh_run "sing-box check -c /etc/sing-box/config.json" >/dev/null 2>&1; then
  echo "add-domain: sing-box check отверг config после изменения — откатываю" >&2
  rollback_now "sing-box check failed"
  exit 20
fi

if [ "$config_route_changed" = "1" ]; then
  ssh_run "/etc/init.d/sing-box-tproxy reload >/dev/null 2>&1 || /etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1 || {
    echo "add-domain: config изменён, но reload не помог — откатываю" >&2
    rollback_now "service reload failed"
    exit 20
  }
elif ! ssh_run "pgrep -x sing-box >/dev/null" >/dev/null 2>&1; then
  ssh_run "/etc/init.d/sing-box-tproxy reload >/dev/null 2>&1 || /etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1 || {
    echo "add-domain: sing-box не запущен и reload не помог — откатываю" >&2
    rollback_now "service reload failed"
    exit 20
  }
fi

# --- Step 4: update memory/<alias>/domains.md --------------------------------
DOMAINS_MD="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/domains.md"
iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
new_row="| $domain | $outbound | $iso | claude-code |"

if [ ! -f "$DOMAINS_MD" ]; then
  echo "add-domain: $DOMAINS_MD отсутствует — запусти doctor.sh" >&2
else
  if grep -qF '{{DOMAIN_TABLE_ROWS}}' "$DOMAINS_MD"; then
    tmp_md="$(mktemp -t openwrt-skill-domains.XXXXXX)"
    awk -v row="$new_row" '
      /\{\{DOMAIN_TABLE_ROWS\}\}/ { print row; print; next }
      { print }
    ' "$DOMAINS_MD" > "$tmp_md"
    mv "$tmp_md" "$DOMAINS_MD"
  elif grep -qF "_(пока пусто — добавь через bin/add-domain.sh)_" "$DOMAINS_MD"; then
    tmp_md="$(mktemp -t openwrt-skill-domains.XXXXXX)"
    awk -v row="$new_row" '
      /_\(пока пусто — добавь через bin\/add-domain\.sh\)_/ { print row; next }
      { print }
    ' "$DOMAINS_MD" > "$tmp_md"
    mv "$tmp_md" "$DOMAINS_MD"
  else
    tmp_md="$(mktemp -t openwrt-skill-domains.XXXXXX)"
    awk -v row="$new_row" '
      BEGIN { in_table = 0; inserted = 0 }
      /^\|[[:space:]]*-+/ { in_table = 1; print; next }
      in_table == 1 && /^\|/ { last_table_line = NR; print; next }
      in_table == 1 && !/^\|/ && inserted == 0 {
        print row
        inserted = 1
        in_table = 0
        print
        next
      }
      { print }
      END { if (in_table == 1 && inserted == 0) print row }
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
  rule-set:  $REMOTE_RULESET (tag: $RULESET_TAG)
  snapshot:  ${snapshot_id:-(skipped)}
EOF

exit 0
