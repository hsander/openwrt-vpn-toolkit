#!/usr/bin/env bash
# bin/unpin-device.sh — remove a LAN device pin created by bin/pin-device.sh.
#
# Reverses pin-device.sh:
#   * removes route.rules[] entry with matching source_ip_cidr from config.json
#   * removes persistent nft rule (vpn-kit-pin-* comment) from init.d script
#   * removes entry from install-state.json dynamic_additions[]
#   * restarts sing-box-tproxy
#
# Usage:
#   bin/unpin-device.sh --router <alias> --source-ip <ip> [--no-backup]
#   bin/unpin-device.sh --router <alias> --source-cidr <cidr> [--no-backup]
#
# Exit codes:
#   0   ok (also if pin wasn't found — idempotent)
#   2   router not found / SSH unreachable
#  13   validation error
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

usage() {
  cat >&2 <<'EOF'
Usage: bin/unpin-device.sh --router <alias> --source-ip <ip> [--no-backup]
       bin/unpin-device.sh --router <alias> --source-cidr <cidr> [--no-backup]

Снимает pin LAN-устройства, созданный bin/pin-device.sh.

Options:
  --router <alias>       alias из memory/routers.yaml (обяз.)
  --source-ip <ip>       IPv4-адрес (a.b.c.d) — будет нормализован до /32
  --source-cidr <cidr>   IPv4 CIDR (a.b.c.d/N)
  --no-backup            (только для тестов) пропустить pre-backup
EOF
  exit 64
}

router=""
source_ip=""
source_cidr=""
no_backup=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router)     router="${2:-}"; shift 2 ;;
    --source-ip)  source_ip="${2:-}"; shift 2 ;;
    --source-cidr) source_cidr="${2:-}"; shift 2 ;;
    --no-backup)  no_backup=1; shift ;;
    -h|--help)    usage ;;
    *) echo "unpin-device: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "unpin-device: --router обязателен" >&2; usage; }
[ -z "$source_ip" ] && [ -z "$source_cidr" ] && {
  echo "unpin-device: нужен --source-ip или --source-cidr" >&2; usage
}
[ -n "$source_ip" ] && [ -n "$source_cidr" ] && {
  echo "unpin-device: --source-ip и --source-cidr взаимоисключающие" >&2; usage
}

# Normalize to CIDR
if [ -n "$source_ip" ]; then
  if ! printf '%s' "$source_ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "unpin-device: невалидный IP '$source_ip'" >&2; exit 13
  fi
  cidr="${source_ip}/32"
else
  cidr="$source_cidr"
fi

# --- Resolve router + SSH alive -----------------------------------------------
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  echo "unpin-device: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST)" >&2
  exit 2
fi

REMOTE_CONFIG="/etc/sing-box/config.json"
REMOTE_INITD="/etc/init.d/sing-box-tproxy"
REMOTE_STATE="/etc/vpn-kit/install-state.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "unpin-device: локально нужен jq (brew install jq)" >&2; exit 13
fi

# --- Idempotency: check if pin exists -----------------------------------------
present="$(ssh_run "jq -e --arg c '$cidr' \
  'any(.route.rules[]?; (.source_ip_cidr // []) | any(. == \$c))' \
  $REMOTE_CONFIG 2>/dev/null" 2>/dev/null || echo "false")"

if [ "$present" != "true" ]; then
  echo "unpin-device: pin для '$cidr' не найден — ничего не делаю" >&2
  exit 0
fi

echo "unpin-device: удаляю pin для $cidr на роутере $ROUTER_ALIAS" >&2

# --- Pre-backup ---------------------------------------------------------------
snapshot_id=""
if [ "$no_backup" = "1" ]; then
  echo "unpin-device: ⚠ --no-backup — только для тестов!" >&2
else
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
                        --label "before unpin-device $cidr" --quiet)"; then
    echo "unpin-device: backup-now упал — отказываюсь продолжать" >&2
    exit 2
  fi
fi

rollback_now() {
  local reason="$1"
  [ -z "$snapshot_id" ] && { echo "unpin-device: $reason; snapshot пуст — ручной откат" >&2; return 1; }
  echo "unpin-device: $reason — восстанавливаю снимок $snapshot_id" >&2
  ssh_run "set -eu
TAR=\"/etc/vpn-kit/snapshots/${snapshot_id}.tar.gz\"
[ -f \"\$TAR\" ] || exit 1
tar -xzf \"\$TAR\" -C /
" >/dev/null 2>&1 || true
}

# --- Find pin ID for THIS source (for state cleanup) --------------------------
# The nft comment pattern is vpn-kit-pin-<hash>. We MUST match the pin belonging
# to this exact source IP — NOT just the first pin in the file. The bare IP (no
# /32) is what appears on the init.d rule line.
bare_ip="${cidr%/*}"

# Primary: the pin-id on the init.d nft rule line that carries this source IP.
pin_id="$(ssh_run "grep -F '$bare_ip' $REMOTE_INITD 2>/dev/null | grep -oE 'vpn-kit-pin-[a-f0-9]+' | head -1" 2>/dev/null || true)"

# Fallback: install-state lookup by source CIDR. Only override when it actually
# returns a value — otherwise we'd clobber a good init.d match with empty.
if [ -z "$pin_id" ] && ssh_run "test -f $REMOTE_STATE" >/dev/null 2>&1; then
  state_pin="$(ssh_run "jq -r --arg c '$cidr' \
    '.dynamic_additions[]? | select(.type == \"pin\" and .source == \$c) | .id' \
    $REMOTE_STATE 2>/dev/null | head -1" 2>/dev/null || true)"
  [ -n "$state_pin" ] && pin_id="$state_pin"
fi

# --- Apply changes on router --------------------------------------------------
ssh_run "set -e
CONFIG='$REMOTE_CONFIG'
INITD='$REMOTE_INITD'
STATE='$REMOTE_STATE'
CIDR='$cidr'
PIN_ID='$pin_id'

# 1. config.json
jq \"del(.route.rules[] | select((.source_ip_cidr // []) | any(. == \\\"\$CIDR\\\")))\" \
  \"\$CONFIG\" > /tmp/unpin-config.json
sing-box check -c /tmp/unpin-config.json >/dev/null
mv -f /tmp/unpin-config.json \"\$CONFIG\"

# 2. init.d — remove nft line with pin comment (if pin_id known)
if [ -n \"\$PIN_ID\" ]; then
  sed -i \"/\$PIN_ID/d\" \"\$INITD\"
fi

# 3. install-state.json
if [ -f \"\$STATE\" ] && [ -n \"\$PIN_ID\" ]; then
  jq \"del(.dynamic_additions[] | select(.id == \\\"\$PIN_ID\\\"))\" \
    \"\$STATE\" > /tmp/unpin-state.json && mv -f /tmp/unpin-state.json \"\$STATE\"
fi

# 4. restart
/etc/init.d/sing-box-tproxy restart
" 2>&1 || {
  echo "unpin-device: SSH команда упала — откатываю" >&2
  rollback_now "ssh apply failed"
  exit 20
}

# --- Verify -------------------------------------------------------------------
still_present="$(ssh_run "jq -e --arg c '$cidr' \
  'any(.route.rules[]?; (.source_ip_cidr // []) | any(. == \$c))' \
  $REMOTE_CONFIG 2>/dev/null" 2>/dev/null || echo "false")"

if [ "$still_present" = "true" ]; then
  echo "unpin-device: pin всё ещё в конфиге после применения — откатываю" >&2
  rollback_now "pin still present after apply"
  exit 20
fi

# --- Update memory/<alias>/pins.md --------------------------------------------
PINS_MD="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/pins.md"
if [ -f "$PINS_MD" ]; then
  tmp_md="$(mktemp -t openwrt-skill-pins.XXXXXX)"
  awk -v c="$cidr" '
    BEGIN { in_table = 0; rows_kept = 0; printed_empty = 0 }
    /^\|[[:space:]]*-+/ { in_table = 1; print; next }
    in_table == 1 && /^\|/ {
      line = $0
      n = index(substr(line, 2), "|")
      if (n > 0) {
        cell1 = substr(line, 2, n - 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell1)
        if (cell1 == c) { next }
      }
      rows_kept++
      print
      next
    }
    in_table == 1 && !/^\|/ {
      in_table = 0
      if (rows_kept == 0 && printed_empty == 0) {
        print "_(пусто)_"
        printed_empty = 1
      }
      print
      next
    }
    { print }
    END {
      if (in_table == 1 && rows_kept == 0 && printed_empty == 0) print "_(пусто)_"
    }
  ' "$PINS_MD" > "$tmp_md"
  mv "$tmp_md" "$PINS_MD"
fi

# --- Journal ------------------------------------------------------------------
if ! memory_journal_append "$ROUTER_ALIAS" "unpin_device" \
       "source_ip=$cidr" "pin_id=${pin_id:-(unknown)}" \
       "snapshot_before=${snapshot_id:-(skipped)}"; then
  echo "unpin-device: журнал не записан (не критично)" >&2
fi

cat >&2 <<EOF

unpin-device: готово.
  router:    $ROUTER_ALIAS
  source:    $cidr
  pin_id:    ${pin_id:-(unknown)}
  snapshot:  ${snapshot_id:-(skipped)}
  sing-box:  перезапущен
EOF

exit 0
