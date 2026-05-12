#!/usr/bin/env bash
# tests/qemu-smoke/boot-vm.sh
#
# Boot a prepared OpenWRT aarch64 image under QEMU + HVF.
#
# Usage:
#   bash tests/qemu-smoke/boot-vm.sh
#     [--image /path/to/rootfs.ext4.img]
#     [--kernel /path/to/kernel.bin]
#     [--ssh-port 2299]
#     [--proxy-port-fwd 14000:4000]
#     [--pid-file /path]
#     [--qemu-log /path]
#     [--ready-timeout 90]
#
# Behaviour:
#   - Clones the prepared image to a per-boot writable copy under TMP_DIR so
#     repeated runs start from a clean state.
#   - Launches qemu-system-aarch64 in the background, writes PID to --pid-file.
#   - Waits for sshd on 127.0.0.1:<ssh-port> up to --ready-timeout seconds.
#   - Sets a trap so a Ctrl-C kills the VM cleanly.
#   - HVF is REQUIRED. If `-accel hvf` doesn't work, we fail fast — TCG is
#     unusably slow for this test (>5 min boot).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Артефакты вне skill-дерева, единый путь с legacy/run-e2e.sh.
TMP_DIR="${LEGACY_QEMU_TMP_DIR:-${TMPDIR:-/tmp}/openwrt-skill-legacy-qemu}"

IMAGE=""
KERNEL=""
SSH_PORT="2299"
PROXY_FWD="14000:4000"
PID_FILE="$TMP_DIR/qemu.pid"
QEMU_LOG="$TMP_DIR/qemu.log"
READY_TIMEOUT="90"
SSH_KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --kernel) KERNEL="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --proxy-port-fwd) PROXY_FWD="$2"; shift 2 ;;
    --pid-file) PID_FILE="$2"; shift 2 ;;
    --qemu-log) QEMU_LOG="$2"; shift 2 ;;
    --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    *) echo "boot-vm: unknown arg: $1" >&2; exit 64 ;;
  esac
done

[ -n "$IMAGE" ]   || { echo "boot-vm: --image is required" >&2; exit 64; }
[ -n "$KERNEL" ]  || { echo "boot-vm: --kernel is required" >&2; exit 64; }
[ -f "$IMAGE" ]   || { echo "boot-vm: image not found: $IMAGE" >&2; exit 2; }
[ -f "$KERNEL" ]  || { echo "boot-vm: kernel not found: $KERNEL" >&2; exit 2; }

# Parse hostfwd spec "HOST_PORT:GUEST_PORT" → "tcp:127.0.0.1:H-:G".
case "$PROXY_FWD" in
  *:*) PROXY_HOST_PORT="${PROXY_FWD%%:*}"; PROXY_GUEST_PORT="${PROXY_FWD##*:}" ;;
  *) echo "boot-vm: bad --proxy-port-fwd '$PROXY_FWD' (want HOST:GUEST)" >&2; exit 64 ;;
esac

mkdir -p "$TMP_DIR"
log() { printf '[boot-vm %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

# ----------------------------- HVF preflight ----------------------------------
QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
command -v "$QEMU_BIN" >/dev/null 2>&1 || {
  echo "boot-vm: $QEMU_BIN not found in PATH" >&2; exit 2; }

if ! "$QEMU_BIN" -accel help 2>/dev/null | grep -q '^hvf$'; then
  echo "boot-vm: HVF accelerator is not available — refusing to fall back to TCG (would take >5min/boot)" >&2
  exit 2
fi

# ----------------------------- clone image -----------------------------------
# Per-boot writable copy so the upstream prepared image stays pristine. We do
# this for a clean baseline AND because debugfs's resize doesn't grow further
# from inside the VM if it's been used once.
RUN_IMG="$TMP_DIR/rootfs.run.img"
log "cloning prepared image -> $RUN_IMG"
cp "$IMAGE" "$RUN_IMG"

# ----------------------------- find DTB / UEFI / etc --------------------------
# armsr/armv8 boots fine on `qemu-system-aarch64 -M virt -cpu host` with the
# raw kernel image — no DTB needed (the virt machine type generates one).

# ----------------------------- launch QEMU ------------------------------------
: > "$QEMU_LOG"

# Network: user-mode, fixed 192.168.1.0/24 so install-vpn's hard-coded
#   --listen 192.168.1.1 works inside the guest (br-lan gets .1, QEMU gw .2).
# Two host->guest forwards:
#   - SSH on $SSH_PORT -> :22 (so we don't need to know guest IP)
#   - Proxy on $PROXY_HOST_PORT -> :$PROXY_GUEST_PORT (sing-box SOCKS5 inbound)
NETDEV="user,id=net0,net=192.168.1.0/24,host=192.168.1.2"
NETDEV="${NETDEV},hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
NETDEV="${NETDEV},hostfwd=tcp:127.0.0.1:${PROXY_HOST_PORT}-:${PROXY_GUEST_PORT}"

log "starting QEMU (HVF, 768M, 2 vCPU; ssh=127.0.0.1:$SSH_PORT, proxy=127.0.0.1:$PROXY_HOST_PORT)"

# NOTE: `-nographic` is a shorthand that conflicts with `-daemonize`. Spell
# out the bits we want explicitly: no display, serial -> file, no monitor.
"$QEMU_BIN" \
  -M virt,highmem=off \
  -accel hvf \
  -cpu host \
  -m 768 \
  -smp 2 \
  -display none \
  -no-reboot \
  -kernel "$KERNEL" \
  -append "root=/dev/vda rootwait console=ttyAMA0,115200n8 console=ttyS0,115200n8" \
  -drive "if=none,file=$RUN_IMG,format=raw,id=hd0" \
  -device virtio-blk-pci,drive=hd0 \
  -netdev "$NETDEV" \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -serial file:"$QEMU_LOG" \
  -monitor none \
  -daemonize \
  -pidfile "$PID_FILE" \
  </dev/null

# `-daemonize -pidfile` writes the PID atomically. Read it.
if [ ! -s "$PID_FILE" ]; then
  echo "boot-vm: qemu did not write pidfile $PID_FILE" >&2
  log "qemu log tail:"
  tail -40 "$QEMU_LOG" >&2 || true
  exit 2
fi
QEMU_PID="$(cat "$PID_FILE")"
log "QEMU pid=$QEMU_PID"

# ----------------------------- trap cleanup -----------------------------------
# Caller (run-e2e.sh) installs its own cleanup; we keep the trap here so a
# direct `bash boot-vm.sh` ctrl-c also cleans up.
cleanup_local() {
  rc=$?
  if [ -n "${QEMU_PID:-}" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    sleep 1
    kill -9 "$QEMU_PID" 2>/dev/null || true
  fi
  exit "$rc"
}
# Only install local trap if not invoked via `source`.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap cleanup_local INT TERM
fi

# ----------------------------- wait for SSH -----------------------------------
log "waiting up to ${READY_TIMEOUT}s for sshd on 127.0.0.1:$SSH_PORT ..."
deadline=$(( $(date +%s) + READY_TIMEOUT ))
SSH_OPTS=( -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR )
[ -n "$SSH_KEY" ] && SSH_OPTS+=( -i "$SSH_KEY" )

# Readiness: we want 3 *consecutive* successful SSH `true` calls spaced ≥2s
# apart. Reason: QEMU's user-mode hostfwd accepts TCP connections to the host
# port before dropbear is actually accepting on the guest, and we've seen the
# very first SSH probe succeed (TCP accept + read) while a few seconds later
# the guest is still mid-boot (procd not done) and SSH banners hang for 30s.
# Three spaced successes = "stable enough to start running tests."
ready=0
consecutive_ok=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "boot-vm: QEMU exited before SSH became ready" >&2
    tail -40 "$QEMU_LOG" >&2 || true
    exit 2
  fi
  if ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" root@127.0.0.1 'true' >/dev/null 2>&1; then
    consecutive_ok=$((consecutive_ok + 1))
    if [ "$consecutive_ok" -ge 3 ]; then
      ready=1
      break
    fi
  else
    consecutive_ok=0
  fi
  sleep 2
done

if [ "$ready" -ne 1 ]; then
  echo "boot-vm: sshd did not become ready within ${READY_TIMEOUT}s" >&2
  log "qemu log tail (last 60 lines):"
  tail -60 "$QEMU_LOG" >&2 || true
  exit 2
fi

log "ssh up; VM is ready"
printf 'QEMU_PID=%s\n' "$QEMU_PID"
printf 'PID_FILE=%s\n' "$PID_FILE"
printf 'QEMU_LOG=%s\n' "$QEMU_LOG"
printf 'RUN_IMG=%s\n'  "$RUN_IMG"
