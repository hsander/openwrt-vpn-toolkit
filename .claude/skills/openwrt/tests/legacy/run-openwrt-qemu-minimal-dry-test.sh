#!/bin/sh
# Run a minimal-profile file install + activation dry-run against OpenWrt QEMU.
#
# Assumes:
#   - VM is reachable by SSH with key auth.
#   - jq is installed in the VM.
#
# Env:
#   OPENWRT_SSH_HOST=127.0.0.1
#   OPENWRT_SSH_PORT=2299
#   OPENWRT_SSH_KEY=/path/to/key
#   OPENWRT_POWEROFF_AFTER_TEST=1   # default; set 0 only for manual debugging

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
HOST="${OPENWRT_SSH_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2299}"
KEY="${OPENWRT_SSH_KEY:-}"
KNOWN_HOSTS="${OPENWRT_KNOWN_HOSTS:-/tmp/openwrt-vpn-kit-known-hosts}"
POWEROFF_AFTER_TEST="${OPENWRT_POWEROFF_AFTER_TEST:-1}"

[ -n "$KEY" ] || { echo "OPENWRT_SSH_KEY is required" >&2; exit 13; }

ssh_base() {
  ssh -i "$KEY" -p "$PORT" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o ConnectTimeout=2 \
    root@"$HOST" "$@"
}

poweroff_vm() {
  [ "$POWEROFF_AFTER_TEST" = "1" ] || return 0
  ssh_base '/sbin/poweroff -f' >/dev/null 2>&1 || true
}

trap poweroff_vm EXIT INT TERM

sample_vless='vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxyzABCDEFGH&sid=abcd&type=tcp&flow=xtls-rprx-vision#node'
tmp_tar="/tmp/openwrt-vpn-kit-qemu-minimal.tgz"

tar -C "$(dirname "$ROOT")" -czf "$tmp_tar" "$(basename "$ROOT")"
scp -O -i "$KEY" -P "$PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN_HOSTS" \
  "$tmp_tar" root@"$HOST":/tmp/openwrt-vpn-kit.tgz

ssh_base 'rm -rf /tmp/openwrt-vpn-kit && tar -C /tmp -xzf /tmp/openwrt-vpn-kit.tgz && /tmp/openwrt-vpn-kit/scripts/install-safety.sh --writer claude-code@qemu-minimal >/tmp/vpnkit-install-safety.out && /etc/init.d/vpn-kit-rollback restart'

ssh_base "VPN_KIT_ACTIVATE_DRY_RUN_LOG=/tmp/vpnkit-minimal-activation-plan.log /tmp/openwrt-vpn-kit/scripts/install-minimal.sh --activate --skip-packages --writer claude-code@qemu-minimal --vless-url '$sample_vless' --node-name qemu-node --port 4000 >/tmp/vpnkit-install-minimal.out"

ssh_base "jq -e '.status == \"ok\" and .activated == 1' /tmp/vpnkit-install-minimal.out >/dev/null"
ssh_base "test -s /etc/sing-box/config.json && test -x /etc/init.d/sing-box-tproxy && test -s /tmp/vpnkit-minimal-activation-plan.log"
ssh_base "jq -e '.components[\"sing-box\"].activated == true and .components[\"sing-box\"].activation_mode == \"dry-run\"' /etc/vpn-kit/install-state.json >/dev/null"
ssh_base "grep -F 'uci set firewall.vpn_kit_lan_proxy_4000=rule' /tmp/vpnkit-minimal-activation-plan.log >/dev/null"
ssh_base "grep -F '/etc/init.d/sing-box-tproxy restart' /tmp/vpnkit-minimal-activation-plan.log >/dev/null"

ssh_base 'tail -5 /etc/vpn-kit/journal/events.jsonl'
echo "OpenWrt QEMU minimal activation dry-run test passed"
