#!/usr/bin/env bash
# tests/qemu-smoke/prepare-image.sh
#
# Download and prepare an OpenWRT aarch64 image suitable for QEMU + HVF on macOS.
#
# Output (printed as `key=value` on stdout, parseable by run-e2e.sh):
#   IMAGE_PATH=/abs/path/to/rootfs.ext4.img        (writable; will be cloned per boot)
#   KERNEL_PATH=/abs/path/to/kernel.bin
#   SSH_KEY=/abs/path/to/id_ed25519                (private)
#   SSH_PUB=/abs/path/to/id_ed25519.pub
#
# Side effects:
#   ~/.openwrt-skill/cache/qemu-aarch64/ caches the upstream download and the
#   generated SSH keypair so subsequent runs are fast.
#
# Approach:
#   - Pull official OpenWRT 24.10.6 `armsr/armv8` ext4 rootfs + kernel from
#     downloads.openwrt.org. Verify SHA256 (pinned below).
#   - Generate / reuse a per-machine ed25519 keypair under the cache dir.
#   - Inject the public key into /etc/dropbear/authorized_keys inside the
#     ext4 rootfs image using `debugfs` from `e2fsprogs-extra` (runs in a
#     tiny Alpine Docker container — macOS has no native ext4 r/w).
#   - Drop a uci-defaults script that:
#       * sets LAN bridge to 192.168.1.1/24 on eth0
#       * disables the wifi radio (no radio anyway, but defensive)
#       * blanks root password (passwordless dropbear is gated by key)
#       * leaves dropbear's default config alone (it listens on :22 already)
#   - Keep the modified image at .../rootfs.ext4.prepared.img (the "golden"
#     prepared image). run-e2e.sh will make a per-boot writable copy.

set -euo pipefail

# ----------------------------- pinned upstream ---------------------------------
OPENWRT_VERSION="24.10.6"
OPENWRT_TARGET="armsr/armv8"
ROOTFS_FILENAME="openwrt-${OPENWRT_VERSION}-armsr-armv8-generic-ext4-rootfs.img.gz"
KERNEL_FILENAME="openwrt-${OPENWRT_VERSION}-armsr-armv8-generic-kernel.bin"
ROOTFS_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${ROOTFS_FILENAME}"
KERNEL_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${KERNEL_FILENAME}"

# Pinned SHA256s (verified 2026-05-12 against downloads.openwrt.org/.../sha256sums).
# Bump these together with $OPENWRT_VERSION above.
ROOTFS_SHA256="44d70e5b2e89d7b96e93dd6f093bf735928e803c0c2a62ff27b15cdedd8e8032"
KERNEL_SHA256="f10546c21cf2b5a577edc4a779b7fc4298336fb213e9dd3d466b8ec114a6433f"

CACHE_DIR="${OPENWRT_SKILL_QEMU_CACHE:-$HOME/.openwrt-skill/cache/qemu-aarch64}"

ROOTFS_GZ="$CACHE_DIR/$ROOTFS_FILENAME"
KERNEL_BIN="$CACHE_DIR/$KERNEL_FILENAME"
ROOTFS_RAW="$CACHE_DIR/rootfs.ext4.img"               # decompressed clean copy
ROOTFS_PREPARED="$CACHE_DIR/rootfs.ext4.prepared.img" # with key + uci-defaults injected
SSH_KEY="$CACHE_DIR/id_ed25519"
SSH_PUB="$CACHE_DIR/id_ed25519.pub"
PREP_STAMP="$CACHE_DIR/.prepared.${OPENWRT_VERSION}.stamp"

# Docker image for ext4 manipulation. Alpine + e2fsprogs-extra is small (~10MB
# layer once cached) and bundles `debugfs`. We pin a digest indirectly by
# using a major alpine tag — good enough for a local test runner.
DEBUGFS_IMAGE="${OPENWRT_SKILL_DEBUGFS_IMAGE:-alpine:3.20}"
# Match host arch so docker can run natively (no qemu-emul tax). debugfs is
# arch-agnostic at the data layer — it works on any ext4 from any host.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|aarch64) DOCKER_PLATFORM="linux/arm64" ;;
  x86_64|amd64)  DOCKER_PLATFORM="linux/amd64" ;;
  *)             DOCKER_PLATFORM="linux/amd64" ;;
esac

log() { printf '[prepare-image %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "prepare-image: missing host command: $1" >&2
    return 2
  }
}

require_cmd curl
require_cmd shasum
require_cmd gunzip
require_cmd ssh-keygen
require_cmd docker
docker info >/dev/null 2>&1 || {
  echo "prepare-image: docker is not running (Docker Desktop?)" >&2
  exit 2
}

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

# ----------------------------- 1. SSH keypair ---------------------------------
if [ ! -f "$SSH_KEY" ] || [ ! -f "$SSH_PUB" ]; then
  log "generating ed25519 keypair: $SSH_KEY"
  ssh-keygen -t ed25519 -N '' -C 'openwrt-skill-qemu-smoke' -f "$SSH_KEY" >/dev/null
  chmod 600 "$SSH_KEY"
fi

# ----------------------------- 2. Download (cached) ---------------------------
verify_sha256() {
  local file="$1" expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}

download_if_needed() {
  local url="$1" dest="$2" expected_sha="$3"
  if [ -f "$dest" ] && verify_sha256 "$dest" "$expected_sha"; then
    log "cached + sha-verified: $(basename "$dest")"
    return 0
  fi
  log "downloading: $url"
  if ! curl -fSL --max-time 300 -o "$dest.part" "$url"; then
    echo "prepare-image: download failed: $url" >&2
    rm -f "$dest.part"
    return 2
  fi
  mv "$dest.part" "$dest"
  if ! verify_sha256 "$dest" "$expected_sha"; then
    echo "prepare-image: SHA256 mismatch for $(basename "$dest")" >&2
    echo "  expected: $expected_sha" >&2
    echo "  got:      $(shasum -a 256 "$dest" | awk '{print $1}')" >&2
    rm -f "$dest"
    return 2
  fi
  log "downloaded + verified: $(basename "$dest")"
}

download_if_needed "$ROOTFS_URL" "$ROOTFS_GZ"  "$ROOTFS_SHA256"
download_if_needed "$KERNEL_URL" "$KERNEL_BIN" "$KERNEL_SHA256"

# ----------------------------- 3. Skip if already prepared --------------------
if [ -f "$PREP_STAMP" ] && [ -f "$ROOTFS_PREPARED" ] && [ -f "$KERNEL_BIN" ]; then
  log "using cached prepared image: $ROOTFS_PREPARED"
  printf 'IMAGE_PATH=%s\n' "$ROOTFS_PREPARED"
  printf 'KERNEL_PATH=%s\n' "$KERNEL_BIN"
  printf 'SSH_KEY=%s\n'    "$SSH_KEY"
  printf 'SSH_PUB=%s\n'    "$SSH_PUB"
  exit 0
fi

# ----------------------------- 4. Decompress rootfs ---------------------------
log "decompressing rootfs..."
gunzip -kc "$ROOTFS_GZ" > "$ROOTFS_RAW.tmp"
mv "$ROOTFS_RAW.tmp" "$ROOTFS_RAW"
cp "$ROOTFS_RAW" "$ROOTFS_PREPARED.tmp"

# Resize-up: rootfs is shipped tight (~104MB). We want a few extra MB for apk
# install of sing-box later. Pad with 256MB by appending zeros and resize.
log "padding rootfs (+256MB headroom for apk install)..."
dd if=/dev/zero bs=1m count=256 >> "$ROOTFS_PREPARED.tmp" 2>/dev/null

# ----------------------------- 5. Build uci-defaults + key payload -----------
WORK_DIR="$(mktemp -d -t openwrt-skill-prep.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM
PAYLOAD_DIR="$WORK_DIR/payload"
mkdir -p "$PAYLOAD_DIR"

# 5a. authorized_keys file from our public key.
cp "$SSH_PUB" "$PAYLOAD_DIR/authorized_keys"

# 5b. uci-defaults script: runs ONCE on first boot, then deletes itself.
#     Sets LAN to 192.168.1.1/24, opens dropbear (key-only), disables WiFi,
#     blanks root password, and tags this build as "qemu-smoke" so
#     `bin/doctor.sh` doesn't get confused.
cat > "$PAYLOAD_DIR/99-qemu-smoke.uci" <<'UCIDEFAULT'
#!/bin/sh
# openwrt-skill qemu-smoke first-boot setup. Runs once via /etc/uci-defaults
# during procd preinit and self-deletes on success.
#
# Keep this MINIMAL: uci-defaults runs synchronously and stalls boot if it
# blocks. We only touch what we have to, and we do NOT restart any services
# from here — the rest of procd does that in the proper order right after.

exec >/tmp/qemu-smoke-uci.log 2>&1
set -x

# 1. LAN: static 192.168.1.1/24. install-vpn.sh hard-codes --listen 192.168.1.1
#    so the guest MUST own that IP for sing-box's mixed inbound to bind.
uci -q set network.lan.ipaddr='192.168.1.1'
uci -q set network.lan.netmask='255.255.255.0'
uci -q set network.lan.proto='static'
uci -q commit network

# 2. Drop wan zone safely (no failure if absent). Default-built armsr image
#    ships only `lan` in the network config, so this is a no-op there.
uci -q delete network.wan   2>/dev/null || true
uci -q delete network.wan6  2>/dev/null || true
uci -q delete dhcp.wan      2>/dev/null || true
uci -q commit network
uci -q commit dhcp

# 3. Make sure firewall allows SSH/inbound on lan. Default openwrt already
#    does this; we override defaults.input=ACCEPT as belt-and-braces.
uci -q set firewall.@defaults[0].input='ACCEPT'   2>/dev/null || true
uci -q set firewall.@defaults[0].forward='ACCEPT' 2>/dev/null || true
uci -q commit firewall

# 4. Blank root password — key auth is required by dropbear's authorized_keys
#    we injected pre-boot, but having no password also lets us `passwd -d` not
#    block in non-interactive mode.
passwd -d root >/dev/null 2>&1 || true

# 5. Tag this image as a smoke VM.
mkdir -p /etc/openwrt-skill
printf 'qemu-smoke armsr/armv8 first-boot=%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" \
  > /etc/openwrt-skill/qemu-smoke.tag

# Returning 0 makes procd remove this script so it never runs again.
exit 0
UCIDEFAULT
chmod +x "$PAYLOAD_DIR/99-qemu-smoke.uci"

# ----------------------------- 6. Inject via debugfs --------------------------
# debugfs runs all commands from -f script; uses absolute paths only. We:
#   - mkdir + write authorized_keys with mode 0600, uid/gid 0
#   - write the uci-defaults script with mode 0755
#   - resize the FS to use the new file size (so apk has room)
#
# Note: debugfs cannot resize the FS — that needs resize2fs. We invoke both.
log "injecting SSH key + uci-defaults via debugfs (docker, $DOCKER_PLATFORM)..."

# Build debugfs command script:
DBSCRIPT="$WORK_DIR/debugfs.cmds"
cat > "$DBSCRIPT" <<'EOF'
# Remove any pre-existing key file (the upstream image has an empty placeholder).
rm /etc/dropbear/authorized_keys
write /payload/authorized_keys /etc/dropbear/authorized_keys
set_inode_field /etc/dropbear/authorized_keys mode 0100600
set_inode_field /etc/dropbear/authorized_keys uid 0
set_inode_field /etc/dropbear/authorized_keys gid 0

# Make sure /etc/uci-defaults exists, then drop our first-boot script.
write /payload/99-qemu-smoke.uci /etc/uci-defaults/99-qemu-smoke
set_inode_field /etc/uci-defaults/99-qemu-smoke mode 0100755
set_inode_field /etc/uci-defaults/99-qemu-smoke uid 0
set_inode_field /etc/uci-defaults/99-qemu-smoke gid 0
EOF

# debugfs ignores "rm" failure on a missing file but exits 0 — guard with
# `|| true` is not possible inside a -f script, so we just check exit at the end.
docker run --rm --platform "$DOCKER_PLATFORM" \
  -v "$ROOTFS_PREPARED.tmp:/img" \
  -v "$PAYLOAD_DIR:/payload:ro" \
  -v "$DBSCRIPT:/dbscript:ro" \
  "$DEBUGFS_IMAGE" \
  sh -euc '
    apk add --no-cache e2fsprogs e2fsprogs-extra >/dev/null
    # Resize the FS to fill the newly-padded image.
    e2fsck -fy /img >/dev/null 2>&1 || true
    resize2fs /img >/dev/null 2>&1 || true
    # Apply file injections.
    debugfs -w -f /dbscript /img
  ' >&2

mv "$ROOTFS_PREPARED.tmp" "$ROOTFS_PREPARED"
touch "$PREP_STAMP"

log "prepared image ready: $ROOTFS_PREPARED ($(stat -f %z "$ROOTFS_PREPARED" 2>/dev/null || stat -c %s "$ROOTFS_PREPARED") bytes)"

# ----------------------------- 7. Emit machine-readable result ----------------
printf 'IMAGE_PATH=%s\n' "$ROOTFS_PREPARED"
printf 'KERNEL_PATH=%s\n' "$KERNEL_BIN"
printf 'SSH_KEY=%s\n'    "$SSH_KEY"
printf 'SSH_PUB=%s\n'    "$SSH_PUB"
