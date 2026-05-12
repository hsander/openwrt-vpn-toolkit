#!/bin/sh
# Run minimal-profile live activation in an OpenWrt QEMU VM.
#
# This test does not use a real router and does not use real VLESS credentials.
# It enables a test-only direct outbound so the mixed proxy can be verified
# without sending traffic through a user's VPN node.
#
# Env:
#   OPENWRT_SSH_HOST=127.0.0.1
#   OPENWRT_SSH_PORT=2299
#   OPENWRT_SSH_KEY=/path/to/key
#   OPENWRT_POWEROFF_AFTER_TEST=1   # default; set 0 only when wrapped by with-openwrt-qemu.sh

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
    -o ConnectTimeout=5 \
    root@"$HOST" "$@"
}

poweroff_vm() {
  [ "$POWEROFF_AFTER_TEST" = "1" ] || return 0
  ssh_base '/sbin/poweroff -f' >/dev/null 2>&1 || true
}

trap poweroff_vm EXIT INT TERM

sample_vless='vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxyzABCDEFGH&sid=abcd&type=tcp&flow=xtls-rprx-vision#node'
tmp_tar="/tmp/openwrt-vpn-kit-qemu-minimal-live.tgz"

tar -C "$(dirname "$ROOT")" -czf "$tmp_tar" "$(basename "$ROOT")"
scp -O -i "$KEY" -P "$PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN_HOSTS" \
  "$tmp_tar" root@"$HOST":/tmp/openwrt-vpn-kit.tgz

ssh_base 'ip route replace default via 192.168.1.2 dev br-lan || true; mkdir -p /tmp/resolv.conf.d; printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /tmp/resolv.conf.d/resolv.conf.auto'
ssh_base 'apk update >/tmp/vpnkit-apk-update.log && apk add jq >/tmp/vpnkit-apk-jq.log'
ssh_base 'rm -rf /tmp/openwrt-vpn-kit && tar -C /tmp -xzf /tmp/openwrt-vpn-kit.tgz && /tmp/openwrt-vpn-kit/scripts/install-safety.sh --writer claude-code@qemu-live >/tmp/vpnkit-install-safety.out && /etc/init.d/vpn-kit-rollback restart'

ssh_base "/tmp/openwrt-vpn-kit/scripts/install-minimal.sh --activate --test-direct-outbound --writer claude-code@qemu-live --vless-url '$sample_vless' --node-name qemu-direct --port 4000 >/tmp/vpnkit-install-minimal-live.out"

ssh_base "jq -e '.status == \"ok\" and .activated == 1' /tmp/vpnkit-install-minimal-live.out >/dev/null"
ssh_base "jq -e '.components[\"sing-box\"].activated == true and .components[\"sing-box\"].activation_mode == \"live\"' /etc/vpn-kit/install-state.json >/dev/null"
ssh_base "sing-box check -c /etc/sing-box/config.json >/dev/null"
ssh_base "/etc/init.d/sing-box-tproxy enabled >/dev/null && /etc/init.d/sing-box-tproxy status >/dev/null"
ssh_base "grep -F 'vpn-kit LAN proxy 4000' /etc/config/firewall >/dev/null"
ssh_base "grep -F '/usr/bin/dns-watchdog.sh' /etc/crontabs/root >/dev/null && grep -F '/usr/bin/vpn-nodes-watchdog.sh' /etc/crontabs/root >/dev/null"
ssh_base "netstat -lnpt 2>/dev/null | grep -E '127.0.0.1:4000|0.0.0.0:4000|:::4000' >/dev/null"
ssh_base "curl -fsS --max-time 20 --proxy http://127.0.0.1:4000 http://example.com/ >/tmp/vpnkit-proxy-example.html && grep -qi example /tmp/vpnkit-proxy-example.html"

ssh_base 'rev=$(jq -r ._revision /etc/vpn-kit/install-state.json); jq "del(._revision, ._last_writer, ._last_writer_host, ._last_updated_at)" /etc/vpn-kit/install-state.json > /tmp/vpnkit-break-state.json; if /usr/lib/vpn-kit/staged-apply.sh --step-id break-sing-box-config --expected-revision "$rev" --writer claude-code@qemu-live --new-state /tmp/vpnkit-break-state.json --snapshot-path /etc/sing-box/config.json --apply "printf %s broken-json > /etc/sing-box/config.json; /etc/init.d/sing-box-tproxy restart >/dev/null 2>&1 || true" --verify "sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1" --rollback-command "/etc/init.d/sing-box-tproxy restart >/dev/null 2>&1 || true" --timeout-seconds 10 >/tmp/vpnkit-break-sing-box.out 2>/tmp/vpnkit-break-sing-box.err; then echo "broken config staged apply unexpectedly succeeded" >&2; exit 1; fi'
ssh_base "sing-box check -c /etc/sing-box/config.json >/dev/null && /etc/init.d/sing-box-tproxy status >/dev/null"
ssh_base "grep -q 'staged_apply_rolled_back' /etc/vpn-kit/journal/events.jsonl"

ssh_base 'tail -8 /etc/vpn-kit/journal/events.jsonl'
echo "OpenWrt QEMU minimal live activation test passed"
