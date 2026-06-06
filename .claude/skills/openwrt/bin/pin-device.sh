#!/usr/bin/env bash
# bin/pin-device.sh — Phase C.1: CLI parse + input validation + outbound verify.
#
# Pins a LAN client (by source IP or CIDR) to a specific sing-box outbound by
# inserting a route.rule with `source_ip_cidr` into /etc/sing-box/config.json
# and a matching nft tproxy mark rule in /etc/init.d/sing-box-tproxy.
#
# C.1 scope (THIS FILE):
#   1. CLI parsing with mutually-exclusive --source-ip / --source-cidr split.
#   2. IP/CIDR validation (regex + octet bounds + bogon refuse).
#   3. LAN-overlap detection (refuses overshadowing the entire LAN unless --force).
#   4. Verify outbound tag exists in remote /etc/sing-box/config.json (ssh+jq).
#   5. Router resolve + SSH alive probe.
#
# C.2/C.3/C.4 (TBD):
#   - jq mutation of config.json (route.rules insert BEFORE auto-failover catch-all)
#   - nft mangle_prerouting tproxy rule insert BEFORE FakeIP rule
#   - staged-apply restart + reachability + auto-rollback
#   - memory MD update + journal append
#
# Usage:
#   bin/pin-device.sh --router <alias> --outbound <tag>
#                     ( --source-ip <ip> | --source-cidr <cidr> )
#                     [--no-backup] [--force] [--allow-ipv6]
#                     [--writer <id>] [--quiet] [-h|--help]
#
# Exit codes:
#    0  ok (C.1 prep complete)
#    2  router not found / SSH unreachable / remote file missing
#   11  install-state CAS conflict (reserved for C.2)
#   12  memory lock contention (reserved for C.2)
#   13  validation refuse (bad IP, bad CIDR, not /32, LAN overlap, outbound missing,
#       loopback/link-local/multicast, bogon, /0 without --force)
#   20  rollback fired (reserved for C.2)
#   30  drift detected (reserved for C.2 — install-state mismatch)
#   64  bad CLI args / unknown flag / missing required / mutually-exclusive violated

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/country-resolve.sh
. "$SKILL_HOME/lib/country-resolve.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/pin-device.sh --router <alias> --outbound <tag>
                         ( --source-ip <ip> | --source-cidr <cidr> )
                         [--no-backup] [--force] [--allow-ipv6]
                         [--writer <id>] [--quiet]

Жёстко пробрасывает конкретное LAN-устройство/подсеть в конкретный outbound,
минуя auto-failover.

Required:
  --router <alias>      alias из memory/routers.yaml
  --outbound <tag>      tag существующего outbound'а в config.json
  --source-ip <ip>      ровно один host (a.b.c.d или a.b.c.d/32; /128 для IPv6).
                        CIDR ≠ /32 здесь → exit 13: используй --source-cidr.
  --source-cidr <cidr>  любая подсеть (a.b.c.d/N). /0 запрещён без --force.
                        CIDR, накрывающий LAN-сеть, требует --force.

Options:
  --no-backup           (testing only) пропустить pre-backup перед apply.
  --force               перезаписать существующее pin-правило / разрешить /0
                        или CIDR, перекрывающий LAN.
  --allow-ipv6          разрешить IPv6 source (по умолчанию только IPv4).
  --writer <id>         writer ID для install-state CAS (default:
                        claude-code@pin-device-<unix-ts>).
  --quiet               минимальный вывод.
  -h, --help            показать справку.

Exit codes:
   0 ok | 2 router/ssh | 13 validation | 20 rollback | 64 cli
EOF
  exit "${1:-64}"
}

router=""
outbound=""
source_ip=""
source_cidr=""
no_backup=0
force=0
allow_ipv6=0
writer=""
quiet=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router)       router="${2:-}"; shift 2 ;;
    --outbound)     outbound="${2:-}"; shift 2 ;;
    --source-ip)    source_ip="${2:-}"; shift 2 ;;
    --source-cidr)  source_cidr="${2:-}"; shift 2 ;;
    --no-backup)    no_backup=1; shift ;;
    --force)        force=1; shift ;;
    --allow-ipv6)   allow_ipv6=1; shift ;;
    --writer)       writer="${2:-}"; shift 2 ;;
    --quiet)        quiet=1; shift ;;
    -h|--help)      usage 0 ;;
    --)             shift; break ;;
    -*)             echo "pin-device: неизвестный флаг: $1" >&2; usage ;;
    *)              echo "pin-device: неожиданный позиционный аргумент: $1" >&2; usage ;;
  esac
done

say() { [ "$quiet" = "1" ] || echo "pin-device: $*" >&2; }

# ---------------------------------------------------------------------------
# Required-args check
# ---------------------------------------------------------------------------
[ -z "$router" ]   && { echo "pin-device: --router обязателен" >&2; usage; }
[ -z "$outbound" ] && { echo "pin-device: --outbound обязателен" >&2; usage; }

# --- Resolve country alias to pool tag (usa → usa-pool, etc.) ----------------
outbound="$(resolve_country_to_pool "$router" "$outbound")"

# Mutually exclusive: exactly one of --source-ip / --source-cidr.
if [ -n "$source_ip" ] && [ -n "$source_cidr" ]; then
  echo "pin-device: --source-ip и --source-cidr взаимоисключающие — укажи ровно один" >&2
  usage
fi
if [ -z "$source_ip" ] && [ -z "$source_cidr" ]; then
  echo "pin-device: укажи либо --source-ip <ip>, либо --source-cidr <cidr>" >&2
  usage
fi

# Outbound tag shape (same alphabet add-vpn/add-proxy use).
if ! printf '%s' "$outbound" | grep -qE '^[a-zA-Z0-9_-]+$'; then
  echo "pin-device: невалидный --outbound '$outbound' (a-zA-Z0-9_-)" >&2
  exit 13
fi

# Writer ID default + validation.
if [ -z "$writer" ]; then
  writer="claude-code@pin-device-$(date +%s)"
fi
if ! printf '%s' "$writer" | grep -qE '^[a-zA-Z0-9._@+-]+$'; then
  echo "pin-device: невалидный --writer '$writer' (a-zA-Z0-9._@+-)" >&2
  exit 13
fi

# ---------------------------------------------------------------------------
# IP / CIDR validators
# ---------------------------------------------------------------------------

# is_ipv4 <str> — exit 0 iff str is a dotted-quad with octets in 0..255.
is_ipv4() {
  local s="$1" a b c d
  case "$s" in
    *[!0-9.]*|'') return 1 ;;
  esac
  IFS=. read -r a b c d _extra <<EOF
$s
EOF
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] || return 1
  [ -z "${_extra:-}" ] || return 1
  for o in "$a" "$b" "$c" "$d"; do
    case "$o" in *[!0-9]*|'') return 1 ;; esac
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
  return 0
}

# is_ipv6 <str> — minimal shape check; full RFC 5952 is overkill here.
is_ipv6() {
  local s="$1"
  case "$s" in
    *:*) ;;
    *) return 1 ;;
  esac
  case "$s" in
    *[!0-9a-fA-F:]*) return 1 ;;
  esac
  return 0
}

# is_prefix_ipv4 <n> — 0..32
is_prefix_ipv4() {
  case "$1" in *[!0-9]*|'') return 1 ;; esac
  [ "$1" -ge 0 ] && [ "$1" -le 32 ]
}

# is_prefix_ipv6 <n> — 0..128
is_prefix_ipv6() {
  case "$1" in *[!0-9]*|'') return 1 ;; esac
  [ "$1" -ge 0 ] && [ "$1" -le 128 ]
}

# refuse_bogon_ipv4 <ip> — refuses loopback / link-local / multicast / unspecified.
# Force does NOT override these — they are never valid as VPN source selectors.
refuse_bogon_ipv4() {
  local ip="$1" a b
  a="${ip%%.*}"
  b="${ip#*.}"; b="${b%%.*}"
  case "$a" in
    0)   echo "pin-device: 0.0.0.0/8 (unspecified) запрещён" >&2; return 1 ;;
    127) echo "pin-device: loopback 127.0.0.0/8 запрещён" >&2; return 1 ;;
    255) echo "pin-device: broadcast 255.x запрещён" >&2; return 1 ;;
  esac
  if [ "$a" -ge 224 ] && [ "$a" -le 239 ]; then
    echo "pin-device: multicast $a.x.x.x запрещён" >&2; return 1
  fi
  if [ "$a" -ge 240 ]; then
    echo "pin-device: reserved $a.x.x.x запрещён" >&2; return 1
  fi
  if [ "$a" = "169" ] && [ "$b" = "254" ]; then
    echo "pin-device: link-local 169.254.0.0/16 запрещён" >&2; return 1
  fi
  return 0
}

refuse_bogon_ipv6() {
  local s="$1"
  case "$s" in
    ::|::1) echo "pin-device: IPv6 loopback/unspecified запрещён" >&2; return 1 ;;
    fe80*|FE80*) echo "pin-device: link-local fe80::/10 запрещён" >&2; return 1 ;;
    ff*|FF*)     echo "pin-device: multicast ff00::/8 запрещён" >&2; return 1 ;;
  esac
  return 0
}

# Parse "<addr>[/<prefix>]" → echoes "<addr> <prefix> <family>" or returns 1.
# family ∈ {v4, v6}. If no prefix supplied, prefix is empty (caller decides default).
split_ip_prefix() {
  local raw="$1" addr prefix
  case "$raw" in
    */*) addr="${raw%/*}"; prefix="${raw#*/}" ;;
    *)   addr="$raw"; prefix="" ;;
  esac
  # Emit "-" as placeholder when prefix is empty so callers can `set --` safely
  # under `set -u` (empty fields would be elided by IFS-split).
  if is_ipv4 "$addr"; then
    if [ -n "$prefix" ]; then
      is_prefix_ipv4 "$prefix" || { echo "pin-device: prefix '$prefix' не подходит для IPv4 (0..32)" >&2; return 1; }
    fi
    printf '%s %s v4\n' "$addr" "${prefix:--}"
    return 0
  fi
  if is_ipv6 "$addr"; then
    if [ -n "$prefix" ]; then
      is_prefix_ipv6 "$prefix" || { echo "pin-device: prefix '$prefix' не подходит для IPv6 (0..128)" >&2; return 1; }
    fi
    printf '%s %s v6\n' "$addr" "${prefix:--}"
    return 0
  fi
  echo "pin-device: '$addr' не похож ни на IPv4, ни на IPv6" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Branch: --source-ip (host-only — must be /32 or /128 with --allow-ipv6)
# ---------------------------------------------------------------------------
final_cidr=""        # canonical "addr/prefix" passed to sing-box later
final_family=""

if [ -n "$source_ip" ]; then
  parsed="$(split_ip_prefix "$source_ip")" || exit 13
  # shellcheck disable=SC2086
  set -- $parsed
  ip_addr="$1"; ip_prefix="$2"; ip_family="$3"
  [ "$ip_prefix" = "-" ] && ip_prefix=""

  if [ "$ip_family" = "v6" ] && [ "$allow_ipv6" != "1" ]; then
    echo "pin-device: IPv6 запрещён без --allow-ipv6 ($source_ip)" >&2
    exit 13
  fi

  if [ "$ip_family" = "v4" ]; then
    # Must be host-only: prefix empty OR exactly 32.
    if [ -n "$ip_prefix" ] && [ "$ip_prefix" != "32" ]; then
      echo "pin-device: --source-ip принимает только /32 (получено /$ip_prefix). Для подсетей используй --source-cidr." >&2
      exit 13
    fi
    refuse_bogon_ipv4 "$ip_addr" || exit 13
    final_cidr="$ip_addr/32"
    final_family="v4"
  else
    # IPv6: prefix must be empty OR 128.
    if [ -n "$ip_prefix" ] && [ "$ip_prefix" != "128" ]; then
      echo "pin-device: --source-ip для IPv6 принимает только /128 (получено /$ip_prefix). Используй --source-cidr." >&2
      exit 13
    fi
    refuse_bogon_ipv6 "$ip_addr" || exit 13
    final_cidr="$ip_addr/128"
    final_family="v6"
  fi
fi

# ---------------------------------------------------------------------------
# Branch: --source-cidr (any valid CIDR; /0 + LAN-overlap need --force)
# ---------------------------------------------------------------------------
if [ -n "$source_cidr" ]; then
  # CIDR must have an explicit prefix.
  case "$source_cidr" in
    */*) ;;
    *) echo "pin-device: --source-cidr требует prefix (a.b.c.d/N)" >&2; exit 13 ;;
  esac
  parsed="$(split_ip_prefix "$source_cidr")" || exit 13
  # shellcheck disable=SC2086
  set -- $parsed
  c_addr="$1"; c_prefix="$2"; c_family="$3"
  [ "$c_prefix" = "-" ] && c_prefix=""

  if [ -z "$c_prefix" ]; then
    echo "pin-device: --source-cidr требует явный prefix" >&2
    exit 13
  fi

  if [ "$c_family" = "v6" ] && [ "$allow_ipv6" != "1" ]; then
    echo "pin-device: IPv6 CIDR запрещён без --allow-ipv6" >&2
    exit 13
  fi

  # /0 catch-all gate runs BEFORE bogon check, because the unspecified-address
  # bogon rule would otherwise reject 0.0.0.0/0 even with --force.
  if [ "$c_prefix" = "0" ]; then
    if [ "$force" != "1" ]; then
      if [ "$c_family" = "v4" ]; then
        echo "pin-device: 0.0.0.0/0 (catch-all) запрещён без --force" >&2
      else
        echo "pin-device: ::/0 (catch-all) запрещён без --force" >&2
      fi
      exit 13
    fi
    # With --force, /0 is permitted — skip per-address bogon checks.
    final_cidr="$c_addr/$c_prefix"
    final_family="$c_family"
  else
    if [ "$c_family" = "v4" ]; then
      refuse_bogon_ipv4 "$c_addr" || exit 13
    else
      refuse_bogon_ipv6 "$c_addr" || exit 13
    fi
    final_cidr="$c_addr/$c_prefix"
    final_family="$c_family"
  fi
fi

# ---------------------------------------------------------------------------
# Resolve router + SSH alive
# ---------------------------------------------------------------------------
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  echo "pin-device: SSH недоступен для '$ROUTER_ALIAS' ($ROUTER_HOST). См. bin/setup-ssh.sh --router $ROUTER_ALIAS" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# LAN-overlap detection (only for --source-cidr v4; v6 LAN detection is TBD).
# Strategy: uci get network.lan.ipaddr + netmask → derive lan_prefix → compare
# lan_network vs cidr_network. If lan ⊆ cidr → refuse unless --force.
# ---------------------------------------------------------------------------

# netmask → prefix-len (POSIX, no python). Supports common /8../30 masks.
netmask_to_prefix() {
  case "$1" in
    255.255.255.255) echo 32 ;;
    255.255.255.254) echo 31 ;;
    255.255.255.252) echo 30 ;;
    255.255.255.248) echo 29 ;;
    255.255.255.240) echo 28 ;;
    255.255.255.224) echo 27 ;;
    255.255.255.192) echo 26 ;;
    255.255.255.128) echo 25 ;;
    255.255.255.0)   echo 24 ;;
    255.255.254.0)   echo 23 ;;
    255.255.252.0)   echo 22 ;;
    255.255.248.0)   echo 21 ;;
    255.255.240.0)   echo 20 ;;
    255.255.224.0)   echo 19 ;;
    255.255.192.0)   echo 18 ;;
    255.255.128.0)   echo 17 ;;
    255.255.0.0)     echo 16 ;;
    255.254.0.0)     echo 15 ;;
    255.252.0.0)     echo 14 ;;
    255.248.0.0)     echo 13 ;;
    255.240.0.0)     echo 12 ;;
    255.224.0.0)     echo 11 ;;
    255.192.0.0)     echo 10 ;;
    255.128.0.0)     echo 9 ;;
    255.0.0.0)       echo 8 ;;
    *)               echo "" ;;
  esac
}

# ipv4_to_int <a.b.c.d> → 32-bit integer (POSIX, no python).
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<EOF
$1
EOF
  echo "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

# mask_int <prefix> — returns 32-bit mask integer for prefix 0..32.
mask_int() {
  local p="$1"
  if [ "$p" -eq 0 ]; then echo 0; return; fi
  if [ "$p" -ge 32 ]; then echo 4294967295; return; fi
  # ((1 << p) - 1) << (32 - p), but bash ints are 64-bit so this is safe.
  echo "$(( ((1 << p) - 1) << (32 - p) ))"
}

if [ -n "$source_cidr" ] && [ "$final_family" = "v4" ]; then
  lan_ip="$(ssh_run "uci -q get network.lan.ipaddr" 2>/dev/null || true)"
  lan_mask="$(ssh_run "uci -q get network.lan.netmask" 2>/dev/null || true)"

  if [ -n "$lan_ip" ] && is_ipv4 "$lan_ip"; then
    lan_prefix=""
    if [ -n "$lan_mask" ]; then
      lan_prefix="$(netmask_to_prefix "$lan_mask")"
    fi
    # Newer OpenWrt may already have CIDR-style or use ipv4-netmask in different shape.
    if [ -z "$lan_prefix" ]; then
      say "WARN: не смог распарсить LAN netmask '$lan_mask' — пропускаю LAN-overlap check"
    else
      c_addr="${final_cidr%/*}"
      c_prefix="${final_cidr#*/}"
      lan_int="$(ipv4_to_int "$lan_ip")"
      cidr_int="$(ipv4_to_int "$c_addr")"
      cidr_mask="$(mask_int "$c_prefix")"
      lan_network="$(( lan_int & cidr_mask ))"
      cidr_network="$(( cidr_int & cidr_mask ))"

      # LAN ⊆ CIDR iff (a) cidr's prefix ≤ lan's prefix and (b) lan_ip masked
      # to cidr's prefix == cidr's network.
      if [ "$c_prefix" -le "$lan_prefix" ] && [ "$lan_network" -eq "$cidr_network" ]; then
        if [ "$force" = "1" ]; then
          say "WARN: --source-cidr $final_cidr перекрывает LAN $lan_ip/$lan_prefix (продолжаю — --force)"
        else
          echo "pin-device: --source-cidr $final_cidr перекрывает LAN-сеть $lan_ip/$lan_prefix (это значит, что весь LAN, включая роутер, уйдёт в outbound). Используй --force, если уверен." >&2
          exit 13
        fi
      fi
    fi
  else
    say "WARN: не смог получить LAN ipaddr с роутера — LAN-overlap check пропущен"
  fi
fi

# ---------------------------------------------------------------------------
# Verify outbound exists in /etc/sing-box/config.json (ssh + jq).
# Tag is acceptable if it appears as .outbounds[].tag — that already covers
# selector/urltest groups (e.g. "auto-failover") because their tag is in the
# same flat array. selector_groups from _doctor_remote.sh v2 is therefore
# already a subset of this check, so no separate query needed in C.1.
# ---------------------------------------------------------------------------
remote_cfg="/etc/sing-box/config.json"

if ! ssh_run "[ -r $remote_cfg ]" >/dev/null 2>&1; then
  echo "pin-device: $remote_cfg не существует на роутере (sing-box установлен?)" >&2
  exit 2
fi

# Run jq on the router so we don't have to scp the whole config in C.1.
# Embed the tag literally inside a here-doc-style heredoc, but escape via printf %q.
outbound_q="$(printf '%q' "$outbound")"
outbound_exists="$(ssh_run "jq -r --arg t $outbound_q '[.outbounds[]?.tag] | index(\$t) | tostring' $remote_cfg" 2>/dev/null || true)"

case "$outbound_exists" in
  null|"")
    echo "pin-device: outbound '$outbound' не найден в $remote_cfg (проверь bin/doctor.sh --router $ROUTER_ALIAS)" >&2
    exit 13
    ;;
  *)
    : # found
    ;;
esac

# ---------------------------------------------------------------------------
# C.1 done — summary & placeholder for C.2.
# ---------------------------------------------------------------------------
say "router=$ROUTER_ALIAS outbound=$outbound source=$final_cidr family=$final_family force=$force writer=$writer"
echo "pin-device.sh: C.1 prep done (CLI + validation + outbound verify OK). Apply pipeline lands in C.2."

# === C.2 starts here ===
# C.2 scope: pre-backup, install-state preflight + ownership expand, drift detection,
#            idempotency / conflict on existing pin, jq mutation of route.rules
#            (insert BEFORE auto-failover catch-all), sing-box check, atomic mv.
# Compatibility note: the canonical pinned-source value used both here (config.json
# jq edit) and in C.3 (nft rule comment marker) is exposed as $source_value. It is
# already-normalised in C.1 as $final_cidr ("addr/prefix"). $family mirrors
# $final_family but uses ipv4/ipv6 spelling that the rest of the script (and C.3
# nft layer) expects.
source_value="$final_cidr"
case "$final_family" in
  v4) family="ipv4" ;;
  v6) family="ipv6" ;;
  *)  echo "pin-device: internal: unknown family '$final_family'" >&2; exit 13 ;;
esac

# shellcheck source=../lib/install-state-remote.sh
. "$SKILL_HOME/lib/install-state-remote.sh"

if ! ensure_router_lib_deployed; then
  echo "pin-device: не смог задеплоить lib/*.sh на роутер — CAS недоступен." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# C.2.1 — Pre-backup (skipped only with --no-backup; failure is fatal).
# backup-now.sh emits the snapshot ID on stdout (last line); tail -n1 isolates
# it from any --quiet leakage.
# ---------------------------------------------------------------------------
snapshot_id=""
if [ "$no_backup" = "1" ]; then
  snapshot_id="(no-backup)"
  say "WARN: --no-backup задан — restore.sh не сможет откатить config.json"
else
  if [ ! -x "$SKILL_HOME/bin/backup-now.sh" ]; then
    echo "pin-device: backup-now.sh не найден или не исполняем — отказываюсь продолжать без снапшота" >&2
    exit 2
  fi
  if ! snapshot_id="$("$SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" --label "before pin-device $source_value to $outbound" --quiet | tail -n1)"; then
    echo "pin-device: backup-now.sh failed — отмена" >&2
    exit 2
  fi
  if [ -z "$snapshot_id" ]; then
    echo "pin-device: backup-now.sh не вернул snapshot id — отмена" >&2
    exit 2
  fi
fi

# rollback_via_restore — restore from the pre-backup snapshot when post-mutation
# atomicity guarantees fail. Mirrors add-vpn.sh rollback_inline contract.
rollback_via_restore() {
  [ -z "$snapshot_id" ] && return 0
  [ "$snapshot_id" = "(no-backup)" ] && {
    echo "pin-device: rollback невозможен — запуск был с --no-backup" >&2
    return 0
  }
  echo "pin-device: пытаюсь откатить из snapshot $snapshot_id ..." >&2
  if [ -x "$SKILL_HOME/bin/restore.sh" ]; then
    "$SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" --snapshot "$snapshot_id" --force >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# C.2.2 — install-state preflight + ownership expand.
# pin-device requires install-state.json present (router must be adopted or
# installed via install-vpn). We expand files_owned_by_skill to include
# /etc/sing-box/config.json BEFORE mutation so a mid-flight crash leaves the
# state consistent with the file we're about to rewrite.
# ---------------------------------------------------------------------------
state_rev=""
if ! state_rev="$(remote_read_revision)"; then
  echo "pin-device: не смог прочитать install-state revision (rc=$?). Запусти bin/adopt.sh --router $ROUTER_ALIAS либо bin/install-vpn.sh." >&2
  exit 13
fi
if [ "$state_rev" = "0" ]; then
  echo "pin-device: install-state.json отсутствует на роутере — сначала bin/install-vpn.sh или bin/adopt.sh --router $ROUTER_ALIAS" >&2
  exit 13
fi

state_json=""
if ! state_json="$(remote_read_state_json)"; then
  echo "pin-device: не смог прочитать install-state.json (rc=$?)" >&2
  exit 13
fi

# Ownership expand: add config.json to files_owned_by_skill if absent.
needs_expand="$(printf '%s' "$state_json" | jq -r '
  (.files_owned_by_skill // []) as $o
  | if ($o | index("/etc/sing-box/config.json")) then "no" else "yes" end
' 2>/dev/null || echo "yes")"

if [ "$needs_expand" = "yes" ]; then
  expand_payload="$(printf '%s' "$state_json" | jq '
    del(._revision, ._last_writer, ._last_writer_host, ._last_updated_at)
    | .files_owned_by_skill =
        ((.files_owned_by_skill // []) + ["/etc/sing-box/config.json"] | unique)
  ')"
  if [ -z "$expand_payload" ]; then
    echo "pin-device: не смог собрать payload для ownership-expand" >&2
    exit 13
  fi
  new_rev=""
  if ! new_rev="$(remote_cas_write "$writer" "$state_rev" "$expand_payload" 2>&1)"; then
    cas_rc=$?
    case "$cas_rc" in
      11) echo "pin-device: install-state CAS STALE на ownership-expand — повтори (другой writer обновил state). Stdout: $new_rev" >&2 ;;
      12) echo "pin-device: install-state LOCK contention на ownership-expand — повтори. Stdout: $new_rev" >&2 ;;
      13) echo "pin-device: install-state VALIDATION на ownership-expand. Stdout: $new_rev" >&2 ;;
      *)  echo "pin-device: install-state CAS rc=$cas_rc на ownership-expand. Stdout: $new_rev" >&2 ;;
    esac
    exit 11
  fi
  state_rev="$new_rev"
  # Re-read so subsequent reads see the expanded state (and any other field
  # that state-write.sh stamped).
  if ! state_json="$(remote_read_state_json)"; then
    echo "pin-device: re-read state.json после ownership-expand упал" >&2
    exit 13
  fi
  say "ownership-expand committed (state revision=$state_rev): /etc/sing-box/config.json now in files_owned_by_skill"
fi

# ---------------------------------------------------------------------------
# C.2.3 — Drift detection.
# If adopt.sh recorded adopted_config_sha256["/etc/sing-box/config.json"], the
# current file on the router MUST match unless --force. Drift means a human
# edited config.json out-of-band and pin-device.sh's mutation would clobber it.
# ---------------------------------------------------------------------------
adopted_sha="$(printf '%s' "$state_json" | jq -r '
  .adopted_config_sha256["/etc/sing-box/config.json"] // empty
' 2>/dev/null || true)"

if [ -n "$adopted_sha" ] && [ "$adopted_sha" != "null" ]; then
  current_sha="$(ssh_run "sha256sum /etc/sing-box/config.json 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
  if [ -z "$current_sha" ]; then
    echo "pin-device: не смог посчитать sha256 /etc/sing-box/config.json на роутере" >&2
    exit 30
  fi
  if [ "$adopted_sha" != "$current_sha" ]; then
    if [ "$force" = "1" ]; then
      say "WARN: config.json drifted с момента adopt (adopted=$adopted_sha current=$current_sha) — --force продолжаю"
    else
      echo "pin-device: drift detected — /etc/sing-box/config.json изменён вне скилла с момента adopt." >&2
      echo "  adopted_sha256: $adopted_sha" >&2
      echo "  current_sha256: $current_sha" >&2
      echo "  Запусти bin/adopt.sh --router $ROUTER_ALIAS чтобы зафиксировать новое состояние, либо --force чтобы продолжить." >&2
      exit 30
    fi
  fi
fi

# ---------------------------------------------------------------------------
# C.2.4 — Download config.json + idempotency / conflict check.
# Rule shape we manage:
#   { action:"route", source_ip_cidr:[<src>], outbound:<tag> }
# Idempotent: existing rule with same source AND same outbound → exit 0, no-op.
# Conflict:   existing rule with same source but DIFFERENT outbound →
#             - without --force: exit 13.
#             - with --force: the jq mutation below removes the conflicting
#               rule before inserting the new one (single-source-of-truth).
# ---------------------------------------------------------------------------
local_cfg="$(mktemp -t openwrt-skill-pin-cfg.XXXXXX)"
local_new_cfg="$(mktemp -t openwrt-skill-pin-cfgnew.XXXXXX)"
trap 'rm -f "$local_cfg" "$local_new_cfg"' EXIT INT TERM

if ! scp_from "$remote_cfg" "$local_cfg" >/dev/null 2>&1; then
  echo "pin-device: не смог получить $remote_cfg с роутера" >&2
  exit 2
fi

if ! jq -e 'type == "object"' "$local_cfg" >/dev/null 2>&1; then
  echo "pin-device: $remote_cfg не парсится как JSON — exit 13. Запусти doctor." >&2
  exit 13
fi

# Find a pin-rule that matches our source. A rule is treated as a "pin" only if
# its source_ip_cidr contains exactly our $source_value AND it has no domain*/
# rule_set/inbound matchers (those belong to other features).
match_outbound="$(jq -r --arg src "$source_value" '
  (.route.rules // [])
  | map(select(
      ((.source_ip_cidr // []) | index($src))
      and ((.domain // null) == null)
      and ((.domain_suffix // null) == null)
      and ((.domain_keyword // null) == null)
      and ((.domain_regex // null) == null)
      and ((.rule_set // null) == null)
      and ((.inbound // null) == null)
    ))
  | (.[0].outbound // empty)
' "$local_cfg" 2>/dev/null || true)"

if [ -n "$match_outbound" ]; then
  if [ "$match_outbound" = "$outbound" ]; then
    say "idempotent: $source_value → $outbound уже зафиксирован в config.json — пропускаю config.json mutation"
    # Skip jq mutation; we still leave $local_new_cfg empty so the "no-op"
    # branch below knows not to scp/check/mv.
    config_changed=0
  else
    if [ "$force" != "1" ]; then
      echo "pin-device: $source_value уже привязан к outbound '$match_outbound' (не '$outbound'). Используй --force чтобы переписать." >&2
      exit 13
    fi
    say "WARN: --force перепишет существующий pin: $source_value: $match_outbound -> $outbound"
    config_changed=1
  fi
else
  config_changed=1
fi

# ---------------------------------------------------------------------------
# C.2.5 — jq mutation: insert pin rule BEFORE the auto-failover catch-all.
# Strategy: split .route.rules into (head, tail) where tail starts at the first
# "catch-all" rule (a rule with no specific matchers — i.e. it would match
# every connection). If no catch-all exists, append to the end. With --force
# we also drop any existing pin-rule for the same source_value (handled via
# the same `select` predicate from the idempotency check).
# ---------------------------------------------------------------------------
if [ "$config_changed" = "1" ]; then
  jq_failed=0
  jq \
    --arg src "$source_value" \
    --arg tag "$outbound" \
    '
      (.route = (.route // {}))
      | (.route.rules = (.route.rules // []))

      # 1. Drop any existing pin-rule for this exact source (force-overwrite or
      #    just preemptive dedup before re-insert). A "pin-rule" is the same
      #    narrow shape we look for in idempotency check.
      | .route.rules = (
          .route.rules
          | map(select(
              ((.source_ip_cidr // []) | index($src) | not)
              or ((.domain // null) != null)
              or ((.domain_suffix // null) != null)
              or ((.domain_keyword // null) != null)
              or ((.domain_regex // null) != null)
              or ((.rule_set // null) != null)
              or ((.inbound // null) != null)
            ))
        )

      # 2. Find insertion index = position of first catch-all rule. A catch-all
      #    is a route-action rule with NO matchers at all (no domain*, no
      #    ip_cidr, no source_ip_cidr, no rule_set, no inbound, no process_*).
      | (.route.rules) as $rules
      | ($rules | length) as $n
      | ([
          range(0; $n) as $i
          | ($rules[$i]) as $r
          | (
              ($r.domain         // null) == null
              and ($r.domain_suffix  // null) == null
              and ($r.domain_keyword // null) == null
              and ($r.domain_regex   // null) == null
              and ($r.ip_cidr        // null) == null
              and ($r.source_ip_cidr // null) == null
              and ($r.rule_set       // null) == null
              and ($r.inbound        // null) == null
              and ($r.process_name   // null) == null
              and ($r.process_path   // null) == null
              and ($r.network        // null) == null
              and ($r.protocol       // null) == null
              and ($r.port           // null) == null
              and (($r.action // "route") == "route")
            ) as $is_catchall
          | if $is_catchall then $i else empty end
        ] | first) as $insert_at_raw
      | (if $insert_at_raw == null then $n else $insert_at_raw end) as $insert_at

      # 3. Splice the new pin-rule in.
      | .route.rules = (
          ($rules[:$insert_at])
          + [{ action: "route", source_ip_cidr: [$src], outbound: $tag }]
          + ($rules[$insert_at:])
        )
    ' "$local_cfg" > "$local_new_cfg" || jq_failed=1

  if [ "$jq_failed" = "1" ] || ! jq -e 'type == "object" and (.route.rules | type == "array")' "$local_new_cfg" >/dev/null 2>&1; then
    echo "pin-device: jq не смог собрать новый config.json" >&2
    rollback_via_restore
    exit 13
  fi

  # ---------------------------------------------------------------------------
  # C.2.6 — sing-box check on router (staged, /tmp temp file).
  # If check fails we DO NOT touch the live config.json. Ownership-expand
  # already committed to state — that's fine: we own the file we plan to
  # write, we just haven't written it yet. No rollback of state is needed.
  # ---------------------------------------------------------------------------
  remote_new="/tmp/openwrt-skill-pin-config.$$.json"
  if ! scp_to "$local_new_cfg" "$remote_new" >/dev/null 2>&1; then
    echo "pin-device: scp нового config.json упал" >&2
    rollback_via_restore
    exit 2
  fi

  if ! ssh_run "sing-box check -c $remote_new" >/dev/null 2>&1; then
    echo "pin-device: 'sing-box check' зафейлился на новом config'е — отмена" >&2
    ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
    rollback_via_restore
    exit 13
  fi

  # ---------------------------------------------------------------------------
  # C.2.7 — Atomic mv: rename temp file over live config.json.
  # If this fails after sing-box check succeeded, rollback is the safest path
  # because we don't know whether the rename was partial.
  # ---------------------------------------------------------------------------
  if ! ssh_run "chmod 644 $remote_new && mv -f $remote_new $remote_cfg" >/dev/null 2>&1; then
    echo "pin-device: не смог mv $remote_new -> $remote_cfg" >&2
    ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
    rollback_via_restore
    exit 2
  fi
  say "config.json updated (atomic mv): $source_value -> $outbound inserted before catch-all"
else
  say "config.json не менялся (idempotent no-op)"
fi

# Clean trap — local tempfiles can go; from here on we don't reference them.
rm -f "$local_cfg" "$local_new_cfg"
trap - EXIT INT TERM

echo "pin-device.sh: C.2 prep done (config.json edit OK, sing-box check passed)."
# Variables ready for C.3: $snapshot_id, $state_rev, $source_value, $outbound,
#                          $family, $force, $writer, $config_changed
# === C.3 starts here ===
# C.3 scope: persistent nft layer in /etc/init.d/sing-box-tproxy + runtime
# insert + install-state.dynamic_additions update.
#
# Strategy:
#   - Idempotency via NFT rule comment "vpn-kit-pin-<sha256(src)[:12]>". Both the
#     persistent line in init.d and the runtime rule carry this comment, so
#     re-runs can locate and replace by *handle resolution from comment* — not
#     by line/position number.
#   - Persistent: parse FakeIP line (regex `(198\.18|fakeip).*tproxy`), insert
#     pin line right before it, atomic mv.
#   - Runtime: delete-by-comment + insert-before-FakeIP-handle (so the order
#     persistent==runtime).
#   - CAS retry x3 for install-state.dynamic_additions[].
#
# C.4 will then restart sing-box-tproxy, watch reachability with auto-rollback
# via $snapshot_id, and append memory journal + pins.md entries.

# C.3 short-circuit: if C.2 didn't actually change config.json, the (source ->
# outbound) mapping is already pinned. We don't want to touch nft / init.d in
# this case — idempotent no-op preserves the existing comment-tagged rule.
c3_skipped=0
if [ "${config_changed:-0}" = "0" ]; then
  echo "pin-device: C.3 skipped (config no-op)"
  c3_skipped=1
fi

if [ "$c3_skipped" = "0" ]; then

# rollback_pin — used by every fatal-after-mutation branch below. Restores from
# pre-backup snapshot ($snapshot_id) and best-effort cleans the runtime nft rule
# carrying our comment. The init.d file is reverted by restore.sh.
rollback_pin() {
  local reason="$1"
  if [ "$no_backup" = "1" ]; then
    echo "pin-device: rollback skipped (--no-backup): $reason" >&2
    return 0
  fi
  if [ -n "${snapshot_id:-}" ] && [ "$snapshot_id" != "(no-backup)" ]; then
    echo "pin-device: rollback ($reason) via snapshot $snapshot_id ..." >&2
    "$SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" --snapshot "$snapshot_id" --force >/dev/null 2>&1 || true
  fi
  if [ -n "${pin_id:-}" ]; then
    # Best-effort runtime cleanup. Resolve handles for any rule carrying our
    # comment and delete them. We don't fail the rollback if this errors.
    ssh_run "
      for h in \$(nft -a list chain inet sing_box_tproxy mangle_prerouting 2>/dev/null | awk '/$pin_id/ {for(i=1;i<=NF;i++)if(\$i==\"handle\")print \$(i+1)}'); do
        nft delete rule inet sing_box_tproxy mangle_prerouting handle \$h 2>/dev/null
      done
    " >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# C.3.1 — Pull /etc/init.d/sing-box-tproxy and parse the FakeIP rule.
# ---------------------------------------------------------------------------
local_init_script="$(mktemp -t openwrt-skill-pin-init.XXXXXX)"
trap 'rm -f "$local_init_script" "$local_init_script.bak"' EXIT INT TERM

if ! scp_from "/etc/init.d/sing-box-tproxy" "$local_init_script" >/dev/null 2>&1; then
  echo "pin-device: не смог scp /etc/init.d/sing-box-tproxy с роутера" >&2
  rollback_pin "scp init.d"
  exit 2
fi

# Locate FakeIP rule. We accept either the 198.18/15 redirect destination or an
# explicit `vpn-kit-fakeip` marker — install-vpn.sh sets up both shapes across
# versions.
fakeip_line="$(grep -nE '(198\.18|fakeip).*tproxy' "$local_init_script" | head -1)"
if [ -z "$fakeip_line" ]; then
  echo "pin-device: FakeIP-правило не найдено в /etc/init.d/sing-box-tproxy — incompatible layout" >&2
  rollback_pin "fakeip layout"
  exit 13
fi

fakeip_count="$(grep -cE '(198\.18|fakeip).*tproxy' "$local_init_script")"
if [ "$fakeip_count" -gt 1 ]; then
  echo "pin-device: найдено $fakeip_count FakeIP-правил — ambiguous layout, отказ" >&2
  rollback_pin "fakeip ambiguous"
  exit 13
fi

tproxy_port="$(printf '%s' "$fakeip_line" | grep -oE '127\.0\.0\.1:[0-9]+' | head -1)"
if [ -z "$tproxy_port" ]; then
  echo "pin-device: не смог распарсить tproxy port из FakeIP-правила" >&2
  rollback_pin "fakeip parse"
  exit 13
fi

fakeip_lineno="$(printf '%s' "$fakeip_line" | cut -d: -f1)"
if ! printf '%s' "$fakeip_lineno" | grep -qE '^[0-9]+$'; then
  echo "pin-device: внутренняя ошибка — не получил line number FakeIP-правила" >&2
  rollback_pin "fakeip lineno"
  exit 13
fi

# ---------------------------------------------------------------------------
# C.3.2 — Build pin rule + family-specific guards.
# Comment-based idempotency token. sha256sum is POSIX-portable across macOS
# (with `brew install coreutils` or system `shasum`) and OpenWRT busybox. We
# fall back to shasum -a 256 if sha256sum is absent (macOS dev hosts).
# ---------------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  pin_hash="$(printf '%s' "$source_value" | sha256sum | cut -c1-12)"
else
  pin_hash="$(printf '%s' "$source_value" | shasum -a 256 | cut -c1-12)"
fi
pin_id="vpn-kit-pin-$pin_hash"

case "$family" in
  ipv4) nft_saddr="ip saddr" ;;
  ipv6)
    nft_saddr="ip6 saddr"
    # The current init.d FakeIP rule is IPv4-only. If we don't see an ip6 chain
    # / ip6 saddr already wired in, refuse rather than insert an orphan rule
    # that won't match anything.
    if ! grep -qE 'ip6 saddr|ip6 daddr' "$local_init_script"; then
      echo "pin-device: family=ipv6, но init.d/sing-box-tproxy не содержит ip6-правил — отказ" >&2
      rollback_pin "ipv6 unsupported layout"
      exit 13
    fi
    ;;
  *)
    echo "pin-device: внутренняя ошибка — неизвестный family '$family'" >&2
    rollback_pin "family"
    exit 13
    ;;
esac

nft_rule_body="iifname br-lan $nft_saddr $source_value meta l4proto { tcp, udp } meta mark set 0x100000 tproxy ip to $tproxy_port accept comment \"$pin_id\""

# ---------------------------------------------------------------------------
# C.3.3 — Idempotent patch of init.d/sing-box-tproxy.
# Comment-based dedup: drop any line carrying our pin_id, then insert the
# fresh line BEFORE the FakeIP line. sed used in POSIX form so the same
# expression is identical to what would run on the router (busybox sed).
# ---------------------------------------------------------------------------
# Detect GNU vs BSD sed in-place semantics — both with `-i.bak` work uniformly.
sed -i.bak "/comment \"$pin_id\"/d" "$local_init_script" || {
  echo "pin-device: sed dedup на init.d упал" >&2
  rollback_pin "sed dedup"
  exit 2
}

# Re-locate FakeIP line — dedup above may have shifted line numbers if a stale
# pin line existed above the FakeIP line.
fakeip_lineno="$(grep -nE '(198\.18|fakeip).*tproxy' "$local_init_script" | head -1 | cut -d: -f1)"
if [ -z "$fakeip_lineno" ]; then
  echo "pin-device: FakeIP-правило исчезло после dedup — внутренняя ошибка" >&2
  rollback_pin "fakeip postdedup"
  exit 13
fi

# Insert. The `i\` form is POSIX (busybox sed на роутере поддерживает). Тело
# правила приходит inline — все спецсимволы регекспа уже экранированы (только
# user-controlled `$source_value` уже прошёл валидацию в C.1 как CIDR).
init_patch_tmp="$(mktemp -t openwrt-skill-pin-init-new.XXXXXX)"
awk -v ln="$fakeip_lineno" -v body="$nft_rule_body" '
  NR == ln { printf "\tnft '\''add rule inet sing_box_tproxy mangle_prerouting %s'\''\n", body }
  { print }
' "$local_init_script" > "$init_patch_tmp" || {
  echo "pin-device: awk insert на init.d упал" >&2
  rm -f "$init_patch_tmp"
  rollback_pin "awk insert"
  exit 2
}

# Sanity: pin line должна быть строго перед fakeip line.
if ! grep -qF "$pin_id" "$init_patch_tmp"; then
  echo "pin-device: pin-строка не появилась в патченом init.d — отмена" >&2
  rm -f "$init_patch_tmp"
  rollback_pin "patch verify"
  exit 2
fi

mv -f "$init_patch_tmp" "$local_init_script"
rm -f "$local_init_script.bak"

# ---------------------------------------------------------------------------
# C.3.4 — Atomic mv on the router.
# ---------------------------------------------------------------------------
remote_init_new="/tmp/openwrt-skill-pin-init.$$.sh"
if ! scp_to "$local_init_script" "$remote_init_new" >/dev/null 2>&1; then
  echo "pin-device: scp нового init.d на роутер упал" >&2
  rollback_pin "scp init.d new"
  exit 2
fi
if ! ssh_run "chmod 755 $remote_init_new && mv -f $remote_init_new /etc/init.d/sing-box-tproxy" >/dev/null 2>&1; then
  echo "pin-device: не смог mv $remote_init_new -> /etc/init.d/sing-box-tproxy" >&2
  ssh_run "rm -f $remote_init_new" >/dev/null 2>&1 || true
  rollback_pin "mv init.d"
  exit 2
fi
say "init.d/sing-box-tproxy patched (pin_id=$pin_id, tproxy_port=$tproxy_port)"

# ---------------------------------------------------------------------------
# C.3.5 — Runtime nft: delete-by-comment, then insert before FakeIP handle.
# Position is the FakeIP rule's handle; `nft insert` semantics place the new
# rule BEFORE that handle, which matches the persistent order.
# ---------------------------------------------------------------------------
# Best-effort delete of any existing rule carrying our pin_id (multi-handle safe).
ssh_run "
  for h in \$(nft -a list chain inet sing_box_tproxy mangle_prerouting 2>/dev/null | awk '/$pin_id/ {for(i=1;i<=NF;i++)if(\$i==\"handle\")print \$(i+1)}'); do
    nft delete rule inet sing_box_tproxy mangle_prerouting handle \$h 2>/dev/null
  done
" >/dev/null 2>&1 || true

# Locate FakeIP rule handle.
fakeip_handle="$(ssh_run "nft -a list chain inet sing_box_tproxy mangle_prerouting 2>/dev/null | grep -E '(198\.18|fakeip).*tproxy' | grep -oE 'handle [0-9]+' | awk '{print \$2}' | head -1" 2>/dev/null || true)"
if [ -z "$fakeip_handle" ] || ! printf '%s' "$fakeip_handle" | grep -qE '^[0-9]+$'; then
  echo "pin-device: не нашёл runtime handle FakeIP-правила в chain inet sing_box_tproxy mangle_prerouting" >&2
  rollback_pin "fakeip runtime missing"
  exit 30
fi

# Insert before FakeIP handle. nft "insert ... position H ..." means: place
# immediately before rule with handle H.
if ! ssh_run "nft insert rule inet sing_box_tproxy mangle_prerouting position $fakeip_handle $nft_rule_body" >/dev/null 2>&1; then
  echo "pin-device: nft insert упал (handle=$fakeip_handle)" >&2
  rollback_pin "nft insert"
  exit 30
fi

# ---------------------------------------------------------------------------
# C.3.6 — Verify pin rule is visible at runtime carrying our comment.
# ---------------------------------------------------------------------------
verify="$(ssh_run "nft -a list chain inet sing_box_tproxy mangle_prerouting 2>/dev/null | grep -F '$pin_id' | head -1" 2>/dev/null || true)"
if [ -z "$verify" ]; then
  echo "pin-device: pin-правило не видно в nft list после insert — отмена" >&2
  rollback_pin "verify"
  exit 30
fi
say "nft pin rule inserted at runtime (handle resolves via comment $pin_id)"

# ---------------------------------------------------------------------------
# C.3.7 — CAS write of install-state.dynamic_additions[].
# Retry x3 on STALE: re-read latest revision/state, dedup by id, append.
# We don't fail the whole operation on persistent CAS failure (config.json +
# runtime + init.d already applied — undoing them would create more drift than
# a stale state file). We log a warning and continue.
# ---------------------------------------------------------------------------
added_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

build_payload() {
  local in_state="$1"
  printf '%s' "$in_state" | jq \
    --arg id "$pin_id" \
    --arg src "$source_value" \
    --arg tag "$outbound" \
    --arg added_at "$added_at" \
    --arg port "$tproxy_port" \
    --arg family "$family" \
    '
    del(._revision, ._last_writer, ._last_writer_host, ._last_updated_at)
    | .dynamic_additions = (
        (.dynamic_additions // [])
        | map(select(.id != $id))
        | . + [{
            id: $id,
            type: "lan_client",
            value: $src,
            family: $family,
            outbound: $tag,
            tproxy_port: $port,
            added_at: $added_at,
            origin: "claude-code",
            persisted_in: "/etc/init.d/sing-box-tproxy",
            config_ref: ("sing-box.route.rules[outbound=" + $tag + "]")
          }]
      )
    '
}

fresh_rev="$state_rev"
fresh_state="$state_json"
cas_attempt=1
cas_ok=0
final_rev="$state_rev"
while [ "$cas_attempt" -le 3 ]; do
  # Re-read latest before each attempt — C.2 ownership-expand bumped the rev,
  # and another writer might have moved on since.
  if ! fresh_rev="$(remote_read_revision)"; then
    echo "pin-device: WARN: CAS re-read revision упал (attempt $cas_attempt)" >&2
    cas_attempt=$((cas_attempt + 1))
    continue
  fi
  if ! fresh_state="$(remote_read_state_json)"; then
    echo "pin-device: WARN: CAS re-read state.json упал (attempt $cas_attempt)" >&2
    cas_attempt=$((cas_attempt + 1))
    continue
  fi
  cas_payload="$(build_payload "$fresh_state")"
  if [ -z "$cas_payload" ]; then
    echo "pin-device: WARN: build_payload вернул пусто (attempt $cas_attempt)" >&2
    cas_attempt=$((cas_attempt + 1))
    continue
  fi
  if new_rev="$(remote_cas_write "$writer" "$fresh_rev" "$cas_payload" 2>/dev/null)"; then
    cas_ok=1
    final_rev="$new_rev"
    break
  fi
  cas_attempt=$((cas_attempt + 1))
done

if [ "$cas_ok" = "1" ]; then
  state_rev="$final_rev"
  say "install-state.dynamic_additions updated (revision=$state_rev, id=$pin_id)"
else
  # Persistent + runtime + config.json all in place. Don't rollback — that
  # would clobber a valid mutation. Warn instead.
  echo "pin-device: WARN: install-state CAS зафейлился 3 раза — state desync (config.json + init.d + runtime nft применены; запиши вручную или перезапусти pin-device для re-sync)" >&2
fi

# ---------------------------------------------------------------------------
# C.3.8 — Journal entry (memory/<alias>/pins.md остаётся territory of C.4).
# ---------------------------------------------------------------------------
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"
memory_journal_append "$ROUTER_ALIAS" "pin_device" \
  "source_ip=$source_value" \
  "outbound=$outbound" \
  "snapshot_before=$snapshot_id" \
  "pin_id=$pin_id" \
  "tproxy_port=$tproxy_port" \
  "revision=$state_rev" \
  || echo "pin-device: WARN: memory_journal_append зафейлился (не критично)" >&2

# Clean local tempfiles.
rm -f "$local_init_script" "$local_init_script.bak"
trap - EXIT INT TERM

echo "pin-device.sh: C.3 prep done (nft layer in place, install-state updated)."

# ---------------------------------------------------------------------------
# C.4.1 — Staged restart of sing-box-tproxy with reachability watch.
# Symmetric to bin/add-vpn.sh:540-566. On restart-fail or SSH-loss within 30s
# we trigger rollback_pin (which restores snapshot + cleans runtime nft rule).
# Skipped entirely when c3_skipped=1 (config.json + nft were no-ops — nothing
# to restart on).
# ---------------------------------------------------------------------------
echo "pin-device: applying restart of sing-box-tproxy ..."

restart_failed=0
ssh_run "/etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1 || restart_failed=1

# Poll SSH reachability for 30s. Symmetric with add-vpn.sh.
reachable=0
end=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$end" ]; do
  if ssh_check_alive 3; then
    reachable=1
    break
  fi
  sleep 2
done

if [ "$restart_failed" = "1" ] || [ "$reachable" != "1" ]; then
  echo "pin-device: restart/reachability fail — катываем (если SSH потерян, rollback может потребовать ручного вмешательства: console/IPMI + bin/restore.sh --snapshot $snapshot_id)" >&2
  rollback_pin "reachability lost"
  exit 20
fi

# Quick sanity: sing-box процесс жив.
if ! ssh_run "/etc/init.d/sing-box-tproxy status >/dev/null 2>&1 || pgrep -f sing-box >/dev/null" >/dev/null 2>&1; then
  echo "pin-device: sing-box не запустился после restart — катываем" >&2
  rollback_pin "sing-box not running"
  exit 20
fi

say "sing-box-tproxy restarted, reachability OK"

fi  # end "if [ \"$c3_skipped\" = \"0\" ]" — C.3+C.4 main body

# ---------------------------------------------------------------------------
# C.4.2 — Render memory/<alias>/pins.md from install-state.dynamic_additions.
# Runs for BOTH c3_skipped=0 (mutations applied) and c3_skipped=1 (no-op —
# state on the router already has the pin, just refresh local view). Failures
# here are non-fatal: mutations on the router already succeeded.
# ---------------------------------------------------------------------------
render_pins_md() {
  local mem_dir="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"
  local pins_md="$mem_dir/pins.md"
  local tpl="$SKILL_HOME/memory/_templates/pins.md"

  mkdir -p "$mem_dir" 2>/dev/null || {
    say "pins.md: не могу создать $mem_dir (write-protect?) — пропускаю render"
    return 0
  }

  # shellcheck source=../lib/template-render.sh
  . "$SKILL_HOME/lib/template-render.sh"

  # Re-read post-CAS state so we pick up the just-added pin (or stable state
  # in the c3_skipped path).
  local post_state rows iso
  if ! post_state="$(remote_read_state_json)"; then
    say "pins.md: re-read state не удался — пропускаю render"
    return 0
  fi
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Build rows from dynamic_additions[type=lan_client]. Scope is "device"
  # for /32 (or bare IPv4 without slash) and "subnet" otherwise.
  rows="$(printf '%s' "$post_state" | jq -r '
    .dynamic_additions // []
    | map(select(.type == "lan_client"))
    | sort_by(.added_at // "")
    | map(
        (.value // "-") as $v
        | (if ($v | endswith("/32")) or
              (($v | contains("/")) | not) and (($v | contains(":")) | not)
           then "device" else "subnet" end) as $scope
        | "| \($v) "
        + "| \($scope) "
        + "| \(.outbound // "-") "
        + "| \(.id // "-") "
        + "| \(.added_at // "-") "
        + "| \(.origin // "-") |"
      )
    | join("\n")
  ' 2>/dev/null)" || rows=""

  if [ -z "$rows" ]; then
    rows="_(пока пусто — добавь через bin/pin-device.sh)_"
  fi

  # Targeted placeholder substitution if the template-placeholder is still
  # present; in-place table-body replace if the file is already real; fresh
  # render otherwise.
  if [ -f "$pins_md" ] && grep -qF '{{PIN_TABLE_ROWS}}' "$pins_md"; then
    local tmp; tmp="$(mktemp -t openwrt-skill-pins.XXXXXX)" || return 0
    SUB="$rows" awk '
      BEGIN { sub_val = ENVIRON["SUB"] }
      {
        if (index($0, "{{PIN_TABLE_ROWS}}") > 0) { print sub_val } else { print }
      }
    ' "$pins_md" > "$tmp" && mv "$tmp" "$pins_md" || rm -f "$tmp"
  elif [ -f "$pins_md" ]; then
    local tmp; tmp="$(mktemp -t openwrt-skill-pins.XXXXXX)" || return 0
    SUB="$rows" awk '
      BEGIN { in_tbl = 0; emitted = 0; sub_val = ENVIRON["SUB"] }
      /^\| Source \| Scope \|/ { print; getline; print; in_tbl = 1; next }
      in_tbl == 1 && /^\|/ { next }
      in_tbl == 1 && !/^\|/ && !emitted { print sub_val; emitted = 1; in_tbl = 0; print; next }
      { print }
      END { if (in_tbl == 1 && !emitted) print sub_val }
    ' "$pins_md" > "$tmp" && mv "$tmp" "$pins_md" || rm -f "$tmp"
  elif [ -f "$tpl" ]; then
    render_template "$tpl" "$pins_md" \
      "ROUTER_ALIAS=$ROUTER_ALIAS" \
      "LAST_UPDATED_ISO=$iso" \
      "PIN_TABLE_ROWS=$rows" \
      "NOTES=" 2>/dev/null || \
      say "pins.md: render_template упал — пропускаю"
  else
    say "pins.md: template $tpl отсутствует — пропускаю render"
  fi
}

render_pins_md || say "pins.md: render не удался (не критично)"

# ---------------------------------------------------------------------------
# C.4.3 — Final summary.
# ---------------------------------------------------------------------------
if [ "$c3_skipped" = "1" ]; then
  say "pin-device: $source_value → $outbound уже зафиксирован (no-op); pins.md refreshed."
else
  say "pin-device: $source_value → $outbound applied and persisted (snapshot=${snapshot_id:-(skipped)})."
fi

echo "pin-device.sh: done."
exit 0
