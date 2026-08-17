#!/usr/bin/env bash
# Read-only inventory of OpenWrt button labels, key codes, and handlers.

set -euo pipefail

router=""
ssh_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    *) echo "Usage: bin/inspect-router-buttons.sh --router <alias> --ssh-alias <alias>" >&2; exit 64 ;;
  esac
done
[ -n "$router" ] && [[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 64

ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 \
  "$ssh_alias" 'sh -s' <<'REMOTE_SH'
set -u

echo "handlers_begin"
for handler in /etc/rc.button/*; do
  [ -f "$handler" ] || continue
  name="${handler##*/}"
  size="$(wc -c <"$handler" 2>/dev/null | tr -d ' ')"
  hash="$(sha256sum "$handler" 2>/dev/null | awk '{print $1}')"
  echo "handler=$name size=$size sha256=$hash"
done
echo "handlers_end"

echo "device_tree_keys_begin"
for keydir in /sys/firmware/devicetree/base/keys/* /sys/firmware/devicetree/base/gpio-keys/*; do
  [ -d "$keydir" ] || continue
  node="${keydir##*/}"
  label="$(tr -d '\000' <"$keydir/label" 2>/dev/null || true)"
  code_hex="$(hexdump -v -e '1/1 "%02x"' "$keydir/linux,code" 2>/dev/null || true)"
  echo "node=$node label=$label linux_code_hex=$code_hex"
done
echo "device_tree_keys_end"

echo "button_log_begin"
logread 2>/dev/null | grep -Ei 'button|gpio.key|hotplug.*button' | tail -40 || true
echo "button_log_end"
REMOTE_SH
