#!/usr/bin/env bash
# bin/raw-ssh.sh — escape hatch: open a raw interactive SSH to the router.
#
# This is the ONE script in bin/ that bypasses the structured-API contract.
# Per SKILL.md: agent MUST get explicit user confirmation before invoking this.
# Each invocation is journalled with the (user-supplied) reason; the SSH session
# itself is whatever the user types — not captured.
#
# Usage:
#   bin/raw-ssh.sh --router <alias> [--reason "<text>"] [--allow-mutations] [--password-auth]
#
# Exit codes:
#   0   ok (user exited shell cleanly)
#   2   router not found / SSH unreachable
#  13   reason contains a secret pattern — refuses to journal it
#  64   bad CLI args
#  other: forwards exit code from the ssh process

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

# Secret regex kept in sync with lib/memory-journal.sh. Defense-in-depth — the
# strict allowlist below catches most of these too, but we keep this as a
# second filter so additions to the secret regex propagate here.
_RAW_SSH_SECRET_RE='vless://|vless%3A%2F%2F|bot[0-9]+:[A-Za-z0-9_-]{20,}|"bot_token":|BOT_TOKEN=|TG_TOKEN=|-----BEGIN [A-Z]+ PRIVATE KEY-----'

# Strict allowlist + length cap + suspicious-shape rejection. Reason text is
# journalled, so we'd rather force a rephrase than risk leaking an identifier.
# Returns 0 if input is acceptable; prints reject reason to stderr and returns
# 1 otherwise. Used by both this script and (mirrored) backup-now.sh --label.
_reject_reason_or_label() {
  local what="$1" val="$2"
  local n=${#val}
  if [ "$n" -gt 200 ]; then
    echo "raw-ssh: --$what слишком длинный ($n симв., максимум 200)" >&2
    return 1
  fi
  # Reject control chars (\n, \t, \r, etc.). grep -E is per-line so we use
  # tr -d to detect them via byte-count diff.
  local stripped
  stripped="$(printf '%s' "$val" | LC_ALL=C tr -d '[:cntrl:]')"
  if [ "${#val}" != "${#stripped}" ]; then
    echo "raw-ssh: --$what содержит управляющие символы (linebreak, tab и т.п.) — переформулируй одной строкой" >&2
    return 1
  fi
  # Allowlist: letters, digits, space, and a small set of punctuation. No @ #
  # = % { } [ ], no slashes-as-URL (we reject :// separately), no backslash.
  # Quotes/apostrophes allowed for natural language.
  if printf '%s' "$val" | LC_ALL=C grep -qE "[^A-Za-z0-9 .,;:!?()\"'_/+-]"; then
    echo "raw-ssh: --$what содержит недопустимые символы (разрешено: буквы, цифры, пробел, .,;:!?()\"'_/+-)" >&2
    return 1
  fi
  # No URL-ish patterns.
  if printf '%s' "$val" | grep -qE '://'; then
    echo "raw-ssh: --$what содержит '://' (похоже на URL — не журналируется)" >&2
    return 1
  fi
  # Defense in depth: secret regex.
  if printf '%s' "$val" | grep -qE "$_RAW_SSH_SECRET_RE"; then
    echo "raw-ssh: --$what матчит секрет-подобный паттерн (vless://, token, PEM и т.п.)" >&2
    return 1
  fi
  # Runs of >=16 of [A-Za-z0-9+/=] — looks base64/hex (public keys, UUIDs
  # without dashes, long tokens).
  if printf '%s' "$val" | grep -qE '[A-Za-z0-9+/=]{16,}'; then
    echo "raw-ssh: --$what содержит длинную base64/hex-подобную последовательность (>=16 симв.) — переформулируй" >&2
    return 1
  fi
  # Hostname/URL piece: a dot followed by 2+ alphanums.
  if printf '%s' "$val" | grep -qE '\.[A-Za-z0-9]{2,}'; then
    echo "raw-ssh: --$what содержит фрагмент похожий на домен/URL ('.xxx') — переформулируй" >&2
    return 1
  fi
  return 0
}

usage() {
  cat >&2 <<'EOF'
Usage: bin/raw-ssh.sh --router <alias> [--reason "<text>"] [--allow-mutations] [--password-auth]

Escape hatch — открывает прямой интерактивный SSH к роутеру.
Каждый вызов журналируется (reason обязателен по-хорошему).

Options:
  --router <alias>      alias из memory/routers.yaml (обяз.)
  --reason "<text>"     причина открытия SSH (без секретов). Будет в journal.md.
  --allow-mutations     разрешить mutating-команды в сессии. По умолчанию: read-only баннер.
  --password-auth       для OEM/stock SSH без ключа: проверять TCP/22, пароль вводится интерактивно.

ВАЖНО: после выхода из сессии запусти:
  bin/doctor.sh --router <alias>   # пересобрать state.md из реального состояния роутера
EOF
  exit 64
}

router=""
reason=""
allow_mutations=0
password_auth=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --reason) reason="${2:-}"; shift 2 ;;
    --allow-mutations) allow_mutations=1; shift ;;
    --password-auth) password_auth=1; shift ;;
    -h|--help) usage ;;
    *) echo "raw-ssh: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "raw-ssh: --router обязателен" >&2; usage; }

# --- Validate reason: strict allowlist + no secrets ----------------------------
# Reason is journalled, so we apply an allowlist with shape-based rejection
# for anything that looks like an identifier/URL/key. If the user supplies
# something rejected, we print a clear message naming what's wrong.
if [ -n "$reason" ]; then
  if ! _reject_reason_or_label "reason" "$reason"; then
    echo "raw-ssh: перефразируй --reason без идентификаторов/URL/ключей и повтори." >&2
    exit 13
  fi
fi

# --- Resolve router + SSH alive ------------------------------------------------
resolve_router_config "$router"

if [ "$password_auth" = "1" ]; then
  if ! nc -z -w 5 "$ROUTER_HOST" 22 >/dev/null 2>&1; then
    echo "raw-ssh: TCP/22 недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST)." >&2
    exit 2
  fi
elif ! ssh_check_alive 5; then
  cat >&2 <<EOF
raw-ssh: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Сначала проверь связность: ping -c1 $ROUTER_HOST
EOF
  exit 2
fi

# --- Confirmation banner (visible BEFORE journal/ssh exec) ---------------------
mutations_label_ru="запрещены — read-only (best-effort)"
[ "$allow_mutations" = "1" ] && mutations_label_ru="разрешены"

cat >&2 <<EOF

──────────────────────────────────────────────────────────────────────
raw-ssh: открываю прямой SSH к '$ROUTER_ALIAS' ($ROUTER_USER@$ROUTER_HOST).
  Причина: ${reason:-(не указана)}
  Мутации: $mutations_label_ru

ЭТО ПОСЛЕДНЕЕ СРЕДСТВО. Каждая твоя команда не отслеживается скриптами,
рекомендуется потом запустить doctor.sh для актуализации memory.
──────────────────────────────────────────────────────────────────────

EOF

# --- Journal BEFORE opening session --------------------------------------------
# We record: timestamp, router alias, reason, mutations flag.
# We DO NOT record: anything that happens during the session.
journal_reason="${reason:-(not provided)}"
if ! memory_journal_append "$ROUTER_ALIAS" "raw_ssh_session_opened" \
       "reason=$journal_reason" \
       "mutations_allowed=$( [ "$allow_mutations" = "1" ] && echo true || echo false )" \
       "ssh_target=$(_ssh_target)"; then
  # If journal append fails because of secret-key, that's a hard refuse.
  echo "raw-ssh: не смог записать journal — отказываюсь открывать SSH" >&2
  exit 13
fi

# --- Open the session ----------------------------------------------------------
# Capture wall-clock duration around exec replacement. Since we want to journal
# the close event too, we cannot use exec — we fork ssh and wait.
start_epoch="$(date +%s)"

# Build the ssh argv. We intentionally do NOT use -o BatchMode=yes here (user
# may need password / passphrase prompt for the key). Allow PTY (-t) so the
# remote shell behaves interactively.
ssh_argv=( -tt )
if [ -n "$ROUTER_SSH_KEY" ] && [ -f "$ROUTER_SSH_KEY" ]; then
  ssh_argv+=( -i "$ROUTER_SSH_KEY" )
fi
ssh_argv+=( -o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=15" )
if [ "$password_auth" = "1" ]; then
  # Old OEM router firmware may only offer SHA-1 RSA host keys. Keep this
  # compatibility exception scoped to the explicit password-auth escape hatch.
  ssh_argv+=( -o "HostKeyAlgorithms=+ssh-rsa" )
fi

# Best-effort "read-only" hint: when --allow-mutations is NOT set, we just warn
# loudly. Busybox shell has no robust way to enforce ro $HOME, and trying to
# wrap the shell with rbash etc. tends to break interactive UX. So we honour
# the documented limitation: banner + journal note + trust the user.
if [ "$allow_mutations" != "1" ]; then
  cat >&2 <<EOF
raw-ssh: NB — read-only mode заявлен, но это рекомендация, не enforcement.
        Busybox не позволяет надёжно chroot'ить интерактивный шелл.
        Старайся не делать mutating-команды; если надо — выйди и перезапусти
        с --allow-mutations (журнал пометит сессию иначе).

EOF
fi

ssh_argv+=( "$(_ssh_target)" )

set +e
ssh "${ssh_argv[@]}"
ssh_exit=$?
set -e

end_epoch="$(date +%s)"
duration_s=$(( end_epoch - start_epoch ))

# --- Journal close event -------------------------------------------------------
memory_journal_append "$ROUTER_ALIAS" "raw_ssh_session_closed" \
  "duration_s=$duration_s" \
  "exit_code=$ssh_exit" || \
  echo "raw-ssh: WARN — не смог записать close-event в journal" >&2

# --- Post-session prompt -------------------------------------------------------
cat >&2 <<EOF

──────────────────────────────────────────────────────────────────────
raw-ssh: сессия закрыта (duration=${duration_s}s, exit=$ssh_exit).

Если ты что-то менял на роутере — обязательно пересобери memory:
  bin/doctor.sh --router $ROUTER_ALIAS
  bin/health.sh --router $ROUTER_ALIAS

Memory-файлы (domains.md / vpns.md / proxies.md) могли стать неактуальными.
──────────────────────────────────────────────────────────────────────
EOF

exit "$ssh_exit"
