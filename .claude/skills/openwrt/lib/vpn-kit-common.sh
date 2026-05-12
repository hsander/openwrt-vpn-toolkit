#!/bin/sh
# Shared helpers for openwrt-vpn-kit lib/* scripts.
# Source, do not execute. POSIX sh (busybox-safe) — avoid bashisms.

# Exit code contract (shared across state-write/notes-write/quirks-update/journal-append):
VPN_KIT_EXIT_OK=0
VPN_KIT_EXIT_STALE=11
VPN_KIT_EXIT_LOCK=12
VPN_KIT_EXIT_VALIDATION=13

# Default paths. Override via env vars in tests or on unusual routers.
: "${VPN_KIT_STATE_FILE:=/etc/vpn-kit/install-state.json}"
: "${VPN_KIT_NOTES_FILE:=/etc/vpn-kit/journal/router-notes.md}"
: "${VPN_KIT_QUIRKS_FILE:=/etc/vpn-kit/journal/learned-quirks.yaml}"
: "${VPN_KIT_JOURNAL_FILE:=/etc/vpn-kit/journal/events.jsonl}"
: "${VPN_KIT_ROLLBACK_DIR:=/etc/vpn-kit/rollback.d}"
: "${VPN_KIT_SNAPSHOT_DIR:=/etc/vpn-kit/snapshots}"
: "${VPN_KIT_LOCK_DIR:=/var/lock}"
: "${VPN_KIT_LOCK_TIMEOUT:=5}"
: "${VPN_KIT_JOURNAL_MAX_BYTES:=2097152}"
: "${VPN_KIT_JOURNAL_ROTATE_KEEP:=5}"
: "${VPN_KIT_ROLLBACK_TICK_SECONDS:=5}"
: "${VPN_KIT_TARGET_ROOT:=}"

# Secret patterns that MUST never appear in journal/notes/quirks.
# CANONICAL SOURCE: lib/memory-journal.sh (_MEMORY_JOURNAL_SECRET_RE).
# Keep this string character-identical to that one. If you extend it,
# update both files in the same commit.
VPN_KIT_SECRET_PATTERNS='vless://|bot[0-9]+:[A-Za-z0-9_-]{20,}|"bot_token":|BOT_TOKEN=|TG_TOKEN=|-----BEGIN [A-Z]+ PRIVATE KEY-----'

# --- timestamp ------------------------------------------------------------
vpn_kit_now_iso8601() {
  # Portable ISO8601 UTC, to the second.
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- validation -----------------------------------------------------------
vpn_kit_validate_writer_id() {
  # <role>@<instance-id>  e.g. claude-code@session-abc123
  printf '%s' "$1" | grep -qE '^[a-z-]+@[a-zA-Z0-9._-]+$'
}

vpn_kit_require_cmd() {
  # Die 13 if any listed command is not on PATH.
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "vpn-kit: missing required command: $cmd" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    fi
  done
}

vpn_kit_validate_step_id() {
  printf '%s' "$1" | grep -qE '^[a-z0-9][a-z0-9-]*$'
}

vpn_kit_contains_secret() {
  # stdin: text to scan. exit 0 if a secret pattern matches.
  grep -Eq "$VPN_KIT_SECRET_PATTERNS"
}

# --- lock -----------------------------------------------------------------
# Portable advisory lock via `flock`. Production OpenWrt busybox has it.
# On macOS: `brew install flock`. If flock absent, fall back to mkdir-lock
# (atomic across POSIX). Tests should work without flock installed.

_vpn_kit_lock_file_for() {
  # Map a logical lock name (e.g. "state") to a path.
  printf '%s/vpn-kit-%s.lock' "$VPN_KIT_LOCK_DIR" "$1"
}

vpn_kit_with_lock() {
  # Usage: vpn_kit_with_lock <name> <command> [args...]
  # Acquires exclusive lock for up to $VPN_KIT_LOCK_TIMEOUT seconds.
  # Exits $VPN_KIT_EXIT_LOCK (12) if cannot acquire.
  _name="$1"; shift
  _lock_path="$(_vpn_kit_lock_file_for "$_name")"
  mkdir -p "$VPN_KIT_LOCK_DIR" 2>/dev/null || true

  if command -v flock >/dev/null 2>&1 && flock --help 2>&1 | grep -q -- '-w'; then
    # flock(1) is available. Use file descriptor form.
    # shellcheck disable=SC2094
    (
      flock -x -w "$VPN_KIT_LOCK_TIMEOUT" 9 || exit "$VPN_KIT_EXIT_LOCK"
      "$@"
    ) 9>"$_lock_path"
    return $?
  fi

  # Fallback: mkdir-based lock. Directory creation is atomic on POSIX.
  _dir_lock="${_lock_path}.d"
  _waited=0
  while ! mkdir "$_dir_lock" 2>/dev/null; do
    if [ "$_waited" -ge "$VPN_KIT_LOCK_TIMEOUT" ]; then
      return "$VPN_KIT_EXIT_LOCK"
    fi
    sleep 1
    _waited=$((_waited + 1))
  done
  # Ensure cleanup on any exit of the caller subshell.
  trap 'rmdir "$_dir_lock" 2>/dev/null' EXIT INT TERM
  "$@"
  _rc=$?
  rmdir "$_dir_lock" 2>/dev/null || true
  trap - EXIT INT TERM
  return "$_rc"
}

# --- atomic file write ----------------------------------------------------
vpn_kit_atomic_write() {
  # Usage: vpn_kit_atomic_write <target>   (reads bytes from stdin)
  # Writes to <target>.tmp.<pid>, fsyncs, then renames.
  _target="$1"
  _tmp="${_target}.tmp.$$"
  mkdir -p "$(dirname "$_target")" 2>/dev/null || true
  cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
  # sync is best-effort; not all hosts have it (busybox has; bash builtin none).
  command -v sync >/dev/null 2>&1 && sync
  mv -f "$_tmp" "$_target"
}

vpn_kit_safe_name() {
  # Make a stable filename from an absolute path or command id.
  printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'
}

vpn_kit_target_path() {
  # Prefix absolute router paths with VPN_KIT_TARGET_ROOT for tests/install staging.
  _path="$1"
  if [ -n "$VPN_KIT_TARGET_ROOT" ]; then
    case "$_path" in
      /*) printf '%s%s\n' "$VPN_KIT_TARGET_ROOT" "$_path" ;;
      *) printf '%s/%s\n' "$VPN_KIT_TARGET_ROOT" "$_path" ;;
    esac
  else
    printf '%s\n' "$_path"
  fi
}

# --- sha256 ---------------------------------------------------------------
vpn_kit_sha256() {
  # stdin -> lowercase hex sha256. Tries sha256sum, shasum, openssl in order.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    echo "vpn-kit: no sha256 backend (sha256sum/shasum/openssl)" >&2
    return 1
  fi
}
