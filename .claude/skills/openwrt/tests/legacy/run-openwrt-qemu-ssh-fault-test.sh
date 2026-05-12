#!/bin/sh
# Run an SSH-loss rollback test against a running OpenWrt QEMU VM.
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

tmp_tar="/tmp/openwrt-vpn-kit-qemu-test.tgz"
tar -C "$(dirname "$ROOT")" -czf "$tmp_tar" "$(basename "$ROOT")"
scp -O -i "$KEY" -P "$PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN_HOSTS" \
  "$tmp_tar" root@"$HOST":/tmp/openwrt-vpn-kit.tgz

ssh_base 'rm -rf /tmp/openwrt-vpn-kit && tar -C /tmp -xzf /tmp/openwrt-vpn-kit.tgz && /tmp/openwrt-vpn-kit/scripts/install-safety.sh --writer claude-code@qemu-test >/tmp/vpnkit-install.out && /etc/init.d/vpn-kit-rollback restart'

ssh_base 'rev=$(jq -r ._revision /etc/vpn-kit/install-state.json); jq "del(._revision, ._last_writer, ._last_writer_host, ._last_updated_at)" /etc/vpn-kit/install-state.json > /tmp/vpnkit-new-state.json; setsid /usr/lib/vpn-kit/staged-apply.sh --step-id ssh-loss-dropbear-binary --expected-revision "$rev" --writer claude-code@qemu-test --new-state /tmp/vpnkit-new-state.json --snapshot-path /usr/sbin/dropbear --apply "mv /usr/sbin/dropbear /usr/sbin/dropbear.off; killall dropbear" --verify "sleep 45; false" --rollback-command "rm -f /usr/sbin/dropbear.off; chmod 755 /usr/sbin/dropbear; /etc/init.d/dropbear start" --timeout-seconds 10 >/tmp/vpnkit-dropbear-binary-loss.log 2>&1 < /dev/null &'

failed=0
recovered=0
i=1
while [ "$i" -le 25 ]; do
  sleep 1
  if ssh_base true >/dev/null 2>&1; then
    echo "t=${i}s ssh-ok"
    if [ "$failed" -eq 1 ]; then
      recovered=1
      break
    fi
  else
    echo "t=${i}s ssh-fail"
    failed=1
  fi
  i=$((i + 1))
done

[ "$failed" -eq 1 ] || { echo "SSH never failed during fault scenario" >&2; exit 1; }
[ "$recovered" -eq 1 ] || { echo "SSH did not recover after rollback timer" >&2; exit 1; }

ssh_base 'tail -5 /etc/vpn-kit/journal/events.jsonl; rm -f /usr/sbin/dropbear.off'
echo "OpenWrt QEMU SSH-loss rollback test passed"
