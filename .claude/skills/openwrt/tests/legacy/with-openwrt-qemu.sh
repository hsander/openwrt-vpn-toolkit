#!/bin/sh
# Start OpenWrt QEMU, wait for SSH, run a command, and always stop the VM.
#
# Usage:
#   tests/with-openwrt-qemu.sh tests/run-openwrt-qemu-minimal-live-test.sh

set -eu

VM_DIR="${OPENWRT_QEMU_VM_DIR:-/tmp/openwrt-vpn-kit-vm}"
IMAGE="${OPENWRT_QEMU_IMAGE:-$VM_DIR/openwrt.img}"
KEY="${OPENWRT_SSH_KEY:-$VM_DIR/id_ed25519}"
KNOWN_HOSTS="${OPENWRT_KNOWN_HOSTS:-$VM_DIR/known_hosts}"
HOST="${OPENWRT_SSH_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2299}"
QEMU_BIN="${OPENWRT_QEMU_BIN:-qemu-system-x86_64}"
QEMU_LOG="${OPENWRT_QEMU_LOG:-$VM_DIR/qemu.log}"
POWEROFF_AFTER_TEST="${OPENWRT_POWEROFF_AFTER_TEST:-1}"

[ "$#" -gt 0 ] || { echo "with-openwrt-qemu: command is required" >&2; exit 13; }
[ -f "$IMAGE" ] || { echo "with-openwrt-qemu: image not found: $IMAGE" >&2; exit 13; }
[ -f "$KEY" ] || { echo "with-openwrt-qemu: SSH key not found: $KEY" >&2; exit 13; }
command -v "$QEMU_BIN" >/dev/null 2>&1 || { echo "with-openwrt-qemu: qemu not found: $QEMU_BIN" >&2; exit 13; }

mkdir -p "$VM_DIR"
: > "$QEMU_LOG"

ssh_base() {
  ssh -i "$KEY" -p "$PORT" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o ConnectTimeout=2 \
    root@"$HOST" "$@"
}

cleanup() {
  rc=$?
  if [ "${qemu_pid:-}" ]; then
    if [ "$POWEROFF_AFTER_TEST" = "1" ]; then
      ssh_base '/sbin/poweroff -f' >/dev/null 2>&1 || true
    fi
    i=1
    while kill -0 "$qemu_pid" >/dev/null 2>&1 && [ "$i" -le 20 ]; do
      sleep 1
      i=$((i + 1))
    done
    if kill -0 "$qemu_pid" >/dev/null 2>&1; then
      kill "$qemu_pid" >/dev/null 2>&1 || true
      wait "$qemu_pid" >/dev/null 2>&1 || true
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

"$QEMU_BIN" \
  -m 256 \
  -smp 1 \
  -nographic \
  -drive "file=$IMAGE,format=raw,if=virtio" \
  -netdev "user,id=net0,net=192.168.1.0/24,host=192.168.1.2,hostfwd=tcp:$HOST:$PORT-192.168.1.1:22" \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  > "$QEMU_LOG" 2>&1 &
qemu_pid="$!"

i=1
while [ "$i" -le 60 ]; do
  if ssh_base true >/dev/null 2>&1; then
    break
  fi
  sleep 1
  i=$((i + 1))
done

if ! ssh_base true >/dev/null 2>&1; then
  echo "with-openwrt-qemu: SSH did not become ready; qemu log tail:" >&2
  tail -80 "$QEMU_LOG" >&2 || true
  exit 1
fi

OPENWRT_SSH_HOST="$HOST" \
OPENWRT_SSH_PORT="$PORT" \
OPENWRT_SSH_KEY="$KEY" \
OPENWRT_KNOWN_HOSTS="$KNOWN_HOSTS" \
OPENWRT_POWEROFF_AFTER_TEST=0 \
  "$@"
