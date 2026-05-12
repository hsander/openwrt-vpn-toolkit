#!/usr/bin/env bash
# lib/memory-journal.sh — append markdown events to memory/<alias>/journal.md.
# Refuses to write values that match secret regex.
# Enforces a per-event-kind ALLOWLIST of keys (stricter than the old blocklist).

# Secret patterns.
# CANONICAL SOURCE for this regex (mirrored to lib/vpn-kit-common.sh as
# VPN_KIT_SECRET_PATTERNS — must be character-identical).
_MEMORY_JOURNAL_SECRET_RE='vless://|bot[0-9]+:[A-Za-z0-9_-]{20,}|"bot_token":|BOT_TOKEN=|TG_TOKEN=|-----BEGIN [A-Z]+ PRIVATE KEY-----'

_mj_has_secret() {
  printf '%s' "$1" | grep -qE "$_MEMORY_JOURNAL_SECRET_RE"
}

# Per-event-kind allowlist of keys.
#
# This is the SOURCE OF TRUTH. If you add a new event kind or pass a new
# key from any bin/*.sh, you MUST register it here, otherwise the call will
# be rejected with exit 13.
#
# Rationale: a blocklist (the previous design) was easy to bypass with names
# like `pbk=`, `psk=`, `apikey=`, `secret=`, `auth=`. An allowlist forces
# the developer adding a new key to think about whether it could be a secret.
#
# Example rejection: `memory_journal_append <alias> add_domain pubkey=AAA...`
# is rejected because `pubkey` is not in the allowlist for `add_domain`
# (only `domain`, `outbound`, `snapshot_before` are allowed).
_mj_allowed_keys_for() {
  case "$1" in
    ssh_setup_completed)        printf 'host user port ssh_alias' ;;
    watchdog_setup_completed)   printf 'watchdogs cron_lines' ;;
    vpn_install_completed)      printf 'tag host port proxy_port snapshot_before activated' ;;
    add_vpn)                    printf 'tag host port proxy_port added_to_failover snapshot_before' ;;
    remove_vpn)                 printf 'tag snapshot_before removed_proxy_ports' ;;
    add_domain)                 printf 'domain outbound snapshot_before' ;;
    remove_domain)              printf 'domain snapshot_before' ;;
    add_proxy)                  printf 'port outbound listen snapshot_before' ;;
    remove_proxy)               printf 'port snapshot_before' ;;
    snapshot_created)           printf 'snapshot_id label sha256 size_bytes' ;;
    restore)                    printf 'from_snapshot safety_snapshot reason result memory_stale_warning' ;;
    raw_ssh_session_opened)     printf 'reason mutations_allowed ssh_target' ;;
    raw_ssh_session_closed)     printf 'reason mutations_allowed duration_s exit_code ssh_target' ;;
    raw_ssh_session_aborted)    printf 'reason mutations_allowed duration_s exit_code ssh_target' ;;
    adopted_existing_setup)     printf 'snapshot_before source outbounds_count inbounds_count domains_count config_present rollback_runtime_present' ;;
    # Unknown event kind: empty allowlist => all keys rejected.
    # Agents adding new event kinds MUST register them above.
    *)                          printf '' ;;
  esac
}

# Check whether $1 (key) is in space-separated $2 (allowlist).
# Uses bash glob match against a padded haystack — robust regardless of the
# caller's IFS / shell word-splitting rules (we cannot rely on for-in
# splitting if a future caller sources us from zsh-with-shwordsplit-off).
_mj_key_allowed() {
  local needle="$1" haystack=" $2 "
  [[ "$haystack" == *" $needle "* ]]
}

# memory_journal_append <router-alias> <event-kind> [key=val ...]
#
# Appends a markdown block to memory/<alias>/journal.md:
#
#   ## 2026-05-11T13:42:07Z — add_domain
#   - **domain:** youtube.com
#   - **outbound:** auto-failover
#   ...
#
# Returns 13 if:
#   - event kind is malformed
#   - a key is not in the allowlist for this event kind
#   - a value matches the secret regex
memory_journal_append() {
  local router="$1" kind="$2"
  shift 2
  : "${OPENWRT_SKILL_MEMORY:?OPENWRT_SKILL_MEMORY must be set}"

  local journal="$OPENWRT_SKILL_MEMORY/$router/journal.md"
  if [ ! -f "$journal" ]; then
    echo "memory-journal: journal.md missing for $router (run doctor first)" >&2
    return 2
  fi

  # Validate kind: lowercase, hyphens/underscores ok
  if ! printf '%s' "$kind" | grep -qE '^[a-z][a-z0-9_]*$'; then
    echo "memory-journal: invalid event kind '$kind' (expected lower-snake-case)" >&2
    return 13
  fi

  local allowed
  allowed="$(_mj_allowed_keys_for "$kind")"

  local iso; iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Build entry into a temp var
  local body=""
  body="$body## $iso — $kind"$'\n'
  body="$body- **router:** $router"$'\n'

  local kv key val
  for kv in "$@"; do
    case "$kv" in
      *=*) key="${kv%%=*}"; val="${kv#*=}" ;;
      *) echo "memory-journal: bad arg '$kv' (expected key=value)" >&2; return 13 ;;
    esac

    # Allowlist check: stricter than the old *token*/*password* blocklist.
    # Catches pbk=, pubkey=, psk=, apikey=, secret=, auth=, cred=, uuid=,
    # short_id=, private_key=, public_key= and anything else not enumerated.
    if ! _mj_key_allowed "$key" "$allowed"; then
      echo "memory-journal: key '$key' not allowed for event '$kind' (see _mj_allowed_keys_for in lib/memory-journal.sh)" >&2
      return 13
    fi

    # Belt-and-suspenders: even if a key is allowlisted, refuse to write a
    # value that looks like a known secret pattern.
    if _mj_has_secret "$val"; then
      echo "memory-journal: refusing to write secret value for key='$key'" >&2
      return 13
    fi

    body="$body- **$key:** $val"$'\n'
  done
  body="$body"$'\n'

  # Append atomically (no concurrent writers from agent side, but still safe).
  printf '%b' "$body" >> "$journal"
}

# memory_journal_recent <router-alias> [count]
# Prints the last N event blocks. Default 5.
memory_journal_recent() {
  local router="$1" n="${2:-5}"
  : "${OPENWRT_SKILL_MEMORY:?}"
  local journal="$OPENWRT_SKILL_MEMORY/$router/journal.md"
  [ -f "$journal" ] || { echo "no journal yet" >&2; return 2; }

  # Each event starts with "## " — take the last $n
  awk -v n="$n" '
    /^## / { events[++count] = "" }
    count > 0 { events[count] = events[count] $0 ORS }
    END {
      start = count - n + 1
      if (start < 1) start = 1
      for (i = start; i <= count; i++) print events[i]
    }
  ' "$journal"
}
