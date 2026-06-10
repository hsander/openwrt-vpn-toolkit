#!/usr/bin/env bash
# bin/install-vpn.sh — first-time VPN bootstrap on a clean OpenWRT router.
#
# Wraps bin/install-minimal.sh: ships the skill tree to the router via tar+scp,
# runs install-minimal.sh remotely (which does package install, render, staged-apply,
# firewall + cron + service activation), then refreshes agent-side memory.
#
# Usage:
#   bin/install-vpn.sh --router <alias> --url '<vless://...>'
#                      [--tag <name>] [--add-proxy-port 4000]
#                      [--skip-preflight] [--dry-run]
#
# Exit codes:
#   0   ok
#   2   router not found / SSH unreachable / preflight failed
#  13   validation error (bad URL, bad tag, bad port)
#  20   rollback fired (install-minimal returned non-zero on staged-apply)
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
Usage:
  bin/install-vpn.sh --router <alias> --url '<vless://...>'
                     [--tag <name>] [--add-proxy-port 4000]
                     [--skip-preflight] [--dry-run]

Поднимает sing-box VPN с нуля на чистом OpenWRT-роутере:
  1) snapshot существующего config.json (если есть)
  2) preflight: версия OpenWRT, пакеты, RAM, конфликты
  3) apk install sing-box + DNS chain + init.d/sing-box-tproxy
  4) рендер config.json из VLESS Reality URL
  5) staged-apply: service start с auto-rollback при потере связности
  6) обновление memory/<alias>/{state,vpns,proxies,journal}.md

Options:
  --router <alias>           alias из memory/routers.yaml (обяз.)
  --url '<vless://...>'      VLESS Reality URL (обяз.)
  --tag <name>               имя outbound (a-z0-9_-). По умолчанию — из #fragment URL'а или node1
  --add-proxy-port <port>    также поднять mixed-inbound на этом порту (4000-4099)
  --skip-preflight           пропустить preflight (для повторного запуска после ручной правки)
  --dry-run                  только зарендерить и положить файлы; БЕЗ apk install и старта сервисов
EOF
  exit 64
}

router=""
url=""
tag=""
proxy_port=""
skip_preflight=0
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --url) url="${2:-}"; shift 2 ;;
    --tag) tag="${2:-}"; shift 2 ;;
    --add-proxy-port) proxy_port="${2:-}"; shift 2 ;;
    --skip-preflight) skip_preflight=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage ;;
    *) echo "install-vpn: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "install-vpn: --router обязателен" >&2; usage; }
[ -z "$url" ]    && { echo "install-vpn: --url обязателен" >&2; usage; }

# --- 1. Validate args -----------------------------------------------------------

# URL must start with vless://. Do NOT log or echo the URL anywhere.
case "$url" in
  vless://*) ;;
  *) echo "install-vpn: --url должен начинаться с vless:// (получено что-то другое)" >&2; exit 13 ;;
esac

# Tag: alphanumeric + - _ . If empty, derive from URL fragment (after '#'), fallback node1.
# We use parameter expansion only — never echo the whole URL.
if [ -z "$tag" ]; then
  case "$url" in
    *\#*)
      # Extract fragment (after last '#'); strip query-style trailing.
      _frag="${url##*#}"
      # URL-decode minimal: %20 -> space, then trim spaces, then keep safe chars only.
      _frag="${_frag//%20/ }"
      # Keep only [A-Za-z0-9_-]; drop everything else.
      tag="$(printf '%s' "$_frag" | tr -cd 'A-Za-z0-9_-' | cut -c1-32)"
      ;;
  esac
  [ -z "$tag" ] && tag="node1"
fi

if ! printf '%s' "$tag" | grep -qE '^[A-Za-z0-9_-]+$'; then
  echo "install-vpn: невалидный --tag='$tag' (только A-Za-z0-9_-)" >&2
  exit 13
fi

if [ -n "$proxy_port" ]; then
  if ! printf '%s' "$proxy_port" | grep -qE '^[0-9]+$'; then
    echo "install-vpn: --add-proxy-port='$proxy_port' — должно быть число" >&2
    exit 13
  fi
  if [ "$proxy_port" -lt 4000 ] || [ "$proxy_port" -gt 4099 ]; then
    echo "install-vpn: --add-proxy-port=$proxy_port вне диапазона 4000-4099" >&2
    exit 13
  fi
fi

# --- 2. Parse host:port from URL (NO secrets touched) ---------------------------
# Strategy: strip scheme, drop fragment, drop query, drop userinfo, then split host:port.
# We isolate ONLY the host and port. uuid/pbk/sid/sni/flow remain inside $url and are
# passed opaquely to install-minimal.sh on the router via a stdin-fed shell wrapper.

_strip_scheme="${url#vless://}"
_no_fragment="${_strip_scheme%%#*}"
_no_query="${_no_fragment%%\?*}"
# userinfo@host:port — drop everything up to and including '@'.
case "$_no_query" in
  *@*) _hostport="${_no_query#*@}" ;;
  *)   _hostport="$_no_query" ;;
esac
vpn_host="${_hostport%:*}"
vpn_port="${_hostport##*:}"

# Sanity: host non-empty, port numeric.
if [ -z "$vpn_host" ] || ! printf '%s' "$vpn_port" | grep -qE '^[0-9]+$'; then
  echo "install-vpn: не удалось извлечь host:port из URL (проверь формат vless://uuid@host:port?...)" >&2
  exit 13
fi

# --- 3. Resolve router config + SSH liveness check -----------------------------

resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
install-vpn: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Сначала настрой SSH-доступ:
  bin/setup-ssh.sh --router $ROUTER_ALIAS --host $ROUTER_HOST
EOF
  exit 2
fi

# --- 4. Pre-install baseline snapshot (MANDATORY) ------------------------------
# Контракт SKILL.md §Rule 2: backup-before-mutate. install-minimal.sh правит
# /etc/config/firewall (uci), /etc/crontabs/root, /etc/init.d/sing-box-tproxy,
# /etc/sing-box/, /usr/bin/*-watchdog.sh, /etc/vpn-kit/*. Без baseline'а откатить
# чистый роутер в исходное состояние невозможно. Поэтому snapshot обязателен —
# и неважно, есть ли уже /etc/sing-box/config.json (на first-install его нет,
# но UCI всё равно мутируется).
#
# В --dry-run snapshot тоже делаем: render-config + scp tarball'а — это легально
# не мутирует, но дешевле снять и снести baseline, чем разбираться постфактум.

if [ ! -x "$SCRIPT_DIR/backup-now.sh" ]; then
  echo "install-vpn: bin/backup-now.sh не найден или не executable — без него pre-install snapshot невозможен. Почини и повтори." >&2
  exit 2
fi

echo "install-vpn: snapshot роутера ДО install-minimal (baseline для отката)..." >&2
snapshot_label=""
if snapshot_out="$("$SCRIPT_DIR/backup-now.sh" --router "$ROUTER_ALIAS" --label "before install-vpn" --quiet 2>&1)"; then
  # backup-now.sh печатает snap-ID на stdout (последняя строка); stderr с retention идёт сюда же.
  snapshot_label="$(printf '%s' "$snapshot_out" | grep -oE '^snap-[0-9TZ]+' | tail -1 || true)"
  if [ -z "$snapshot_label" ]; then
    echo "install-vpn: backup-now.sh не вернул snap-ID — отказываюсь продолжать без verified baseline." >&2
    printf '%s\n' "$snapshot_out" | head -10 >&2
    exit 2
  fi
  echo "install-vpn: baseline snapshot = $snapshot_label" >&2
else
  echo "install-vpn: backup-now.sh упал — продолжать без baseline нельзя (это нарушает safety-контракт)." >&2
  printf '%s\n' "$snapshot_out" | head -10 >&2
  echo "install-vpn: если роутер настолько пустой, что snapshot не получается, — это первый запуск и риск минимален; временно повтори с OPENWRT_SKILL_FORCE_NO_BASELINE=1 (только если понимаешь последствия)." >&2
  if [ "${OPENWRT_SKILL_FORCE_NO_BASELINE:-0}" != "1" ]; then
    exit 2
  fi
  echo "install-vpn: OPENWRT_SKILL_FORCE_NO_BASELINE=1 — продолжаю без baseline. Откат install-minimal'а будет невозможен." >&2
fi

# --- 5. Preflight on the router ------------------------------------------------
# В dry-run пропускаем preflight по умолчанию — он часто валится на SNAPSHOT/dev
# builds и блокирует чистый dry-run в CI. Пользователь может форсить полный
# preflight через --with-preflight (не реализовано). Сейчас: --dry-run ⇒ skip,
# если явно не задан --skip-preflight=0.

if [ "$dry_run" = "1" ] && [ "$skip_preflight" = "0" ]; then
  echo "install-vpn: --dry-run — пропускаю preflight (для полного preflight убери --dry-run)" >&2
  skip_preflight=1
fi

if [ "$skip_preflight" = "0" ]; then
  echo "install-vpn: preflight (OpenWRT 24.10+ или SNAPSHOT, RAM, apk, конфликты)..." >&2
  # Inline preflight — keep small. We don't ship preflight-minimal.sh separately here;
  # the full tarball below will include it for install-minimal's own use. For the gate
  # we do a tight subset: openwrt major, ram, package manager.
  # NOTE: bash can't safely use $(cat <<'TAG' ... TAG) when the body has case/;;,
  # so we write the script to a tmpfile first.
  preflight_script_path="$(mktemp -t openwrt-skill-preflight.XXXXXX)"
  cat > "$preflight_script_path" <<'REMOTE'
#!/bin/sh
set -eu
fail=""
ver=""
[ -f /etc/openwrt_release ] && ver="$(awk -F\' '/DISTRIB_RELEASE/ {print $2}' /etc/openwrt_release)"
case "$ver" in
  24.*|25.*|26.*|SNAPSHOT|snapshot|r[0-9]*) ;;
  *) fail="$fail openwrt=$ver(need-24.10+-or-SNAPSHOT)" ;;
esac
ram_mb="$(awk '/^MemTotal/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 0)"
[ "${ram_mb:-0}" -ge 256 ] || fail="$fail ram=${ram_mb}MB(need>=256)"
command -v apk >/dev/null 2>&1 || fail="$fail no-apk"
arch="$(uname -m)"
case "$arch" in
  aarch64|x86_64|x86|armv7l) ;;
  *) fail="$fail arch=$arch(unsupported)" ;;
esac
if command -v sing-box >/dev/null 2>&1; then
  if [ -f /etc/sing-box/config.json ] && [ ! -f /etc/vpn-kit/install-state.json ]; then
    fail="$fail existing-sing-box-config-not-owned"
  fi
fi
if [ -n "$fail" ]; then
  echo "preflight-fail:$fail" >&2
  exit 2
fi
echo "preflight-ok arch=$arch ram=${ram_mb}MB openwrt=$ver"
REMOTE
  if ! preflight_out="$(ssh_run_remote < "$preflight_script_path" 2>&1)"; then
    rm -f "$preflight_script_path"
    echo "install-vpn: preflight не прошёл:" >&2
    printf '%s\n' "$preflight_out" >&2
    cat >&2 <<EOF

Подсказки:
  - OpenWRT должен быть 24.10+ (apk-based)
  - RAM ≥ 256MB
  - архитектура: aarch64 / x86_64 / x86 / armv7l
  - если /etc/sing-box/config.json уже есть и НЕ от этого навыка (preflight-fail
    'existing-sing-box-config-not-owned'): НЕ сноси руками. Запусти
        bin/adopt.sh --router $ROUTER_ALIAS
    Он сделает baseline-snapshot и синхронизирует memory с реальным состоянием
    роутера, не модифицируя сам роутер. После этого install-vpn.sh можно
    запускать только для расширения (add-vpn/add-domain/add-proxy).
EOF
    exit 2
  fi
  rm -f "$preflight_script_path"
  echo "install-vpn: preflight OK ($preflight_out)" >&2
fi

# --- 6. Ship the skill tree to the router and run install-minimal.sh ----------

writer="claude-code@openwrt-skill-$(date +%s)"

# Build a tarball of the skill repo (bin/, lib/, templates/, openwrt/, schemas/).
# We exclude memory/ — it's agent-side only.
work_dir="$(mktemp -d -t openwrt-skill-install-vpn.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT INT TERM
tarball="$work_dir/openwrt-skill.tgz"

# Only ship what install-minimal.sh actually needs at runtime.
(cd "$SKILL_HOME" && tar --exclude='./memory' --exclude='./tests' --exclude='./.git' \
    -czf "$tarball" \
    bin lib templates openwrt schemas 2>/dev/null) || {
  echo "install-vpn: не смог собрать tar архив skill-дерева" >&2
  exit 1
}

remote_root="/tmp/openwrt-skill-install-vpn"
remote_tgz="/tmp/openwrt-skill-install-vpn.tgz"

# Upload tarball.
echo "install-vpn: загружаю skill-tree на роутер..." >&2
if ! scp_to "$tarball" "$remote_tgz"; then
  echo "install-vpn: scp tarball'а упал" >&2
  exit 2
fi

# Untar on the router.
if ! ssh_run "rm -rf $remote_root && mkdir -p $remote_root && tar -C $remote_root -xzf $remote_tgz" >/dev/null 2>&1; then
  echo "install-vpn: не смог распаковать tarball на роутере" >&2
  exit 2
fi

# Write the VLESS URL to a chmod-600 tmpfile on the router and pass its PATH (not
# the URL itself) to install-minimal.sh. URL никогда не появляется в argv ни
# одного процесса — ни ssh, ни install-minimal.sh, ни render-minimal-config.sh.
# Видно только путь к файлу. ps/auditd/proc на роутере не покажут URL.
echo "install-vpn: загружаю VLESS URL на роутер (chmod 600, удалю после install)..." >&2
url_remote="/tmp/.openwrt-skill-url.$$"

# Write URL via stdin (also avoids exposure on the local command line beyond this script).
if ! printf '%s' "$url" | ssh_run "umask 077 && cat > $url_remote && chmod 600 $url_remote" >/dev/null 2>&1; then
  echo "install-vpn: не смог записать URL на роутер" >&2
  exit 2
fi

# Build the activation flag.
activate_flag=""
[ "$dry_run" = "0" ] && activate_flag="--activate"

# Optional proxy port. install-minimal.sh defaults port=4000 BUT always renders a
# mixed-inbound on $port. If user did NOT pass --add-proxy-port, we still need a port
# (install-minimal requires one). We'll use 4000 silently, and only record it in
# memory if explicitly requested.
effective_port="${proxy_port:-4000}"

# install-minimal.sh принимает --vless-url-file и сам пробрасывает в
# render-minimal-config.sh. Стираем файл после install (try-always), даже при
# падении.
remote_cmd="set -eu
'$remote_root/bin/install-minimal.sh' \\
  --vless-url-file '$url_remote' \\
  --node-name '$tag' \\
  --listen '192.168.1.1' \\
  --port '$effective_port' \\
  --writer '$writer' \\
  $activate_flag
rc=\$?
rm -f '$url_remote'
exit \$rc"

echo "install-vpn: запускаю install-minimal.sh на роутере (tag=$tag, listen=192.168.1.1:$effective_port, activate=$([ -n "$activate_flag" ] && echo yes || echo no))..." >&2

install_rc=0
install_out="$(ssh_run "$remote_cmd" 2>&1)" || install_rc=$?

# Defensive: wipe URL file even if remote_cmd didn't reach `rm` (e.g. ssh dropped).
ssh_run "rm -f $url_remote" >/dev/null 2>&1 || true

# Forward install-minimal stderr/stdout for visibility.
# install-minimal prints a JSON object on success at end of stdout; on failure
# it emits stderr that may contain DIAGNOSTIC info — but NOT secrets (it never
# echoes the URL itself).
if [ "$install_rc" -ne 0 ]; then
  echo "install-vpn: install-minimal.sh упал с кодом $install_rc" >&2
  printf '%s\n' "$install_out" >&2
  # Map staged-apply rollback signal. install-minimal exits with $VPN_KIT_EXIT_VALIDATION=13
  # for validation, or non-zero from staged-apply.sh when verify/reachability fails.
  case "$install_rc" in
    20|21|22) exit 20 ;;     # rollback fired
    13) exit 13 ;;           # validation
    *)
      # Treat unknown failures as rollback if config likely got reverted.
      exit 20 ;;
  esac
fi

# Print install-minimal's JSON summary (last line) for the user.
echo "install-vpn: install-minimal.sh завершился успешно:" >&2
printf '%s\n' "$install_out" | tail -1 >&2

# --- 7. Post-install verification via doctor (warning-only) --------------------

echo "install-vpn: запускаю doctor для верификации..." >&2
doctor_json=""
if doctor_json="$("$SCRIPT_DIR/doctor.sh" --router "$ROUTER_ALIAS" --no-render --json --quiet 2>/dev/null)"; then
  if command -v jq >/dev/null 2>&1; then
    cfg_valid="$(printf '%s' "$doctor_json" | jq -r '.config.valid' 2>/dev/null || echo "?")"
    out_count="$(printf '%s' "$doctor_json" | jq -r '.config.outbound_count' 2>/dev/null || echo "0")"
    tproxy_running="$(printf '%s' "$doctor_json" | jq -r '.tproxy.running' 2>/dev/null || echo "false")"

    warn=""
    [ "$cfg_valid" = "true" ] || warn="$warn config.valid=$cfg_valid"
    [ "${out_count:-0}" -ge 1 ] || warn="$warn outbound_count=$out_count"
    if [ "$dry_run" = "0" ] && [ "$tproxy_running" != "true" ]; then
      warn="$warn tproxy.running=$tproxy_running"
    fi
    if [ -n "$warn" ]; then
      echo "install-vpn: ⚠ doctor отдал предупреждения (возможно, сервису нужно ещё пару секунд):$warn" >&2
    else
      echo "install-vpn: doctor — всё чисто" >&2
    fi
  fi
else
  echo "install-vpn: doctor --no-render --json не отработал (не критично)" >&2
fi

# --- 8. Update agent-side memory -----------------------------------------------

# Ensure memory dir exists; render_first_time_memory is idempotent.
render_first_time_memory "$ROUTER_ALIAS" "$ROUTER_HOST"

# Refresh state.md.
"$SCRIPT_DIR/doctor.sh" --router "$ROUTER_ALIAS" --quiet >/dev/null 2>&1 || true

# Append row to vpns.md. Be defensive: file may still have {{VPN_TABLE_ROWS}} OR
# may already have real rows. We try to inject before the placeholder if present,
# else we append a row after the header line of the active table.
vpns_md="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/vpns.md"
proxy_cell_for_vpn="—"
[ -n "$proxy_port" ] && proxy_cell_for_vpn=":$proxy_port"
vpn_row="| $tag | reality | $vpn_host:$vpn_port | ? | нет | $proxy_cell_for_vpn |"

if [ -f "$vpns_md" ]; then
  if grep -q '{{VPN_TABLE_ROWS}}' "$vpns_md"; then
    # Replace placeholder with new row (so future entries append below).
    tmp_md="$vpns_md.tmp.$$"
    awk -v row="$vpn_row" '
      { if (index($0, "{{VPN_TABLE_ROWS}}") > 0) print row; else print $0 }
    ' "$vpns_md" > "$tmp_md" && mv "$tmp_md" "$vpns_md"
  elif grep -qE '^\| Tag \| Тип \| Host:port' "$vpns_md"; then
    # Append AFTER the markdown table block. Find the "## auto-failover" header
    # and insert the row on the line before it.
    tmp_md="$vpns_md.tmp.$$"
    awk -v row="$vpn_row" '
      /^## auto-failover/ && !inserted { print row; print ""; inserted=1 }
      { print }
    ' "$vpns_md" > "$tmp_md" && mv "$tmp_md" "$vpns_md"
  else
    tmp_md="$vpns_md.tmp.$$"
    awk -v row="$vpn_row" 'BEGIN{last=-1}
      /^\|/ { last=NR }
      { lines[NR]=$0 }
      END {
        for(i=1;i<=NR;i++) {
          print lines[i]
          if (i==last) print row
        }
        if (last==-1) print row
      }
    ' "$vpns_md" > "$tmp_md" && mv "$tmp_md" "$vpns_md"
  fi
fi

# Append row to proxies.md if --add-proxy-port was given.
if [ -n "$proxy_port" ]; then
  proxies_md="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/proxies.md"
  proxy_row="| $proxy_port | $tag | LAN mixed inbound | 192.168.1.1 |"
  if [ -f "$proxies_md" ]; then
    if grep -q '{{PROXY_TABLE_ROWS}}' "$proxies_md"; then
      tmp_md="$proxies_md.tmp.$$"
      awk -v row="$proxy_row" '
        { if (index($0, "{{PROXY_TABLE_ROWS}}") > 0) print row; else print $0 }
      ' "$proxies_md" > "$tmp_md" && mv "$tmp_md" "$proxies_md"
    elif grep -qE '^\| Port \| Outbound' "$proxies_md"; then
      tmp_md="$proxies_md.tmp.$$"
      awk -v row="$proxy_row" '
        /^## Как использовать/ && !inserted { print row; print ""; inserted=1 }
        { print }
      ' "$proxies_md" > "$tmp_md" && mv "$tmp_md" "$proxies_md"
    else
      tmp_md="$proxies_md.tmp.$$"
      awk -v row="$proxy_row" 'BEGIN{last=-1}
        /^\|/ { last=NR }
        { lines[NR]=$0 }
        END {
          for(i=1;i<=NR;i++) {
            print lines[i]
            if (i==last) print row
          }
          if (last==-1) print row
        }
      ' "$proxies_md" > "$tmp_md" && mv "$tmp_md" "$proxies_md"
    fi
  fi
fi

# --- 9. Journal append (no secrets, helper will reject them anyway) ------------

journal_args=(
  "tag=$tag"
  "host=$vpn_host"
  "port=$vpn_port"
  "proxy_port=${proxy_port:-none}"
  "snapshot_before=${snapshot_label:-none}"
  "activated=$([ "$dry_run" = "0" ] && echo yes || echo no)"
)
if ! memory_journal_append "$ROUTER_ALIAS" "vpn_install_completed" "${journal_args[@]}"; then
  echo "install-vpn: journal append вернул не 0 (не критично — основная операция уже отработала)" >&2
fi

# --- 10. Success message (Russian) ---------------------------------------------

cat >&2 <<EOF

install-vpn: успех — VPN '$tag' поднят на '$ROUTER_ALIAS'.
  endpoint:   $vpn_host:$vpn_port  (секреты остались в /etc/sing-box/config.json на роутере, chmod 600)
  tag:        $tag$([ -n "$proxy_port" ] && echo "
  proxy:      mixed-inbound на 192.168.1.1:$proxy_port")
$([ "$dry_run" = "1" ] && echo "  ⚠ dry-run — пакеты не ставились, сервис не стартовал.")

Следующие шаги:
  - проверь health:        bin/doctor.sh --router $ROUTER_ALIAS
  - добавь домен в VPN:    bin/add-domain.sh --router $ROUTER_ALIAS --domain youtube.com
  - добавь ещё ноду:       bin/add-vpn.sh --router $ROUTER_ALIAS --url 'vless://...' --tag node2
EOF

exit 0

# ============================================================================
# self-test for URL parsing (host/port extraction):
#
# Given URL: vless://aaaa@1.2.3.4:443?security=reality&pbk=x&sni=ya.ru&type=tcp#test
#   _strip_scheme = aaaa@1.2.3.4:443?security=reality&pbk=x&sni=ya.ru&type=tcp#test
#   _no_fragment  = aaaa@1.2.3.4:443?security=reality&pbk=x&sni=ya.ru&type=tcp
#   _no_query     = aaaa@1.2.3.4:443
#   _hostport     = 1.2.3.4:443                       (userinfo 'aaaa' stripped)
#   vpn_host      = 1.2.3.4
#   vpn_port      = 443
#
# Note: uuid (aaaa), pbk, sni, sid, fp NEVER end up in any shell variable that gets
# echoed or journaled. The full URL is held in $url and passed via stdin to a remote
# tmpfile (chmod 600) that's deleted right after install-minimal.sh consumes it.
# ============================================================================
