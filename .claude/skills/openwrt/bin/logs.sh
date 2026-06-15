#!/usr/bin/env bash
# bin/logs.sh — tail logs from the router for sing-box / watchdog / zapret.
#
# Usage:
#   bin/logs.sh --router <alias> [--source sing-box|watchdog|zapret|all] [--lines 100] [--follow]
#
# Exit codes:
#   0   ok
#   1   generic error
#   2   router not found / SSH unreachable
#  13   bad --source value
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

# Secret-stripping regex. Used on the LOCAL stream after pulling logs from the
# router. Patterns (all replaced by [REDACTED]):
#   - vless:// URLs up to the next whitespace
#   - bot<digits>:<base64ish> Telegram bot tokens (>=20 chars after colon)
#   - "bot_token": "..." JSON values
#   - BOT_TOKEN=... env-style
#   - TG_TOKEN=... env-style
#   - PEM private key blocks (full block if it leaks on one line)
#   - URLs with userinfo: scheme://user:pass@host (catches assorted creds)
_LOGS_SECRET_RE='(vless://[^[:space:]]+|bot[0-9]+:[A-Za-z0-9_-]{20,}|"bot_token":[[:space:]]*"[^"]*"|BOT_TOKEN=[^[:space:]]+|TG_TOKEN=[^[:space:]]+|-----BEGIN [A-Z]+ PRIVATE KEY-----[^-]*-----END [A-Z]+ PRIVATE KEY-----|[a-z][a-z0-9+.-]*://[^[:space:]/@]+:[^[:space:]/@]+@[^[:space:]]+)'

usage() {
  cat >&2 <<'EOF'
Usage: bin/logs.sh --router <alias> [--source sing-box|watchdog|zapret|all] [--lines N] [--follow]

Тянет логи с роутера (read-only, journal не пишется).
Секреты (vless://..., токены) удаляются на локальной стороне до вывода.

Options:
  --router <alias>   alias из memory/routers.yaml (обяз.)
  --source <name>    sing-box | watchdog | zapret | all (по умолчанию: all)
  --lines N          сколько последних строк (по умолчанию: 100)
  --follow           следить (logread -f). Ctrl-C для остановки.

ВАЖНО: --follow не работает с --source all (логически: несколько потоков).
EOF
  exit 64
}

router=""
source_name="all"
lines=100
follow=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --source) source_name="${2:-}"; shift 2 ;;
    --lines) lines="${2:-}"; shift 2 ;;
    --follow) follow=1; shift ;;
    -h|--help) usage ;;
    *) echo "logs: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "logs: --router обязателен" >&2; usage; }

case "$source_name" in
  sing-box|singbox|sb) source_name="sing-box" ;;
  watchdog|wd) source_name="watchdog" ;;
  zapret|zapret2|zp) source_name="zapret" ;;
  all) source_name="all" ;;
  *) echo "logs: невалидный --source '$source_name' (sing-box|watchdog|zapret|all)" >&2; exit 13 ;;
esac

case "$lines" in
  ''|*[!0-9]*) echo "logs: --lines должно быть число" >&2; exit 13 ;;
esac
[ "$lines" -lt 1 ] && lines=1
[ "$lines" -gt 5000 ] && lines=5000

if [ "$follow" = "1" ] && [ "$source_name" = "all" ]; then
  echo "logs: --follow несовместим с --source all. Укажи конкретный --source." >&2
  exit 13
fi

# --- Resolve router + SSH alive ------------------------------------------------
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
logs: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
EOF
  exit 2
fi

# --- Local secret-strip filter (sed) -------------------------------------------
# We use a function to keep the call sites tidy. Bash regex constants are fine
# inside sed -E with single-quoted bracket-expansions.
sanitize_stream() {
  # Read stdin → write sanitized to stdout.
  # Delimiter is '#' (not '|') because the regex itself contains '|' for
  # alternation; BSD sed (macOS) doesn't tolerate '|' inside () with '|' as
  # the s-command delimiter.
  sed -E "s#$_LOGS_SECRET_RE#[REDACTED]#g"
}

# --- Compose remote command per source -----------------------------------------
remote_cmd_for() {
  local src="$1" n="$2" f="$3"
  case "$src" in
    sing-box)
      if [ "$f" = "1" ]; then
        printf '%s' "logread -f -e sing-box 2>/dev/null"
      else
        printf '%s' "logread -e sing-box 2>/dev/null | tail -$n"
      fi
      ;;
    watchdog)
      if [ "$f" = "1" ]; then
        printf '%s' "logread -f -e watchdog 2>/dev/null"
      else
        # Multi-part: state files in /tmp + logread.
        printf '%s' "
set +e
echo '=== /tmp/*.state ==='
for st in /tmp/*.state; do
  [ -f \"\$st\" ] && { echo \"--- \$st ---\"; cat \"\$st\"; }
done
echo
echo '=== logread -e watchdog (tail -$n) ==='
logread -e watchdog 2>/dev/null | tail -$n
"
      fi
      ;;
    zapret)
      # Match both "zapret2" daemon lines and the init's "zapret:" notices.
      if [ "$f" = "1" ]; then
        printf '%s' "logread -f -e zapret 2>/dev/null"
      else
        printf '%s' "logread -e zapret 2>/dev/null | tail -$n"
      fi
      ;;
  esac
}

# --- Run ----------------------------------------------------------------------
if [ "$source_name" = "all" ]; then
  # all: emit three sections, sanitized.
  {
    echo "########## sing-box ##########"
    ssh_run "$(remote_cmd_for sing-box "$lines" 0)" 2>/dev/null || true
    echo
    echo "########## watchdog ##########"
    ssh_run "$(remote_cmd_for watchdog "$lines" 0)" 2>/dev/null || true
    echo
    echo "########## zapret2 ##########"
    ssh_run "$(remote_cmd_for zapret "$lines" 0)" 2>/dev/null || true
  } | sanitize_stream
  exit 0
fi

# Single source.
if [ "$follow" = "1" ]; then
  cat >&2 <<EOF
logs: follow mode, source=$source_name. Ctrl-C для остановки.
      Secrets фильтруются локально через sed.

EOF
  # Stream stdout from SSH through sanitize. ssh exit code propagates.
  set +e
  ssh_run "$(remote_cmd_for "$source_name" "$lines" 1)" 2>/dev/null | sanitize_stream
  exit_code=$?
  set -e
  # Common: Ctrl-C kills ssh with 130 (or 255 if pipe broken). Treat as ok.
  case "$exit_code" in
    0|130|141|255) exit 0 ;;
    *) exit "$exit_code" ;;
  esac
fi

ssh_run "$(remote_cmd_for "$source_name" "$lines" 0)" 2>/dev/null | sanitize_stream
exit 0
