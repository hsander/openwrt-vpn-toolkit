#!/usr/bin/env bash
# bin/backup-now.sh — create a tar.gz snapshot of key router files BEFORE any
# mutating operation. Idempotent in the sense that running it twice creates two
# distinct snapshots (ID is timestamp-based).
#
# Behaviour:
#   1. Resolve router config and check SSH alive.
#   2. Build a snapshot tar.gz on the router from a fixed set of paths
#      (only those that exist — --ignore-failed-read).
#   3. Write a sidecar <id>.meta.json with sha256, created-at, label, paths.
#   4. Update memory/<alias>/journal.md with `snapshot_created`.
#   5. Apply retention: keep last 10 OR all within 30 days (whichever is larger).
#      Skip retention via --no-prune.
#   6. Print snapshot ID to stdout for capture by callers.
#
# Usage:
#   bin/backup-now.sh --router <alias> [--label <text>] [--quiet] [--no-prune]
#
# Exit codes:
#   0   ok
#   2   router not found / SSH unreachable
#  13   validation error (label contains secrets)
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

# Secret regex kept in sync with lib/memory-journal.sh and lib/vpn-kit-common.sh.
_SECRET_RE='vless://|vless%3A%2F%2F|bot[0-9]+:[A-Za-z0-9_-]{20,}|"bot_token":|BOT_TOKEN=|TG_TOKEN=|-----BEGIN [A-Z]+ PRIVATE KEY-----'

# Mirror of raw-ssh.sh's _reject_reason_or_label, applied to --label.
# We deliberately reject control chars (\n, \t, \r, etc.) because they would
# also break the JSON sidecar we write later.
_reject_label() {
  local val="$1"
  local n=${#val}
  if [ "$n" -gt 200 ]; then
    echo "backup-now: --label слишком длинный ($n симв., максимум 200)" >&2
    return 1
  fi
  # Reject control chars (incl. \n, \t, \r) and unsafe JSON chars ("\, \\).
  # NB: grep -E '[[:cntrl:]]' won't match \n because grep operates per-line —
  # the newline is the record separator, not data. Use tr -d to count bytes
  # before vs after stripping control chars; any drop means \n/\t/\r/etc.
  stripped="$(printf '%s' "$val" | LC_ALL=C tr -d '[:cntrl:]')"
  if [ "${#val}" != "${#stripped}" ]; then
    echo "backup-now: --label содержит управляющие символы (linebreak, tab и т.п.) — они портят JSON-сайдкар. Перефразируй." >&2
    return 1
  fi
  if printf '%s' "$val" | LC_ALL=C grep -qE '["\\]'; then
    echo "backup-now: --label содержит кавычку или обратный слэш — они портят JSON-сайдкар. Перефразируй." >&2
    return 1
  fi
  # Allowlist (same set as raw-ssh.sh --reason).
  if printf '%s' "$val" | LC_ALL=C grep -qE "[^A-Za-z0-9 .,;:!?()'_/+-]"; then
    echo "backup-now: --label содержит недопустимые символы (разрешено: буквы, цифры, пробел, .,;:!?()'_/+-)" >&2
    return 1
  fi
  if printf '%s' "$val" | grep -qE '://'; then
    echo "backup-now: --label содержит '://' (похоже на URL — переформулируй)" >&2
    return 1
  fi
  if printf '%s' "$val" | grep -qE "$_SECRET_RE"; then
    echo "backup-now: --label матчит секрет-подобный паттерн (vless://, token, PEM и т.п.)" >&2
    return 1
  fi
  # NB: ранее тут были проверки на base64/hex run и `.domain` фрагмент. Они
  # отвергали легитимные label'ы от внутренних callers:
  #   - "before add-domain youtube.com" — '.com' триггерил domain-fragment;
  #   - "safety before restore snap-20260511T153659Z" — 16-char alnum run.
  # Эти проверки имели смысл для raw-ssh --reason (свободный ввод агента),
  # но не для label'ов snapshot'ов, которые скрипты строят детерминистически.
  # Здесь оставлены только реальные защиты: control chars, JSON-портящие
  # символы, '://', secret regex.
  return 0
}

usage() {
  cat >&2 <<'EOF'
Usage: bin/backup-now.sh --router <alias> [--label <text>] [--quiet] [--no-prune]

Снимает tar.gz-snapshot ключевых файлов роутера (sing-box, init.d, /etc/config,
nftables, watchdogs, install-state) в /etc/vpn-kit/snapshots/ на роутере.

Options:
  --router <alias>   alias из memory/routers.yaml (обязателен)
  --label <text>     произвольная метка (без секретов). По умолчанию пусто.
  --quiet            не печатать summary в stderr
  --no-prune         не удалять старые снимки

stdout: ID нового снимка (snap-YYYYMMDDTHHMMSSZ)
EOF
  exit 64
}

router=""
label=""
quiet=0
no_prune=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --label)  label="${2:-}"; shift 2 ;;
    --quiet)  quiet=1; shift ;;
    --no-prune) no_prune=1; shift ;;
    -h|--help) usage ;;
    *) echo "backup-now: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "backup-now: --router обязателен" >&2; usage; }

# --- Validate label: strict allowlist + secret-free ----------------------------
# Label is journalled and embedded in the meta JSON sidecar, so we reject
# control chars (linebreaks etc.), URL-ish fragments, base64/hex runs, dots
# followed by alphanums. The exact same rules apply to raw-ssh.sh --reason.
if [ -n "$label" ]; then
  if ! _reject_label "$label"; then
    echo "backup-now: перефразируй --label без идентификаторов/URL/ключей/контрол-символов и повтори." >&2
    exit 13
  fi
fi

# --- Resolve router + SSH alive ------------------------------------------------
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
backup-now: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Проверь связь: ping -c1 $ROUTER_HOST
Или прогон: bin/setup-ssh.sh --router $ROUTER_ALIAS
EOF
  exit 2
fi

# Ensure memory dir exists so journal works later.
render_first_time_memory "$ROUTER_ALIAS" "$ROUTER_HOST"

# --- Build snapshot ID and run remote tar in a single ssh round-trip -----------
snap_id="snap-$(date -u +%Y%m%dT%H%M%SZ)"
SNAP_DIR_REMOTE="/etc/vpn-kit/snapshots"
tar_path="$SNAP_DIR_REMOTE/${snap_id}.tar.gz"
meta_path="$SNAP_DIR_REMOTE/${snap_id}.meta.json"

# Paths to snapshot. Only those that exist on the router are included (tar with
# --ignore-failed-read). NOTE: /etc/router-watchdog.conf contains TG_TOKEN —
# router-local snapshot is acceptable; we keep 700/600 perms below.
read -r -d '' SNAP_REMOTE_SCRIPT <<'REMOTE_SH' || true
set -eu

SNAP_DIR="$1"
SNAP_ID="$2"
LABEL="$3"

TAR="$SNAP_DIR/${SNAP_ID}.tar.gz"
META="$SNAP_DIR/${SNAP_ID}.meta.json"

mkdir -p "$SNAP_DIR"
chmod 700 "$SNAP_DIR" 2>/dev/null || true

# Paths to capture; keep absolute. `tar --ignore-failed-read` skips missing
# entries. We expand the globs via a tmp file-list so missing globs don't break.
LIST="$(mktemp /tmp/openwrt-skill-snap-list.XXXXXX)"
trap 'rm -f "$LIST"' EXIT INT TERM

for p in \
  /etc/sing-box \
  /etc/init.d/sing-box-tproxy \
  /etc/init.d/zapret2 \
  /opt/zapret2/config \
  /opt/zapret2/ipset/zapret-hosts-user.txt \
  /opt/zapret2/ipset/zapret-ip-user-exclude.txt \
  /etc/config/firewall \
  /etc/config/network \
  /etc/config/dhcp \
  /etc/config/https-dns-proxy \
  /etc/nftables.d \
  /etc/crontabs/root \
  /etc/dnsmasq.conf \
  /etc/router-watchdog.conf \
  /etc/vpn-kit/install-state.json \
  /etc/vpn-kit/firewall \
  /etc/vpn-kit/cron \
  /etc/vpn-kit/dnsmasq-additions.conf \
  /etc/vpn-kit/activation
do
  if [ -e "$p" ]; then
    printf '%s\n' "$p" >> "$LIST"
  fi
done

# Glob for watchdog scripts (may be empty).
for f in /usr/bin/*-watchdog.sh; do
  [ -e "$f" ] && printf '%s\n' "$f" >> "$LIST"
done

# Refuse to build an empty archive — that would look "successful" but
# restoring it would silently do nothing. Exit 2 is the "router not ready"
# signal; pre-install routers legitimately have nothing to snapshot.
if [ ! -s "$LIST" ]; then
  echo "snap_err=no_paths" >&2
  echo "no_paths_to_snapshot=1"
  exit 2
fi

# Build the tar from the file-list. -P keeps absolute paths (busybox tar OK).
# Use --ignore-failed-read for defensive bracketing.
tar -czf "$TAR" --ignore-failed-read -T "$LIST" 2>/dev/null || \
  tar -czf "$TAR" -T "$LIST"

chmod 600 "$TAR"

# sha256 (busybox-compatible).
if command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "$TAR" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  SHA="$(shasum -a 256 "$TAR" | awk '{print $1}')"
else
  SHA=""
fi

ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HN="$(uname -n 2>/dev/null || echo unknown)"

# Capture the list of paths actually inside the tar (for the meta file).
PATHS_JSON="$(awk '{
  gsub(/\\/, "\\\\"); gsub(/"/, "\\\"");
  printf "%s\"%s\"", (NR>1 ? "," : ""), $0
}' "$LIST")"

# Build meta json. We avoid jq here (busybox may not have it on router);
# fields are well-scoped so manual JSON is safe.
# Escape label for JSON (basic: backslash, double-quote).
LABEL_ESC="$(printf '%s' "$LABEL" | sed 's/\\/\\\\/g; s/"/\\"/g')"

cat > "$META" <<META_EOF
{
  "id": "${SNAP_ID}",
  "created": "${ISO}",
  "label": "${LABEL_ESC}",
  "host_hostname": "${HN}",
  "sha256": "${SHA}",
  "paths": [${PATHS_JSON}]
}
META_EOF
chmod 600 "$META"

# Print summary to stdout — caller parses last line for size.
SIZE_BYTES="$(wc -c < "$TAR" 2>/dev/null | tr -d ' ')"
printf 'snap_id=%s\n' "$SNAP_ID"
printf 'tar=%s\n' "$TAR"
printf 'sha256=%s\n' "$SHA"
printf 'size_bytes=%s\n' "$SIZE_BYTES"
printf 'created=%s\n' "$ISO"
REMOTE_SH

# Run remotely with positional args (alias, id, label).
# 2>&1 to capture stderr too — we want to surface "no_paths" if it fires.
remote_out=""
remote_combined=""
if ! remote_combined="$(printf '%s' "$SNAP_REMOTE_SCRIPT" | ssh \
        $(_ssh_key_arg) $(_ssh_common_opts | xargs) -o ConnectTimeout=15 \
        "$(_ssh_target)" \
        "sh -s -- $(printf '%q ' "$SNAP_DIR_REMOTE" "$snap_id" "$label")" 2>&1)"; then
  if printf '%s' "$remote_combined" | grep -q 'no_paths_to_snapshot=1\|snap_err=no_paths'; then
    echo "backup-now: на роутере нет ни одного из ожидаемых путей — отказываюсь делать пустой снимок." >&2
    echo "backup-now: похоже, роутер ещё не настроен (нет /etc/sing-box и т.п.). Запусти bin/install-vpn.sh или bin/doctor.sh сначала." >&2
    exit 2
  fi
  echo "backup-now: удалённый tar не удался" >&2
  [ -n "$remote_combined" ] && printf '%s\n' "$remote_combined" | head -5 >&2
  exit 2
fi
remote_out="$remote_combined"

# Parse k=v output.
parse_kv() {
  printf '%s\n' "$remote_out" | awk -F= -v k="$1" '$1==k {sub(/^[^=]+=/, ""); print; exit}'
}
got_id="$(parse_kv snap_id)"
sha256_val="$(parse_kv sha256)"
size_bytes="$(parse_kv size_bytes)"
created="$(parse_kv created)"

if [ -z "$got_id" ] || [ "$got_id" != "$snap_id" ]; then
  echo "backup-now: неожиданный ответ от роутера (got_id='$got_id')" >&2
  exit 2
fi

# --- Retention --------------------------------------------------------------
# Keep: union of last 10 (by id-as-date) AND any from last 30 days.
# We compute epochs from snap IDs WITHOUT relying on `date -d` or `date -j`
# (neither exists in busybox). Pure awk arithmetic — coarse civil-time → epoch
# using fixed month lengths is plenty for "is this within 30 days".
pruned_count=0
kept_count=0
if [ "$no_prune" != "1" ]; then
  prune_script='
set -eu
SNAP_DIR="$1"
KEEP_N="$2"
KEEP_DAYS="$3"

NOW_S="$(date -u +%s)"
CUTOFF=$((NOW_S - KEEP_DAYS*86400))

# Newest first by ID (lexical == time, since IDs are UTC timestamps).
i=0
ls -1 "$SNAP_DIR"/*.meta.json 2>/dev/null | sort -r | while read -r M; do
  i=$((i + 1))
  ID="$(basename "$M" .meta.json)"

  # Compute epoch from "snap-YYYYMMDDTHHMMSSZ" via awk. POSIX-only: no
  # mktime() (busybox awk lacks it). We use civil-time approximation:
  #   epoch ≈ days_since_1970 * 86400 + H*3600 + M*60 + S
  # where days_since_1970 sums full years (with leap days) + month offsets.
  EPOCH="$(printf "%s" "$ID" | awk '"'"'
    BEGIN { split("0 31 59 90 120 151 181 212 243 273 304 334", mo_off, " ") }
    {
      if (match($0, /snap-([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z/)) {
        s = substr($0, RSTART, RLENGTH)
        y  = substr(s, 6, 4) + 0
        mo = substr(s, 10, 2) + 0
        d  = substr(s, 12, 2) + 0
        h  = substr(s, 15, 2) + 0
        mi = substr(s, 17, 2) + 0
        se = substr(s, 19, 2) + 0
        if (y < 1970 || mo < 1 || mo > 12) { print 0; exit }
        # Days from 1970-01-01 to start of year y.
        days = (y - 1970) * 365
        # Leap days: years divisible by 4 (excl. 100, incl. 400) between 1970..y-1.
        for (yy = 1970; yy < y; yy++) {
          if ((yy % 4 == 0 && yy % 100 != 0) || (yy % 400 == 0)) days += 1
        }
        days += mo_off[mo] + (d - 1)
        # Add this years leap day if past Feb.
        if (mo > 2 && ((y % 4 == 0 && y % 100 != 0) || (y % 400 == 0))) days += 1
        print days * 86400 + h * 3600 + mi * 60 + se
      } else {
        print 0
      }
    }
  '"'"')"

  KEEP=0
  # Rule 1: keep last N regardless of age.
  if [ "$i" -le "$KEEP_N" ]; then KEEP=1; fi
  # Rule 2: keep if within KEEP_DAYS.
  if [ -n "$EPOCH" ] && [ "$EPOCH" != "0" ] && [ "$EPOCH" -ge "$CUTOFF" ]; then KEEP=1; fi

  if [ "$KEEP" = "1" ]; then
    printf "kept=%s\n" "$ID"
  else
    rm -f "$SNAP_DIR/${ID}.tar.gz" "$SNAP_DIR/${ID}.meta.json"
    printf "pruned=%s\n" "$ID"
  fi
done
'
  # Best-effort prune. Capture counts.
  if prune_out="$(ssh \
        $(_ssh_key_arg) $(_ssh_common_opts | xargs) -o ConnectTimeout=15 \
        "$(_ssh_target)" \
        "sh -s -- $(printf '%q ' "$SNAP_DIR_REMOTE" "10" "30")" \
        <<<"$prune_script" 2>/dev/null)"; then
    pruned_count="$(printf '%s\n' "$prune_out" | grep -c '^pruned=' || true)"
    kept_count="$(printf '%s\n' "$prune_out" | grep -c '^kept=' || true)"
  fi

  if [ "$quiet" != "1" ]; then
    printf 'retention: kept %s, pruned %s\n' "${kept_count:-0}" "${pruned_count:-0}" >&2
  fi
fi

# --- Update memory/journal (label is already validated as secret-free) -------
if ! memory_journal_append "$ROUTER_ALIAS" "snapshot_created" \
       "snapshot_id=$snap_id" "label=${label:-(none)}" "sha256=${sha256_val:-}" \
       "size_bytes=${size_bytes:-0}"; then
  echo "backup-now: не смог записать journal (не критично)" >&2
fi

# stdout: snapshot id, for downstream capture.
printf '%s\n' "$snap_id"

if [ "$quiet" != "1" ]; then
  cat >&2 <<EOF

backup-now: готово.
  router:      $ROUTER_ALIAS
  snapshot:    $snap_id
  путь:        $tar_path
  meta:        $meta_path
  sha256:      ${sha256_val:-?}
  size:        ${size_bytes:-?} bytes
  label:       ${label:-(none)}
  created:     ${created:-?}
  pruned:      ${pruned_count:-0} старых снимков
EOF
fi

exit 0
