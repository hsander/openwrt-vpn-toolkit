#!/usr/bin/env bash
# tests/qemu-docker/entrypoint.sh
#
# Container entrypoint. Runs as PID 1 inside the openwrt-skill-qemu container.
#
# Job:
#   1. Ensure /data/id_ed25519{,.pub} keypair exists (re-used across runs).
#   2. Decompress /srv/openwrt.img.gz -> /data/openwrt.img (skip if present).
#   3. Resize the image to 256MB for sing-box install headroom.
#   4. losetup the image, mount its rootfs partition (p2), inject:
#        - /etc/dropbear/authorized_keys (root's public key)
#        - /etc/uci-defaults/99-test-bootstrap (first-boot network setup)
#      then unmount + losetup -d.
#   5. exec qemu-system-x86_64 in the foreground so the container's lifetime
#      tracks the VM.
#
# The mount step is the whole point of putting QEMU in Docker on macOS: the
# container runs Linux, so ext4 mount + edit is trivial.
#
# Caveats / non-obvious bits:
#   - `losetup -fP` is what exposes /dev/loopXp1, /dev/loopXp2 etc. Without
#     `-P` you only get /dev/loopX (no partition scan).
#   - The OpenWRT combined image has 2 partitions: p1=kernel/grub, p2=rootfs.
#   - We mount-mangle-unmount on every container start. It's idempotent: the
#     uci-defaults script self-deletes after first boot, and the authorized_keys
#     write is identical each time (chmod 600, owner 0:0).
#   - The image is resized via `qemu-img resize` (sparse-grow) + `resize2fs`
#     on the rootfs partition. We only do this once (gated by a stamp file).
#
# This script is sourced as the container CMD. It must run as PID 1, in
# foreground, so we end with `exec qemu-system-x86_64 ...`.

set -euo pipefail

log() { printf '[entrypoint %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

DATA_DIR="${DATA_DIR:-/data}"
SRC_IMG_GZ="${SRC_IMG_GZ:-/srv/openwrt.img.gz}"
TARGET_IMG="${TARGET_IMG:-$DATA_DIR/openwrt.img}"
TARGET_SIZE="${TARGET_SIZE:-256M}"
SSH_KEY="${SSH_KEY:-$DATA_DIR/id_ed25519}"
SSH_PUB="${SSH_PUB:-$DATA_DIR/id_ed25519.pub}"
PREP_STAMP="${PREP_STAMP:-$DATA_DIR/.prepared.stamp}"

mkdir -p "$DATA_DIR"

# ----------------------------- 1. SSH keypair --------------------------------
# We generate inside the container so the host doesn't have to (and so the
# private key lives on the shared volume, owned by container-root which is
# usually root on the host volume too).
if [ ! -f "$SSH_KEY" ] || [ ! -f "$SSH_PUB" ]; then
  log "generating ed25519 keypair: $SSH_KEY"
  ssh-keygen -t ed25519 -N '' -C "openwrt-skill-qemu" -f "$SSH_KEY" >/dev/null
  chmod 600 "$SSH_KEY"
  chmod 644 "$SSH_PUB"
else
  log "reusing keypair: $SSH_KEY"
fi

# ----------------------------- 2. Decompress (cached) ------------------------
if [ ! -f "$TARGET_IMG" ]; then
  log "decompressing $(basename "$SRC_IMG_GZ") -> $TARGET_IMG"
  # OpenWRT combined.img.gz часто имеет padding-байты в конце, и GNU gzip
  # рапортует exit 2 "trailing garbage ignored". Декомпрессия при этом
  # корректная — поэтому ловим rc=2 как ok.
  set +e
  gunzip -kc "$SRC_IMG_GZ" > "$TARGET_IMG.tmp"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
    log "FATAL: gunzip failed with exit $rc"
    exit "$rc"
  fi
  # Sanity: file must be at least 10MB (OpenWRT combined is ~20-30MB raw).
  size=$(wc -c < "$TARGET_IMG.tmp")
  if [ "$size" -lt 10485760 ]; then
    log "FATAL: decompressed image suspiciously small ($size bytes)"
    exit 2
  fi
  mv "$TARGET_IMG.tmp" "$TARGET_IMG"
  log "decompressed ok: $size bytes"
else
  log "reusing decompressed image: $TARGET_IMG"
fi

# ----------------------------- 3. Resize (idempotent-ish) --------------------
# We grow the file once (qemu-img resize is a no-op if already at/above target)
# and resize2fs the rootfs partition once. The stamp file gates the inner
# resize2fs because rerunning it on an already-grown FS is harmless but adds
# 1-2s to every container start.
prep_already_done=0
if [ -f "$PREP_STAMP" ]; then
  prep_already_done=1
fi

log "qemu-img resize $TARGET_IMG -> $TARGET_SIZE (no-op if already >=)"
qemu-img resize -q "$TARGET_IMG" "$TARGET_SIZE" 2>&1 | sed 's/^/[qemu-img] /' >&2 || true

# ----------------------------- 4. losetup + mount + inject -------------------
# Why we do this on every start (not just first run):
#   - The first time, we need to inject the key + uci-defaults.
#   - The uci-defaults script self-deletes on first boot. If the host wipes
#     /data and rebuilds, the next start needs to re-inject it.
#   - If the operator deletes the stamp, we re-inject (cheap).
# It costs ~200ms per container start. Worth it for re-runnability.

LOOP_DEV=""
ROOTFS_MNT=""

cleanup_loop() {
  if [ -n "${ROOTFS_MNT:-}" ] && mountpoint -q "$ROOTFS_MNT" 2>/dev/null; then
    umount "$ROOTFS_MNT" 2>/dev/null || umount -l "$ROOTFS_MNT" 2>/dev/null || true
  fi
  if [ -n "${LOOP_DEV:-}" ]; then
    losetup -d "$LOOP_DEV" 2>/dev/null || true
  fi
}
trap cleanup_loop EXIT

ROOTFS_MNT="$(mktemp -d -t openwrt-rootfs.XXXXXX)"

# Docker Desktop's Linux VM kernel often refuses kernel-side partition scan
# (`losetup -fP` returns a loop device but never creates loop0p1/loop0p2). We
# sidestep the whole partition-scan dance by computing the rootfs partition's
# byte offset from the partition table and mounting with `-o loop,offset=...`.
#
# This needs CAP_SYS_ADMIN (privileged), which we already require.

# Read partition table with sfdisk. Output format (json) lists each partition
# with its start sector. We want the SECOND partition (p2, rootfs).
PT_JSON="$(sfdisk --json "$TARGET_IMG" 2>/dev/null || true)"
if [ -z "$PT_JSON" ]; then
  log "FATAL: sfdisk --json failed on $TARGET_IMG"
  exit 2
fi

# OpenWRT combined image: partition 2 = rootfs. Extract its start (in sectors).
P2_START_SECTORS="$(printf '%s' "$PT_JSON" | jq -r '.partitiontable.partitions[1].start')"
P2_SIZE_SECTORS="$(printf '%s' "$PT_JSON" | jq -r '.partitiontable.partitions[1].size')"
SECTOR_SIZE="$(printf '%s' "$PT_JSON" | jq -r '.partitiontable.sectorsize // 512')"

if [ -z "$P2_START_SECTORS" ] || [ "$P2_START_SECTORS" = "null" ]; then
  log "FATAL: cannot find partition 2 in: $PT_JSON"
  exit 2
fi

P2_OFFSET_BYTES=$(( P2_START_SECTORS * SECTOR_SIZE ))
P2_SIZE_BYTES=$(( P2_SIZE_SECTORS * SECTOR_SIZE ))
log "rootfs partition: start_sector=$P2_START_SECTORS, offset=${P2_OFFSET_BYTES} bytes, size=${P2_SIZE_BYTES} bytes"

# Mount the image directly with offset — no losetup -P, no /dev/loopXp2 needed.
# The kernel creates an internal loop device for us; `losetup -l` shows it.
if ! mount -t ext4 -o "loop,offset=${P2_OFFSET_BYTES},sizelimit=${P2_SIZE_BYTES}" \
       "$TARGET_IMG" "$ROOTFS_MNT" 2>/dev/null; then
  log "FATAL: mount -o loop,offset=... failed"
  log "  Likely cause: rootfs partition is not ext4, or kernel can't loop-mount with offset."
  log "  Image partition table:"; printf '%s\n' "$PT_JSON" >&2
  exit 2
fi
log "mounted rootfs (offset=${P2_OFFSET_BYTES}) at $ROOTFS_MNT (rw)"

# Track loop device for cleanup (so we don't accumulate /dev/loopN entries
# across restarts). `losetup -j` finds devices backing our image file.
LOOP_DEV="$(losetup -j "$TARGET_IMG" | awk -F: 'NR==1{print $1}')"

# 4a. authorized_keys: ALWAYS overwrite from our pubkey (idempotent).
mkdir -p "$ROOTFS_MNT/etc/dropbear"
install -m 600 -o 0 -g 0 "$SSH_PUB" "$ROOTFS_MNT/etc/dropbear/authorized_keys"
log "injected $ROOTFS_MNT/etc/dropbear/authorized_keys"

# 4b. uci-defaults: first-boot config. procd runs everything in
# /etc/uci-defaults/ once on first boot, then deletes scripts that return 0.
# We always (re-)write it so a fresh /data image gets it. If the stamp says we
# already booted once, the file is gone from inside the image anyway -- but
# we rebuilt the image from gz on this run if it was missing, so we need to
# re-inject. Keep this simple: always write.
mkdir -p "$ROOTFS_MNT/etc/uci-defaults"
cat > "$ROOTFS_MNT/etc/uci-defaults/99-test-bootstrap" <<'UCIDEFAULTS'
#!/bin/sh
# openwrt-skill qemu-docker test bootstrap. Runs once via /etc/uci-defaults
# during procd preinit, then self-deletes on success (exit 0).
#
# We KEEP THIS MINIMAL: uci-defaults is synchronous and blocks boot. We only
# touch what tests need:
#   - LAN ip 192.168.50.1/24 (some bin/* scripts assume the router owns its LAN
#     gateway; install-vpn binds sing-box to the LAN IP).
#   - Hostname=qemubox (so doctor.sh logs are self-identifying).
#   - Wi-Fi: disabled if present (no radio in QEMU anyway; defensive).
#   - Dropbear: ensure it's enabled (it is by default on stock OpenWRT).
#   - Root password: blanked (key auth is required by our injected
#     authorized_keys, but having no password also helps `passwd -d`-style
#     interactive paths).

exec >/tmp/test-bootstrap.log 2>&1
set -x

uci -q set network.lan.ipaddr='192.168.50.1'
uci -q set network.lan.netmask='255.255.255.0'
uci -q set network.lan.proto='static'
uci -q commit network

# Disable wifi radios if any (no-op on x86_64 generic, defensive).
for r in $(uci -q show wireless 2>/dev/null | awk -F'[.=]' '/wifi-device/{print $2}'); do
  uci -q set "wireless.${r}.disabled=1"
done
uci -q commit wireless 2>/dev/null || true

# Make sure dropbear stays enabled (it is by default).
/etc/init.d/dropbear enable 2>/dev/null || true

uci -q set system.@system[0].hostname='qemubox'
uci -q set system.@system[0].zonename='UTC'
uci -q commit system

# Tag for traceability.
mkdir -p /etc/openwrt-skill
echo "qemu-docker x86_64 first-boot=$(date -u +%Y%m%dT%H%M%SZ)" > /etc/openwrt-skill/qemu-docker.tag

# Blank root password (dropbear authorized_keys is what really gates us).
passwd -d root >/dev/null 2>&1 || true

exit 0
UCIDEFAULTS
chmod +x "$ROOTFS_MNT/etc/uci-defaults/99-test-bootstrap"
log "injected /etc/uci-defaults/99-test-bootstrap"

# Unmount. With `mount -o loop,offset=...` the kernel auto-detaches the loop
# device on umount, so an explicit `losetup -d` either no-ops or fails with
# "No such device" if cleanup happened first. We swallow that.
sync
umount "$ROOTFS_MNT"
if [ -n "${LOOP_DEV:-}" ]; then
  losetup -d "$LOOP_DEV" 2>/dev/null || true
fi
LOOP_DEV=""; ROOTFS_MNT=""
trap - EXIT  # we won't need the cleanup once QEMU has the file

touch "$PREP_STAMP"

# ----------------------------- 5. Launch QEMU --------------------------------
# Networking notes:
#   - We bind hostfwd to 0.0.0.0 inside the container (the container's veth
#     interface) so Docker's port-publish can reach it. The host then maps
#     the container ports to 127.0.0.1 on macOS.
#   - The OpenWRT image's br-lan defaults to 192.168.1.1; our uci-defaults
#     pushes it to 192.168.50.1 (post first-boot). install-vpn picks the LAN
#     IP via UCI lookup, so the value doesn't matter to the orchestrator,
#     only to the guest.
#
# Accel:
#   - TCG by default. KVM is not available inside Docker Desktop on macOS.
#   - q35 + virtio gives reasonable throughput even on TCG (~30-90s boot).
#
# Console:
#   - serial mon:stdio so `docker logs` shows the boot log; helpful for debug.
log "launching qemu-system-x86_64 (TCG, 512MB, 2 vCPU)"
log "  ssh fwd:   container :22   <- guest :22"
log "  proxy fwd: container :4000 <- guest :4000"

exec qemu-system-x86_64 \
  -M q35 \
  -m 512 \
  -smp 2 \
  -nographic \
  -no-reboot \
  -drive "file=${TARGET_IMG},format=raw,if=virtio" \
  -netdev "user,id=net0,net=192.168.50.0/24,host=192.168.50.2,hostfwd=tcp:0.0.0.0:22-192.168.50.1:22,hostfwd=tcp:0.0.0.0:4000-192.168.50.1:4000" \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -serial mon:stdio
