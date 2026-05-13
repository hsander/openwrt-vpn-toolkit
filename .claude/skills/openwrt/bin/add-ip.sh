#!/usr/bin/env bash
# bin/add-ip.sh — append an IP/CIDR to the proxy_subnets nft set used by the
# sing-box tproxy hook for IP-based VPN routing.
#
# PHASE: B.1 — CLI parsing + input validation + router/SSH preflight ONLY.
#              The actual mutation pipeline (snapshot → CAS read → nft + persistent
#              edit → CAS write → memory + journal) is implemented in B.2.
#              B.3 adds rollback wiring & docs.
#
# Flow (when fully implemented, B.1 stops after the preflight section):
#   1. Parse CLI, validate IP/CIDR shape & safeguards, resolve writer-id.        [B.1]
#   2. Resolve router alias + SSH alive check.                                   [B.1]
#   3. Read install-state via CAS (revision + payload).                          [B.2]
#   4. Backup snapshot, render persistent template, apply via staged-apply.      [B.2]
#   5. Idempotent merge into dynamic_additions[] + CAS write.                    [B.2]
#   6. Memory rendering (memory/<alias>/ip-rules.md), journal append.            [B.2]
#   7. Rollback on any apply failure.                                            [B.3]
#
# Usage:
#   bin/add-ip.sh --router <alias> --ip <ipv4-or-cidr>
#                 [--via auto|<tag>] [--no-backup] [--force]
#                 [--allow-ipv6] [--writer <id>] [--quiet] [-h|--help]
#
# Exit codes:
#    0  ok
#    2  invalid usage (CLI parse error, missing required flag)
#   11  CAS STALE                (reserved for B.2)
#   12  CAS LOCK                 (reserved for B.2)
#   13  validation error (bad IP/CIDR, refused safeguard, bad writer-id, etc.)
#   20  router unreachable (SSH preflight failed)
#   30  apply failure / rollback triggered (reserved for B.2/B.3)
#   64  not-implemented sub-mode (currently: --via <tag> per-tag pinning)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/vpn-kit-common.sh
. "$SKILL_HOME/lib/vpn-kit-common.sh"
# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"

# --- usage --------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: bin/add-ip.sh --router <alias> --ip <ipv4-or-cidr>
                     [--via auto|<tag>] [--no-backup] [--force]
                     [--allow-ipv6] [--writer <id>] [--quiet] [-h|--help]

Добавляет IP-адрес или CIDR-подсеть в nft-сет `proxy_subnets`, чтобы трафик к
этим адресам уходил через VPN. Запись становится persistent через шаблон
/etc/init.d/sing-box-tproxy и hot-applied через `nft add element`.

Options:
  --router <alias>   alias из memory/routers.yaml (обяз.)
  --ip <addr>        IPv4 или IPv4/CIDR (например 1.2.3.4 или 10.20.0.0/16).
                     Без префикса нормализуется в /32.
  --via auto         (default) кладёт в общий nft-сет proxy_subnets.
  --via <tag>        per-tag pinning — НЕ реализовано в V1.1; exit 64.
  --no-backup        ⚠ только для тестов — пропустить pre-backup.
  --force            обойти safeguard'ы (0.0.0.0/0, RFC1918).
                     Loopback/link-local/multicast НЕ обходятся.
  --allow-ipv6       разрешить IPv6 (нужен python3 для валидации).
  --writer <id>      writer-id для CAS (формат: ^[a-z-]+@[A-Za-z0-9._-]+$).
                     Default: claude-code@add-ip-<unix-ts>.
  --quiet            подавить informational stderr (errors всё равно идут).
  -h, --help         показать эту справку.

Exit codes: 0 ok | 2 usage | 11 stale | 12 lock | 13 validation
            20 unreachable | 30 apply/rollback | 64 not-implemented
EOF
}

# --- CLI parsing --------------------------------------------------------------

router=""
ip_input=""
via="auto"
no_backup=0
force=0
allow_ipv6=0
writer=""
quiet=0

# Print informational messages unless --quiet. Errors are unconditional.
info() {
  if [ "$quiet" = "0" ]; then
    printf 'add-ip: %s\n' "$*" >&2
  fi
}

err() {
  printf 'add-ip: %s\n' "$*" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --router)
      [ $# -ge 2 ] || { err "--router требует значение"; exit 2; }
      router="$2"; shift 2 ;;
    --ip)
      [ $# -ge 2 ] || { err "--ip требует значение"; exit 2; }
      ip_input="$2"; shift 2 ;;
    --via)
      [ $# -ge 2 ] || { err "--via требует значение"; exit 2; }
      via="$2"; shift 2 ;;
    --no-backup) no_backup=1; shift ;;
    --force)     force=1;     shift ;;
    --allow-ipv6) allow_ipv6=1; shift ;;
    --writer)
      [ $# -ge 2 ] || { err "--writer требует значение"; exit 2; }
      writer="$2"; shift 2 ;;
    --quiet) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) err "неизвестный флаг: $1"; usage >&2; exit 2 ;;
    *)  err "неожиданный позиционный аргумент: $1"; usage >&2; exit 2 ;;
  esac
done

# Required-flag check. We do this BEFORE shape validation so a totally
# blank invocation gets a clear "usage" error (exit 2), not "bad IP" (exit 13).
if [ -z "$router" ]; then
  err "--router обязателен"
  usage >&2
  exit 2
fi
if [ -z "$ip_input" ]; then
  err "--ip обязателен"
  usage >&2
  exit 2
fi

# --- --via gate ---------------------------------------------------------------
# Per-tag pinning needs a separate per-tag rule_set / nft set in V1.1+, plus a
# matching route.rules entry. Refusing fast prevents silently routing through
# the wrong outbound. Use pin-device.sh for "this device through tag X" or
# wait for V1.2 per-tag IP pinning.
if [ "$via" != "auto" ]; then
  cat >&2 <<EOF
add-ip: per-tag pinning (--via $via) пока не реализовано в V1.1.

Используй:
  - --via auto (default) — общий nft-сет proxy_subnets.
  - bin/pin-device.sh    — закрепить конкретное устройство за tag-ом.

Per-tag IP pinning требует отдельного nft-сета + route.rules в config.json;
запланировано на V1.2. Если очень нужно сейчас — bin/raw-ssh.sh + bin/doctor.sh.
EOF
  exit 64
fi

# --- writer-id default + validation ------------------------------------------
if [ -z "$writer" ]; then
  writer="claude-code@add-ip-$(date +%s)"
fi
if ! vpn_kit_validate_writer_id "$writer"; then
  err "невалидный --writer '$writer' (формат: ^[a-z-]+@[A-Za-z0-9._-]+$)"
  exit 13
fi

# --- IP family detection ------------------------------------------------------
# Cheap pre-check: a colon means "looks like IPv6". This shapes the decision
# tree before we get into octet-by-octet validation.
is_ipv6=0
case "$ip_input" in
  *:*) is_ipv6=1 ;;
esac

# --- IPv4 validators ----------------------------------------------------------

# validate_ipv4 <input>
#   stdin: -
#   prints normalized "addr/prefix" on success (always with /N, /32 if missing)
#   returns 0 if valid IPv4 or IPv4/CIDR with octets 0-255 and prefix 0-32.
validate_ipv4() {
  local in="$1"
  # Shape check first — cheap, weeds out 99% of junk.
  if ! printf '%s' "$in" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'; then
    return 1
  fi

  local addr prefix
  case "$in" in
    */*) addr="${in%/*}"; prefix="${in#*/}" ;;
    *)   addr="$in";      prefix="32" ;;
  esac

  # Octet range check.
  local IFS=.
  # shellcheck disable=SC2086
  set -- $addr
  for octet in "$@"; do
    # No leading zeros except "0" itself — "010" is ambiguous (octal-ish).
    # We tolerate them as decimal but Cap at 255 below.
    if [ "$octet" -gt 255 ] 2>/dev/null; then
      return 1
    fi
    if [ -z "$octet" ]; then
      return 1
    fi
  done

  # Prefix range check (0..32).
  if [ "$prefix" -lt 0 ] 2>/dev/null || [ "$prefix" -gt 32 ] 2>/dev/null; then
    return 1
  fi

  printf '%s/%s' "$addr" "$prefix"
}

# --- IPv6 validator -----------------------------------------------------------
# Delegates to python3's ipaddress.ip_network for correctness — bash regex for
# IPv6 is a known footgun (`::`, embedded IPv4, zone-id, etc.).
validate_ipv6() {
  local in="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    err "cannot validate IPv6 without python3; install python3 or pass an IPv4"
    exit 13
  fi
  # strict=False allows host bits set (we don't require net-aligned input).
  python3 - "$in" <<'PY' 2>/dev/null
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    if not isinstance(net, ipaddress.IPv6Network):
        sys.exit(1)
    print(f"{net.network_address}/{net.prefixlen}")
except (ValueError, IndexError):
    sys.exit(1)
PY
}

# --- Refused-prefix safeguards ------------------------------------------------
# These run AFTER shape validation, so we know we have a normalized addr/prefix.
# Returns 0 ("refuse") or 1 ("ok to pass").
#
# Categorization:
#   - ALWAYS refused (no --force escape):
#       loopback 127.0.0.0/8, ::1/128
#       link-local 169.254.0.0/16, fe80::/10
#       multicast 224.0.0.0/4, ff00::/8
#   - Refused without --force:
#       0.0.0.0/0, ::/0 (default route — would VPN-route everything)
#       RFC1918 (10/8, 172.16/12, 192.168/16) — own LAN, almost always bug
check_refused() {
  local normalized="$1"
  local addr prefix
  addr="${normalized%/*}"
  prefix="${normalized#*/}"

  # --- ALWAYS refused (force does NOT bypass) ---
  case "$addr" in
    127.*)              err "отказываюсь добавлять loopback '$normalized' (127.0.0.0/8)"; exit 13 ;;
    169.254.*)          err "отказываюсь добавлять link-local '$normalized' (169.254.0.0/16)"; exit 13 ;;
  esac

  # Multicast IPv4: 224.0.0.0 - 239.255.255.255
  local first_octet="${addr%%.*}"
  if [ -n "$first_octet" ] && [ "$first_octet" -ge 224 ] 2>/dev/null && [ "$first_octet" -le 239 ] 2>/dev/null; then
    err "отказываюсь добавлять multicast '$normalized' (224.0.0.0/4)"
    exit 13
  fi

  # IPv6 always-refused (loopback / link-local / multicast).
  # Lowercase for matching; ipaddress normalizes already, but be defensive.
  local addr_lc
  addr_lc="$(printf '%s' "$addr" | tr 'A-Z' 'a-z')"
  case "$addr_lc" in
    ::1)        err "отказываюсь добавлять IPv6 loopback '::1/128'"; exit 13 ;;
    fe8?:*|fe9?:*|fea?:*|feb?:*) err "отказываюсь добавлять IPv6 link-local '$normalized' (fe80::/10)"; exit 13 ;;
    ff*)        err "отказываюсь добавлять IPv6 multicast '$normalized' (ff00::/8)"; exit 13 ;;
  esac

  # --- Refused without --force ---
  if [ "$force" = "1" ]; then
    return 0
  fi

  # Default route — would tunnel literally everything.
  case "$normalized" in
    0.0.0.0/0|::/0)
      err "'$normalized' — default route. Заворачивать ВСЁ в VPN через add-ip — почти всегда ошибка."
      err "Если действительно нужно — повтори с --force. Лучше — настрой default outbound в sing-box config."
      exit 13
      ;;
  esac

  # RFC1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16. The router's own LAN
  # almost never wants to be routed through itself.
  case "$addr" in
    10.*)
      err "'$normalized' в RFC1918 10.0.0.0/8 (твой LAN). VPN-роутинг внутрь LAN — обычно ошибка."
      err "Если уверен — добавь --force."
      exit 13
      ;;
    192.168.*)
      err "'$normalized' в RFC1918 192.168.0.0/16 (твой LAN). VPN-роутинг внутрь LAN — обычно ошибка."
      err "Если уверен — добавь --force."
      exit 13
      ;;
    172.*)
      # 172.16.0.0 - 172.31.255.255 → second octet 16..31
      local second="${addr#172.}"
      second="${second%%.*}"
      if [ -n "$second" ] && [ "$second" -ge 16 ] 2>/dev/null && [ "$second" -le 31 ] 2>/dev/null; then
        err "'$normalized' в RFC1918 172.16.0.0/12 (твой LAN). VPN-роутинг внутрь LAN — обычно ошибка."
        err "Если уверен — добавь --force."
        exit 13
      fi
      ;;
  esac

  return 0
}

# --- run validation -----------------------------------------------------------

normalized=""
family=""
if [ "$is_ipv6" = "1" ]; then
  if [ "$allow_ipv6" = "0" ]; then
    err "'$ip_input' выглядит как IPv6; нужен флаг --allow-ipv6 для опт-ина."
    exit 13
  fi
  if ! normalized="$(validate_ipv6 "$ip_input")" || [ -z "$normalized" ]; then
    err "невалидный IPv6 '$ip_input'"
    exit 13
  fi
  family="ipv6"
else
  if ! normalized="$(validate_ipv4 "$ip_input")" || [ -z "$normalized" ]; then
    err "невалидный IPv4/CIDR '$ip_input' (ожидаю N.N.N.N или N.N.N.N/M, октеты 0-255, prefix 0-32)"
    exit 13
  fi
  family="ipv4"
fi

# Safeguards (loopback/link-local/multicast always; RFC1918/default unless --force).
check_refused "$normalized"

info "validated: input='$ip_input' → normalized='$normalized' family=$family"

# --- Resolve router + SSH alive ----------------------------------------------
# Mirrors add-domain.sh:118-129: resolve first, then ping. Resolution failure
# (registry missing / bad alias) is exit 2 from resolve_router_config; SSH
# unreachable is our own exit 20 (per the contract above).
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
add-ip: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Проверь:
  - роутер включён и в сети,
  - ssh ключ ($ROUTER_SSH_KEY) загружен в агент,
  - bin/doctor.sh --router $ROUTER_ALIAS говорит "ok".
EOF
  exit 20
fi

info "router resolved: alias=$ROUTER_ALIAS host=$ROUTER_HOST user=$ROUTER_USER ssh=alive"

# --- Draft variable stack ready for B.2 --------------------------------------
# B.2 will source the following from this point:
#   $ROUTER_ALIAS, $ROUTER_HOST, $ROUTER_USER, $ROUTER_SSH_KEY  (router-config)
#   $normalized   — "addr/prefix" (always has /N)
#   $family       — "ipv4" | "ipv6"
#   $via          — currently always "auto" (gate above refuses others)
#   $writer       — validated writer-id for CAS write
#   $no_backup    — 0/1; if 1, skip backup-now.sh in B.2
#   $force        — 0/1; B.2 propagates this into apply-time confirmations
#   $allow_ipv6   — 0/1; B.2 picks ipv4 vs ipv6 nft set name based on $family
#   $quiet        — 0/1; suppresses informational echoes
#
# Remote paths B.2 will use (declared here for the next agent's convenience;
# leave them commented until B.2 actually consumes them — `set -u` would not
# trip on these since they're never read in B.1):
#   REMOTE_TPROXY_INIT="/etc/init.d/sing-box-tproxy"
#   REMOTE_STATE="/etc/vpn-kit/install-state.json"
#   NFT_TABLE="inet sing_box_tproxy"
#   NFT_SET_V4="proxy_subnets"
#   NFT_SET_V6="proxy_subnets_v6"
#
# B.2 idempotency contract:
#   - read state via remote_read_state_json
#   - check dynamic_additions[] for type=subnet AND value=$normalized
#   - if present → exit 0 (no-op, no journal, no nft change)
#   - else → backup, render template, staged-apply, CAS write, journal.

# === B.2 starts here ==========================================================
# Persistent-first atomic apply.
#
# Order of operations (per critic-review R2):
#   1. Snapshot (backup-now.sh) so we have a rollback target.
#   2. Read install-state revision + payload via CAS shim.
#   3. Expand files_owned_by_skill (defensive: tproxy init + persistent-sets.nft)
#      via a CAS write BEFORE any file mutation. Stops adopt drift later.
#   4. Drift detection on /etc/init.d/sing-box-tproxy via adopted_config_sha256.
#   5. Idempotency check (tri-state):
#        case A: persistent + state + runtime all agree → no-op exit 0.
#        case B: persistent + state but not runtime, uptime<5m OR install<5m →
#                silent `nft add element` (boot-window sync), journal, exit 0.
#        case C: persistent + state but not runtime, age≥5m → loud warn on
#                stderr, `nft add element` recovery, journal, exit 0.
#        case D: anything else → continue to step 6.
#   6. Build new /etc/vpn-kit/persistent-sets.nft (append + dedup).
#   7. Patch /etc/init.d/sing-box-tproxy to source persistent-sets.nft on start
#      (idempotent — skip if hook already present).
#   8. Atomic mv of BOTH files into place via one ssh round-trip.
#   9. Runtime nft add element (after persistent succeeded).
#  10. CAS-write final state (dynamic_additions[] += $entry), with retry on STALE.
#  11. Verify subnet visible in `nft list set`.
#  12. Render memory/<alias>/subnets.md from updated install-state.
#  13. Memory journal append (event=add_ip).
#
# IPv6 is intentionally NOT supported in B.2 (see open-question resolution
# #1: shipping V1.1 fast is more valuable than dual-stack scaffolding).
# B.3 owns proxy_subnets_v6.
#
# Rollback strategy: any failure AFTER step 8 (persistent files moved) triggers
# bin/restore.sh against $snapshot_id. We additionally `nft delete element` if
# the rule was hot-applied — restore.sh only handles file-level state and
# reload, not runtime nft membership.

# --- Source extra libs needed for B.2 ----------------------------------------
# shellcheck source=../lib/install-state-remote.sh
. "$SKILL_HOME/lib/install-state-remote.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"
# shellcheck source=../lib/template-render.sh
. "$SKILL_HOME/lib/template-render.sh"

# Remote paths (frozen contract — keep in sync with adopt.sh / install-vpn.sh).
REMOTE_TPROXY_INIT="/etc/init.d/sing-box-tproxy"
REMOTE_PERSISTENT_SETS="/etc/vpn-kit/persistent-sets.nft"
NFT_TABLE_FAMILY="inet"
NFT_TABLE_NAME="sing_box_tproxy"
NFT_SET_V4="proxy_subnets"
# NFT_SET_V6="proxy_subnets_v6"  # B.3 territory.

# Hard refuse IPv6 in B.2 — even if --allow-ipv6 made it past validation in B.1
# we have no persistent-sets template wiring for proxy_subnets_v6 yet. Honest
# error beats silently writing v4 entries to a v6 set.
if [ "$family" = "ipv6" ]; then
  err "IPv6 add-ip пока не реализован в V1.1 (B.3 territory). Используй --allow-ipv6 только когда B.3 выйдет."
  exit 13
fi

if ! command -v jq >/dev/null 2>&1; then
  err "локально нужен jq (brew install jq)"
  exit 13
fi

# --- Strip leading-zero octets before any file/state write -------------------
# B.1's validator accepts "010.020.030.040" as decimal (no octal interpretation),
# but writing that to persistent-sets.nft / install-state.json would be
# canonically wrong and break exact-match idempotency on subsequent invocations.
# Normalize once here.
normalized="$(printf '%s\n' "$normalized" | awk '{
  split($1, a, "/"); split(a[1], o, ".");
  printf "%d.%d.%d.%d/%s\n", o[1], o[2], o[3], o[4], a[2]
}')"
info "post-normalize for storage: $normalized"

# --- Tempdir & cleanup --------------------------------------------------------
TMPDIR_LOCAL="$(mktemp -d -t openwrt-skill-add-ip.XXXXXX)"
LOCAL_PERSISTENT_NEW="$TMPDIR_LOCAL/persistent-sets.new.nft"
LOCAL_TPROXY_CUR="$TMPDIR_LOCAL/sing-box-tproxy.cur"
LOCAL_TPROXY_NEW="$TMPDIR_LOCAL/sing-box-tproxy.new"
REMOTE_PERSISTENT_TMP="/tmp/openwrt-skill-persistent-sets.$$.nft"
REMOTE_TPROXY_TMP="/tmp/openwrt-skill-sing-box-tproxy.$$"

# track whether runtime nft add succeeded — needed by rollback to know if we
# must also `nft delete element` (file restore does not undo runtime state).
runtime_added=0
persistent_moved=0

cleanup_addip() {
  rm -rf "$TMPDIR_LOCAL" 2>/dev/null || true
  ssh_run "rm -f $REMOTE_PERSISTENT_TMP $REMOTE_TPROXY_TMP" >/dev/null 2>&1 || true
}
trap cleanup_addip EXIT INT TERM

# rollback_addip <reason>
# Restores from snapshot (file-level) and best-effort deletes the runtime nft
# element if it was added before the failure. Used by every fail-point that
# already mutated router state (steps 8+).
rollback_addip() {
  local reason="$1"
  err "$reason — пытаюсь откатиться"
  if [ "$runtime_added" = "1" ]; then
    # Best-effort runtime cleanup; restore.sh only handles files.
    ssh_run "nft delete element $NFT_TABLE_FAMILY $NFT_TABLE_NAME $NFT_SET_V4 { $normalized } 2>/dev/null" \
      >/dev/null 2>&1 || true
  fi
  if [ -z "$snapshot_id" ]; then
    err "snapshot_id пуст (--no-backup) — file-level rollback недоступен. РУЧНОЕ ВМЕШАТЕЛЬСТВО."
    return 1
  fi
  if ! "$OPENWRT_SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" \
        --snapshot "$snapshot_id" --no-pre-backup >/dev/null 2>&1; then
    err "restore.sh упал — состояние роутера неизвестно. РУЧНОЕ ВМЕШАТЕЛЬСТВО: bin/restore.sh --router $ROUTER_ALIAS --snapshot $snapshot_id"
    return 1
  fi
  return 0
}

# --- Step 1: pre-backup (capture snapshot id) ---------------------------------
snapshot_id=""
if [ "$no_backup" = "1" ]; then
  info "WARN: --no-backup — пропускаю pre-backup snapshot (rollback недоступен)"
else
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
                       --label "before add-ip $normalized" --quiet)"; then
    err "backup-now упал — отказываюсь продолжать"
    exit 2
  fi
  info "snapshot taken: $snapshot_id"
fi

# --- Step 2: read install-state ----------------------------------------------
if ! existing_rev="$(remote_read_revision)"; then
  err "не смог прочитать install-state revision"
  exit 2
fi
if [ "$existing_rev" = "0" ]; then
  err "install-state.json отсутствует (revision=0). Запусти bin/adopt.sh или bin/install-vpn.sh сначала."
  exit 13
fi

if ! current_state_json="$(remote_read_state_json)"; then
  err "не смог прочитать install-state.json"
  exit 2
fi
info "install-state: revision=$existing_rev"

# --- Step 3: expand files_owned_by_skill (defensive, BEFORE mutation) --------
# If a future adopt or critic asks "is persistent-sets.nft tracked?" — yes, the
# moment we touch it. This avoids the "modified file the skill doesn't own"
# drift that the critic flagged.
needs_expand="$(printf '%s' "$current_state_json" | jq -r \
  '((.files_owned_by_skill // []) | (index("/etc/vpn-kit/persistent-sets.nft") == null
                                  or index("/etc/init.d/sing-box-tproxy") == null))')"

if [ "$needs_expand" = "true" ]; then
  expand_payload="$(printf '%s' "$current_state_json" | jq '
    del(._revision, ._last_writer, ._last_writer_host, ._last_updated_at)
    | .files_owned_by_skill = ((.files_owned_by_skill // []) +
                               ["/etc/vpn-kit/persistent-sets.nft",
                                "/etc/init.d/sing-box-tproxy"] | unique)
  ')"
  if ! new_rev="$(remote_cas_write "$writer" "$existing_rev" "$expand_payload" 2>&1)"; then
    cas_rc=$?
    err "ownership-expand CAS write упал (rc=$cas_rc). Stdout: $new_rev"
    exit "$cas_rc"
  fi
  existing_rev="$new_rev"
  # Re-read so subsequent jq merges work on the post-expand snapshot.
  current_state_json="$(remote_read_state_json)"
  info "ownership expanded: files_owned_by_skill += persistent-sets.nft, sing-box-tproxy (rev=$existing_rev)"
fi

# --- Step 4: drift detection on sing-box-tproxy ------------------------------
# adopt.sh records adopted_config_sha256[path] for files it took over. If the
# current on-disk sha doesn't match, someone edited tproxy outside the skill —
# our sed-patch could clobber their change. Refuse unless --force.
adopted_sha="$(printf '%s' "$current_state_json" \
  | jq -r '.adopted_config_sha256["/etc/init.d/sing-box-tproxy"] // null')"

if [ "$adopted_sha" != "null" ] && [ -n "$adopted_sha" ]; then
  current_sha="$(ssh_run "sha256sum $REMOTE_TPROXY_INIT 2>/dev/null | awk '{print \$1}'")"
  if [ -z "$current_sha" ]; then
    err "не смог прочитать sha256sum $REMOTE_TPROXY_INIT"
    exit 2
  fi
  if [ "$current_sha" != "$adopted_sha" ]; then
    if [ "$force" = "1" ]; then
      info "WARN: drift detected on $REMOTE_TPROXY_INIT (expected=$adopted_sha got=$current_sha), --force — продолжаю"
      drift_overridden=1
    else
      cat >&2 <<EOF
add-ip: $REMOTE_TPROXY_INIT drifted from adopted state.
  expected sha256: $adopted_sha
  actual sha256:   $current_sha

Файл был изменён вне скилла. Sed-патч может затереть чужие правки.
Варианты:
  - bin/raw-ssh.sh --router $ROUTER_ALIAS --reason "review tproxy edits"
  - bin/adopt.sh --router $ROUTER_ALIAS (если изменения легитимны — переадоптировать)
  - повтори с --force чтобы патчить поверх drift'а (журналируется как drift_overridden).
EOF
      exit 13
    fi
  fi
else
  info "no adopted_config_sha256 for tproxy init — пропускаю drift check (новый install)"
fi
drift_overridden="${drift_overridden:-0}"

# --- Step 5: idempotency check on dynamic_additions[] ------------------------
# Tri-state discrimination (case A/B/C) — see check_idempotent_state below.
#
#   case A: persistent + dynamic_additions + runtime all agree → no-op.
#   case B: persistent + dyn but NOT runtime, AND uptime/installed_age < 5min
#           → silent `nft add element` (boot-window sync). Journals
#           revision=boot_window_sync. exit 0.
#   case C: persistent + dyn but NOT runtime, age ≥ 5min → runtime drift.
#           Loud warn on stderr, still `nft add element`. Journals
#           revision=runtime_drift_detected. exit 0.
#   case D (default): persistent OR dyn missing → fall through to full
#           mutation pipeline (B.2 steps 6..12).
#
# Boot-window threshold: 300s. Probed via /proc/uptime (Linux/busybox) AND
# wall-clock(now) - installed_at (covers reboots where uptime≈now but install
# was months ago, AND fresh installs where installed_at≈now but router has
# been up for days). Either being < 300s triggers the boot-window branch.

check_idempotent_state() {
  # Inputs (free-vars): $normalized, $current_state_json, $writer,
  #                    $existing_rev, $ROUTER_ALIAS, $family, $via.
  # Side-effects: may `nft add element` + journal + exit 0.
  # Returns 0 (no idempotent match — caller must continue with full pipeline).
  local has_persistent=0 has_dyn_add="false" has_runtime=0

  if ssh_run "grep -F '$normalized' $REMOTE_PERSISTENT_SETS 2>/dev/null" \
       >/dev/null 2>&1; then
    has_persistent=1
  fi

  has_dyn_add="$(printf '%s' "$current_state_json" | jq -r \
    --arg v "$normalized" \
    '((.dynamic_additions // []) | map(select(.type=="subnet" and .value==$v)) | length) > 0')"

  if ssh_run "nft list set $NFT_TABLE_FAMILY $NFT_TABLE_NAME $NFT_SET_V4 2>/dev/null" \
       2>/dev/null | grep -qF "$normalized"; then
    has_runtime=1
  fi

  # case A: full agreement → no-op.
  if [ "$has_persistent" = "1" ] && [ "$has_dyn_add" = "true" ] && [ "$has_runtime" = "1" ]; then
    info "subnet '$normalized' уже добавлен (persistent+state+runtime) — no-op (exit 0)"
    exit 0
  fi

  # Cases B/C only fire when persistent + state agree but runtime is missing.
  # Any other partial mismatch (e.g. state has it but persistent doesn't) is
  # NOT a boot-window scenario — it's genuine partial state from a previous
  # half-completed run. Drop into the full pipeline so we re-establish all 3.
  if [ "$has_persistent" = "1" ] && [ "$has_dyn_add" = "true" ] && [ "$has_runtime" = "0" ]; then
    # Determine age via two channels — whichever is smaller wins.
    local uptime_sec="" installed_at="" installed_epoch="" now age
    uptime_sec="$(ssh_run "awk '{print int(\$1)}' /proc/uptime 2>/dev/null" 2>/dev/null | tr -dc '0-9')"
    installed_at="$(printf '%s' "$current_state_json" | jq -r '.installed_at // empty')"
    now="$(date +%s)"

    # Try GNU date first (Linux/CI), fall back to python3 ISO-8601 (macOS/BSD/
    # busybox where `date -d` is missing or weaker).
    if [ -n "$installed_at" ]; then
      installed_epoch="$(date -d "$installed_at" +%s 2>/dev/null || true)"
      if [ -z "$installed_epoch" ] && command -v python3 >/dev/null 2>&1; then
        installed_epoch="$(python3 - "$installed_at" <<'PY' 2>/dev/null || true
import datetime, sys
try:
    s = sys.argv[1].replace("Z", "+00:00")
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    sys.exit(1)
PY
)"
      fi
    fi

    if [ -n "$installed_epoch" ]; then
      age=$(( now - installed_epoch ))
    else
      # Edge case: installed_at missing OR couldn't parse → treat as old
      # install (fall into drift branch) unless uptime says otherwise.
      age=9999
    fi

    local boot_window=0
    if [ -n "$uptime_sec" ] && [ "$uptime_sec" -lt 300 ] 2>/dev/null; then
      boot_window=1
    fi
    if [ "$age" -lt 300 ] 2>/dev/null; then
      boot_window=1
    fi

    if [ "$boot_window" = "1" ]; then
      # case B — silent sync, soft journaling.
      if ! ssh_run "nft add element $NFT_TABLE_FAMILY $NFT_TABLE_NAME $NFT_SET_V4 { $normalized }" \
           >/dev/null 2>&1; then
        err "boot-window: 'nft add element' не удался — что-то странное (set отсутствует?). Падаю в full pipeline."
        return 0
      fi
      memory_journal_append "$ROUTER_ALIAS" "add_ip" \
        "ip=$normalized" \
        "family=$family" \
        "via=$via" \
        "nft_set=$NFT_SET_V4" \
        "revision=boot_window_sync" >/dev/null 2>&1 || true
      info "subnet '$normalized' синхронизировано (boot-window sync; uptime=${uptime_sec:-?}s, install_age=${age}s)"
      exit 0
    else
      # case C — runtime drift, loud warn, still recover.
      if ! ssh_run "nft add element $NFT_TABLE_FAMILY $NFT_TABLE_NAME $NFT_SET_V4 { $normalized }" \
           >/dev/null 2>&1; then
        err "runtime drift detected, но 'nft add element' тоже не удался — set отсутствует. Падаю в full pipeline."
        return 0
      fi
      memory_journal_append "$ROUTER_ALIAS" "add_ip" \
        "ip=$normalized" \
        "family=$family" \
        "via=$via" \
        "nft_set=$NFT_SET_V4" \
        "revision=runtime_drift_detected" >/dev/null 2>&1 || true
      printf 'add-ip: WARN: runtime nft drift detected for %s (install_age=%ss, uptime=%ss) — recovered via nft add element\n' \
        "$normalized" "$age" "${uptime_sec:-?}" >&2
      exit 0
    fi
  fi

  # Falls through — caller continues with full mutation pipeline.
  return 0
}

check_idempotent_state

# --- Step 6: build new persistent-sets.nft -----------------------------------
NFT_HEADER='# vpn-kit persistent nft sets — managed by bin/add-ip.sh'
NFT_NEW_LINE="add element $NFT_TABLE_FAMILY $NFT_TABLE_NAME $NFT_SET_V4 { $normalized }"

if ssh_run "test -f $REMOTE_PERSISTENT_SETS" >/dev/null 2>&1; then
  if ! scp_from "$REMOTE_PERSISTENT_SETS" "$TMPDIR_LOCAL/persistent-sets.cur.nft" >/dev/null 2>&1; then
    err "не смог скачать $REMOTE_PERSISTENT_SETS"
    exit 2
  fi
  # Append + dedup. Preserve original ordering of existing lines; drop blank
  # lines from final to keep file canonical.
  {
    grep -v -F -x "$NFT_NEW_LINE" "$TMPDIR_LOCAL/persistent-sets.cur.nft" || true
    printf '%s\n' "$NFT_NEW_LINE"
  } > "$LOCAL_PERSISTENT_NEW"
else
  {
    printf '%s\n' "$NFT_HEADER"
    printf '%s\n' "$NFT_NEW_LINE"
  } > "$LOCAL_PERSISTENT_NEW"
fi

# --- Step 7: patch /etc/init.d/sing-box-tproxy (idempotent) ------------------
if ! scp_from "$REMOTE_TPROXY_INIT" "$LOCAL_TPROXY_CUR" >/dev/null 2>&1; then
  err "не смог скачать $REMOTE_TPROXY_INIT"
  exit 2
fi

PERSISTENT_LOAD_LINE="  [ -f $REMOTE_PERSISTENT_SETS ] && nft -f $REMOTE_PERSISTENT_SETS"

if grep -qF "$PERSISTENT_LOAD_LINE" "$LOCAL_TPROXY_CUR"; then
  # Hook already in place — no patch needed. Just copy as-is so the staged-apply
  # is still uniform (chmod 755 happens either way).
  cp "$LOCAL_TPROXY_CUR" "$LOCAL_TPROXY_NEW"
  info "tproxy init уже содержит persistent-load hook — пропускаю патч"
else
  # Insert after the last "nft add set " line within start_service() (or start()
  # for legacy non-procd scripts). awk pass: track when we're inside the start
  # block, remember the line number of the last `nft add set`, then emit the
  # hook line right after it. Falls back to "after first `nft add` line of any
  # kind" if no set line was found.
  awk -v hook="$PERSISTENT_LOAD_LINE" '
    BEGIN { in_start = 0; depth = 0; last_set = 0; emitted = 0 }
    {
      lines[NR] = $0
      # Detect start of start_service() / start() block.
      if ($0 ~ /^[[:space:]]*(start_service|start)[[:space:]]*\(\)[[:space:]]*\{/) {
        in_start = 1; depth = 1
      } else if (in_start) {
        n_open  = gsub(/\{/, "{")
        n_close = gsub(/\}/, "}")
        depth += n_open - n_close
        if (depth <= 0) in_start = 0
      }
      if (in_start && $0 ~ /nft[[:space:]]+add[[:space:]]+(set|element)/) {
        last_set = NR
      }
    }
    END {
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (i == last_set && !emitted) {
          print hook
          emitted = 1
        }
      }
      # Pathological fallback: nothing matched. Print hook before final closing
      # brace so the user at least gets a working file (and surface a warning
      # to stderr via the calling script — handled below by grep recheck).
      if (!emitted && last_set == 0) {
        # no-op; caller will re-grep and bail.
      }
    }
  ' "$LOCAL_TPROXY_CUR" > "$LOCAL_TPROXY_NEW"

  if ! grep -qF "$PERSISTENT_LOAD_LINE" "$LOCAL_TPROXY_NEW"; then
    err "не смог найти подходящее место для вставки persistent-load в $REMOTE_TPROXY_INIT (нет 'nft add set' в start блоке). Проверь файл вручную."
    exit 13
  fi
  info "tproxy init пропатчен: добавлен persistent-load hook"
fi

# --- Step 8: atomic apply (mv both files in one ssh round-trip) --------------
if ! scp_to "$LOCAL_PERSISTENT_NEW" "$REMOTE_PERSISTENT_TMP" >/dev/null 2>&1; then
  err "scp persistent-sets.nft в /tmp не удался"
  exit 2
fi
if ! scp_to "$LOCAL_TPROXY_NEW" "$REMOTE_TPROXY_TMP" >/dev/null 2>&1; then
  err "scp sing-box-tproxy в /tmp не удался"
  exit 2
fi

# Single round-trip ensures we don't end up with persistent updated but
# tproxy untouched (or vice versa) on transient SSH flake.
if ! ssh_run "
set -eu
mkdir -p $(dirname "$REMOTE_PERSISTENT_SETS")
mv $REMOTE_PERSISTENT_TMP $REMOTE_PERSISTENT_SETS
chmod 644 $REMOTE_PERSISTENT_SETS
mv $REMOTE_TPROXY_TMP $REMOTE_TPROXY_INIT
chmod 755 $REMOTE_TPROXY_INIT
" >/dev/null 2>&1; then
  err "атомарный mv не удался — пытаюсь откатиться"
  rollback_addip "atomic mv failed" || true
  exit 30
fi
persistent_moved=1
info "persistent applied: $REMOTE_PERSISTENT_SETS + $REMOTE_TPROXY_INIT"

# --- Step 9: runtime nft add element -----------------------------------------
# The set MUST already exist (tproxy created it on its last start). If it
# doesn't, that's a serious mismatch — bail and rollback rather than running
# `nft create set` here (that would silently fix what should be a tproxy bug).
if ! ssh_run "nft add element $NFT_TABLE_FAMILY $NFT_TABLE_NAME $NFT_SET_V4 { $normalized }" \
     >/dev/null 2>&1; then
  err "runtime 'nft add element' не удался — set отсутствует или nft вернул ошибку"
  rollback_addip "runtime nft add failed" || true
  exit 30
fi
runtime_added=1
info "runtime: nft add element $NFT_SET_V4 { $normalized } OK"

# --- Step 10: CAS-write final state with STALE retry -------------------------
# Compact deterministic id (busybox may not have uuidgen).
addition_id="$(printf '%s' "${normalized}-$(date +%s%N 2>/dev/null || date +%s)" \
  | sha256sum | cut -c1-16)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

build_payload() {
  # $1 = current state json
  printf '%s' "$1" | jq \
    --arg id      "$addition_id" \
    --arg value   "$normalized" \
    --arg added   "$now_iso" \
    --arg origin  "claude-code" \
    --arg persist "$REMOTE_PERSISTENT_SETS" \
    --arg nft_set "$NFT_SET_V4" \
    '
      del(._revision, ._last_writer, ._last_writer_host, ._last_updated_at)
      | .dynamic_additions = ((.dynamic_additions // []) + [{
          id: $id,
          type: "subnet",
          value: $value,
          added_at: $added,
          origin: $origin,
          persisted_in: $persist,
          nft_set: $nft_set
        }])
    '
}

cas_attempt=1
cas_max=3
state_revision=""
while [ "$cas_attempt" -le "$cas_max" ]; do
  payload="$(build_payload "$current_state_json")"
  if state_revision="$(remote_cas_write "$writer" "$existing_rev" "$payload" 2>&1)"; then
    info "install-state CAS write OK (revision=$state_revision, attempt=$cas_attempt)"
    break
  fi
  cas_rc=$?
  if [ "$cas_rc" = "11" ] && [ "$cas_attempt" -lt "$cas_max" ]; then
    info "CAS STALE — re-read и retry ($cas_attempt/$cas_max)"
    existing_rev="$(remote_read_revision)" || { err "re-read revision упал"; exit 2; }
    current_state_json="$(remote_read_state_json)" || { err "re-read state упал"; exit 2; }
    cas_attempt=$((cas_attempt + 1))
    continue
  fi
  # Hard failure — runtime + persistent already applied. This is the rare
  # divergence case: router state is forward, install-state is behind. Do NOT
  # rollback (that would lose the working nft entry); journal a warning so
  # operator can re-run reconciliation manually.
  err "install-state CAS write упал после ретраев (rc=$cas_rc). runtime+persistent применены, но state НЕ обновлён."
  memory_journal_append "$ROUTER_ALIAS" "add_ip" \
    "ip=$normalized" \
    "family=$family" \
    "via=$via" \
    "nft_set=$NFT_SET_V4" \
    "snapshot_before=${snapshot_id:-(skipped)}" \
    "revision=cas_failed_after_apply" \
    "drift_overridden=$drift_overridden" >/dev/null 2>&1 || true
  exit "$cas_rc"
done

# --- Step 11: verify --------------------------------------------------------
if ! ssh_run "nft list set $NFT_TABLE_FAMILY $NFT_TABLE_NAME $NFT_SET_V4 2>/dev/null" \
     | grep -qF "$normalized"; then
  err "post-apply verify: '$normalized' НЕ виден в nft list set — что-то странное"
  rollback_addip "verify failed" || true
  exit 30
fi

# --- Step 12: memory render (subnets.md) -------------------------------------
# Rebuild memory/<alias>/subnets.md from the freshly-written install-state.
# Failures here are non-fatal (mutation already succeeded); we log and proceed.
render_subnets_md() {
  local mem_dir="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"
  local subnets_md="$mem_dir/subnets.md"
  local tpl="$SKILL_HOME/memory/_templates/subnets.md"

  mkdir -p "$mem_dir" 2>/dev/null || {
    info "subnets.md: не могу создать $mem_dir (write-protect?) — пропускаю render"
    return 0
  }

  # Re-read post-CAS state so we pick up the just-added row.
  local post_state rows iso
  if ! post_state="$(remote_read_state_json)"; then
    info "subnets.md: re-read state не удался — пропускаю render"
    return 0
  fi
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  rows="$(printf '%s' "$post_state" | jq -r '
    .dynamic_additions // []
    | map(select(.type == "subnet"))
    | sort_by(.added_at // "")
    | map(
        "| \(.value) "
        + "| \(if ((.value // "") | contains(":")) then "ipv6" else "ipv4" end) "
        + "| \(.via // "auto") "
        + "| \(.nft_set // "proxy_subnets") "
        + "| \(.added_at // "-") "
        + "| \(.origin // "-") |"
      )
    | join("\n")
  ' 2>/dev/null)" || rows=""

  if [ -z "$rows" ]; then
    rows="_(пока пусто — добавь через bin/add-ip.sh)_"
  fi

  # If the template's first-time-rendered file is in place, do a targeted
  # placeholder replace (preserves "Файлы на роутере" / "Как добавить" prose).
  # Otherwise render from scratch via template.
  if [ -f "$subnets_md" ] && grep -qF '{{SUBNET_TABLE_ROWS}}' "$subnets_md"; then
    # Pre-render template still has placeholder — substitute in place.
    local tmp; tmp="$(mktemp -t openwrt-skill-subnets.XXXXXX)" || return 0
    SUB="$rows" awk '
      BEGIN { sub_val = ENVIRON["SUB"] }
      {
        if (index($0, "{{SUBNET_TABLE_ROWS}}") > 0) { print sub_val } else { print }
      }
    ' "$subnets_md" > "$tmp" && mv "$tmp" "$subnets_md" || rm -f "$tmp"
  elif [ -f "$subnets_md" ]; then
    # File exists with prior real rows. Replace the table body between the
    # header separator "| IP / CIDR | ..." and the next non-table line.
    local tmp; tmp="$(mktemp -t openwrt-skill-subnets.XXXXXX)" || return 0
    SUB="$rows" awk '
      BEGIN { in_tbl = 0; emitted = 0; sub_val = ENVIRON["SUB"] }
      /^\| IP \/ CIDR \|/ { print; getline; print; in_tbl = 1; next }     # header + separator
      in_tbl == 1 && /^\|/ { next }                                       # drop old body rows
      in_tbl == 1 && !/^\|/ && !emitted { print sub_val; emitted = 1; in_tbl = 0; print; next }
      { print }
      END { if (in_tbl == 1 && !emitted) print sub_val }
    ' "$subnets_md" > "$tmp" && mv "$tmp" "$subnets_md" || rm -f "$tmp"
  elif [ -f "$tpl" ]; then
    # First write — render from template.
    render_template "$tpl" "$subnets_md" \
      "ROUTER_ALIAS=$ROUTER_ALIAS" \
      "LAST_UPDATED_ISO=$iso" \
      "SUBNET_TABLE_ROWS=$rows" \
      "NOTES=" 2>/dev/null || \
      info "subnets.md: render_template упал — пропускаю"
  else
    info "subnets.md: template $tpl отсутствует — пропускаю render"
  fi
}

if ! render_subnets_md; then
  info "subnets.md: render не удался (не критично)"
fi

# --- Step 13: memory journal -------------------------------------------------
if ! memory_journal_append "$ROUTER_ALIAS" "add_ip" \
      "ip=$normalized" \
      "family=$family" \
      "via=$via" \
      "nft_set=$NFT_SET_V4" \
      "snapshot_before=${snapshot_id:-(skipped)}" \
      "revision=$state_revision" \
      "drift_overridden=$drift_overridden"; then
  err "журнал не записан (не критично)"
fi

cat >&2 <<EOF

add-ip: готово.
  router:     $ROUTER_ALIAS
  ip:         $normalized ($family)
  via:        $via
  nft set:    $NFT_TABLE_FAMILY $NFT_TABLE_NAME $NFT_SET_V4
  persistent: $REMOTE_PERSISTENT_SETS
  snapshot:   ${snapshot_id:-(skipped)}
  revision:   $state_revision
EOF

exit 0
