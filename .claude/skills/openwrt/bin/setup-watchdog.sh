#!/usr/bin/env bash
# bin/setup-watchdog.sh — install /etc/router-watchdog.conf (TG creds),
# watchdog scripts and cron entries on the router.
#
# Secrets (TG_TOKEN, TG_CHAT_ID) must NEVER reach the agent's chat, journal or
# any tracked file. This script only knows a *path* to a conf file that the
# user has prepared locally. We SCP it as-is without parsing the values.
#
# Two-phase:
#   Phase 1 (no --conf-file): print the template + instructions and exit 64.
#   Phase 2 (--conf-file <path>): validate by regex only, scp to router,
#                                 install watchdog scripts + cron, shred local.
#
# Usage:
#   bin/setup-watchdog.sh --router <alias>
#   bin/setup-watchdog.sh --router <alias> --conf-file <local-path> [--keep-local] [--watchdogs dns,vpn-nodes]
#
# Exit codes:
#   0   ok
#   2   router not found / SSH unreachable
#  13   validation error (bad conf file format)
#  64   bad CLI args OR user action needed (prepare conf file and retry)

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

WATCHDOG_TPL_DIR="$SKILL_HOME/templates/watchdogs"

usage() {
  cat >&2 <<'EOF'
Usage:
  bin/setup-watchdog.sh --router <alias>
  bin/setup-watchdog.sh --router <alias> --conf-file <local-path> [--keep-local] [--watchdogs <names>]

Ставит на роутер:
  - /etc/router-watchdog.conf (с TG_TOKEN / TG_CHAT_ID, chmod 600)
  - /usr/bin/<watchdog>.sh скрипты
  - cron-задачи

Без --conf-file печатает шаблон файла и инструкции (фаза 1).
С --conf-file — валидирует локальный файл по regex и заливает на роутер (фаза 2).

Options:
  --router <alias>       alias из memory/routers.yaml (обяз.)
  --conf-file <path>     путь к локальному файлу с TG_TOKEN/TG_CHAT_ID
  --keep-local           не удалять локальный conf после успешной заливки
  --watchdogs <list>     comma-list watchdog'ов (без расширения). По умолчанию все из templates/watchdogs/*.tmpl
EOF
  exit 64
}

router=""
conf_file=""
keep_local=0
watchdogs_arg=""

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --conf-file) conf_file="${2:-}"; shift 2 ;;
    --keep-local) keep_local=1; shift ;;
    --watchdogs) watchdogs_arg="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "setup-watchdog: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "setup-watchdog: --router обязателен" >&2; usage; }

# --- helper: list available watchdog template names (no .sh.tmpl suffix) -------
list_available_watchdogs() {
  if [ ! -d "$WATCHDOG_TPL_DIR" ]; then
    return 0
  fi
  # shellcheck disable=SC2012
  ls "$WATCHDOG_TPL_DIR"/*.sh.tmpl 2>/dev/null | while read -r f; do
    b="$(basename "$f")"
    printf '%s\n' "${b%.sh.tmpl}"
  done
}

# Compute the list of watchdogs we'll install.
if [ -n "$watchdogs_arg" ]; then
  # Normalize: split on comma, trim whitespace.
  selected="$(printf '%s' "$watchdogs_arg" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
else
  selected="$(list_available_watchdogs)"
fi

if [ -z "$selected" ]; then
  echo "setup-watchdog: нет watchdog'ов для установки (проверь templates/watchdogs/*.sh.tmpl)" >&2
  exit 2
fi

# Verify each selected watchdog has a corresponding template.
missing=""
for name in $selected; do
  tpl="$WATCHDOG_TPL_DIR/$name.sh.tmpl"
  if [ ! -f "$tpl" ]; then
    missing="$missing $name"
  fi
done
if [ -n "$missing" ]; then
  echo "setup-watchdog: нет шаблонов для:$missing" >&2
  echo "Доступны: $(list_available_watchdogs | tr '\n' ' ')" >&2
  exit 64
fi

# =====================================================================
# PHASE 1 — no --conf-file: print template + instructions, exit 64.
# =====================================================================
if [ -z "$conf_file" ]; then
  secrets_dir="$HOME/.openwrt-skill/secrets"
  conf_path="$secrets_dir/${router}-watchdog.conf"

  cat >&2 <<EOF
setup-watchdog: для роутера '$router' нужен файл с Telegram-кредами.

Шаг 1. Создай папку для секретов (вне git):
  mkdir -p $secrets_dir
  chmod 700 $secrets_dir

Шаг 2. Положи в $conf_path следующее содержимое:

  TG_TOKEN="123456:ABC-DEF..."
  TG_CHAT_ID="-1001234567890"

Как получить значения:
  - TG_TOKEN — напиши боту @BotFather, команда /newbot, он отдаст токен вида
    "123456789:AAH...".
  - TG_CHAT_ID — два способа:
      (a) перешли любое своё сообщение боту @userinfobot — он покажет твой id;
      (b) после создания бота отправь ему любое сообщение, потом открой
          https://api.telegram.org/bot<TOKEN>/getUpdates и найди "chat":{"id":...}.
    Для группы id обычно отрицательный (начинается с -100...).

Шаг 3. Защити файл:
  chmod 600 $conf_path

Шаг 4. Запусти команду заново:
  bin/setup-watchdog.sh --router $router --conf-file $conf_path

ВАЖНО: не вставляй значения TG_TOKEN/TG_CHAT_ID в чат с агентом — он их не
запоминает и не должен видеть. Файл существует только локально у тебя, и после
успешной установки будет затёрт (shred) — это поведение можно отключить флагом
--keep-local.
EOF
  exit 64
fi

# =====================================================================
# PHASE 2 — --conf-file given: validate, ssh + scp, install, cleanup.
# =====================================================================

# Resolve router + check SSH.
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
setup-watchdog: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Сначала настрой SSH:
  bin/setup-ssh.sh --router $ROUTER_ALIAS --host $ROUTER_HOST
EOF
  exit 2
fi

# --- 2.1 Validate local conf file (presence-only checks, NO content echo) -----

if [ ! -f "$conf_file" ]; then
  echo "setup-watchdog: файл не найден: $conf_file" >&2
  exit 13
fi
if [ ! -r "$conf_file" ]; then
  echo "setup-watchdog: файл нечитаем: $conf_file" >&2
  exit 13
fi

# Check format: must contain TG_TOKEN= and TG_CHAT_ID= lines.
# Use grep -q so we never echo matched content.
if ! grep -qE '^TG_TOKEN=' "$conf_file"; then
  echo "setup-watchdog: в $conf_file нет строки 'TG_TOKEN=...'" >&2
  exit 13
fi
if ! grep -qE '^TG_CHAT_ID=' "$conf_file"; then
  echo "setup-watchdog: в $conf_file нет строки 'TG_CHAT_ID=...'" >&2
  exit 13
fi

# Mode check (warn only).
if command -v stat >/dev/null 2>&1; then
  if mode="$(stat -f '%Lp' "$conf_file" 2>/dev/null)"; then
    :
  else
    mode="$(stat -c '%a' "$conf_file" 2>/dev/null || echo "?")"
  fi
  if [ "$mode" != "600" ] && [ "$mode" != "400" ]; then
    echo "setup-watchdog: предупреждение — права на $conf_file = $mode (рекомендую 600). Продолжаю." >&2
  fi
fi

# --- 2.2 Stream conf file to router as /etc/router-watchdog.conf ---------------
# Use cat | ssh "umask 077 && cat > … && chmod 600 …" instead of scp+chmod.
# scp lands the file as 644 first, then chmod races to 600 — a brief window
# where the file is world-readable. umask 077 inside ssh makes the create
# mode 600 atomically (no readable-by-others window).

echo "setup-watchdog: заливаю /etc/router-watchdog.conf …" >&2
if ! cat "$conf_file" | ssh_run 'umask 077 && cat > /etc/router-watchdog.conf && chmod 600 /etc/router-watchdog.conf' >/dev/null; then
  echo "setup-watchdog: не смог записать /etc/router-watchdog.conf на роутер" >&2
  exit 2
fi

# --- 2.3 Install watchdog scripts under /usr/bin/<name>.sh --------------------

installed_names=""
for name in $selected; do
  tpl="$WATCHDOG_TPL_DIR/$name.sh.tmpl"
  remote="/usr/bin/$name.sh"
  echo "setup-watchdog: → $remote" >&2
  if ! scp_to "$tpl" "$remote" >/dev/null; then
    echo "setup-watchdog: scp $remote не удался" >&2
    exit 2
  fi
  if ! ssh_run "chmod +x $remote" >/dev/null; then
    echo "setup-watchdog: chmod +x $remote не удался" >&2
    exit 2
  fi
  installed_names="$installed_names $name"
done
# Trim leading space.
installed_names="${installed_names# }"

# --- 2.4 Install cron entries (idempotent) ------------------------------------

# Read existing crontab; if none, empty is fine.
existing_cron="$(ssh_run 'crontab -l 2>/dev/null || true')"

# Build desired lines.
desired_lines=""
for name in $installed_names; do
  line="* * * * * /usr/bin/$name.sh"
  desired_lines="${desired_lines}${line}"$'\n'
done

# Normalize whitespace before comparison so two cron lines differing only by
# the number of spaces between fields don't both get installed.
# awk '{$1=$1; print}' rebuilds each record using OFS=" " — collapses runs of
# whitespace to a single space and strips leading/trailing whitespace.
desired_normalized="$(printf '%s\n' "$desired_lines" | awk 'NF>0 {$1=$1; print}')"
existing_normalized="$(printf '%s\n' "$existing_cron" | awk 'NF>0 {$1=$1; print}')"

# Merge: keep existing lines as-is (preserve user formatting), append any
# missing desired lines (compared by normalized form).
new_cron="$existing_cron"
added=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if printf '%s\n' "$existing_normalized" | grep -Fxq "$line"; then
    continue
  fi
  if [ -n "$new_cron" ]; then
    new_cron="${new_cron}"$'\n'"${line}"
  else
    new_cron="${line}"
  fi
  added=$((added + 1))
done <<EOF
$desired_normalized
EOF

if [ "$added" -gt 0 ]; then
  echo "setup-watchdog: добавляю $added cron-строк" >&2
  # Push new crontab via stdin.
  if ! printf '%s\n' "$new_cron" | ssh_run 'crontab -' >/dev/null; then
    echo "setup-watchdog: crontab - не удался" >&2
    exit 2
  fi
  # OpenWRT also needs cron service running; restart to pick up file.
  ssh_run '/etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true' >/dev/null || true
else
  echo "setup-watchdog: все cron-строки уже на месте" >&2
fi

# --- 2.5 Cleanup local conf file ----------------------------------------------

if [ "$keep_local" = "1" ]; then
  echo "setup-watchdog: --keep-local — локальный conf $conf_file оставлен" >&2
else
  if command -v shred >/dev/null 2>&1; then
    shred -u "$conf_file" 2>/dev/null || rm -f "$conf_file"
  else
    # macOS rm -P overwrites once before unlink (best-effort secure delete).
    rm -P "$conf_file" 2>/dev/null || rm -f "$conf_file"
  fi
  echo "setup-watchdog: локальный $conf_file удалён" >&2
fi

# --- 2.6 Journal (NEVER pass TG_TOKEN/TG_CHAT_ID values) ----------------------

# Count cron lines that match our watchdogs (idempotent check).
cron_count="$(printf '%s\n' "$installed_names" | wc -w | tr -d ' ')"

# Comma-join installed names without spaces.
csv="$(printf '%s' "$installed_names" | tr ' ' ',')"

if ! memory_journal_append "$ROUTER_ALIAS" "watchdog_setup_completed" \
      "watchdogs=$csv" "cron_lines=$cron_count"; then
  echo "setup-watchdog: не смог записать journal (не критично)" >&2
fi

cat >&2 <<EOF

setup-watchdog: готово.
  router:           $ROUTER_ALIAS
  watchdogs:        $csv
  cron-строк:       $cron_count
  /etc/router-watchdog.conf: установлен, chmod 600

Следующий шаг — проверь, что doctor видит watchdog:
  bin/doctor.sh --router $ROUTER_ALIAS
EOF
exit 0
