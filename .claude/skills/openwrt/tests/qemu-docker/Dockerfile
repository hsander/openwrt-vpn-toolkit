# tests/qemu-docker/Dockerfile
#
# QEMU-in-Docker host for the openwrt-skill end-to-end tests.
#
# Why this exists: the prior native qemu-system-aarch64 + HVF runner on macOS
# couldn't inject an SSH key into the OpenWRT ext4 rootfs (macOS has no native
# ext4 r/w). We pivot: run the *entire* QEMU stack inside a Linux container
# (which has ext4 mount via losetup+mount). Tradeoff: no nested KVM in Docker
# Desktop on macOS, so QEMU runs in TCG -- first boot ~1-3 min.
#
# Image is amd64 deliberately: we boot the official OpenWRT x86_64 combined
# (boot + ext4 rootfs) image, and qemu-system-x86_64 runs natively on amd64
# hosts (and emulated-but-still-fine on aarch64 Docker Desktop on Apple
# Silicon, since QEMU itself is TCG anyway).
#
# Build args (none) -- the upstream image URL + sha are pinned below.
# Build context: this directory (tests/qemu-docker/).
# Run-time: see entrypoint.sh; expects /data mounted as a volume.

FROM --platform=linux/amd64 debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Pinned upstream image. Verified against
# https://downloads.openwrt.org/releases/24.10.6/targets/x86/64/sha256sums
# (header line for openwrt-24.10.6-x86-64-generic-ext4-combined.img.gz).
# Bump together with the URL when promoting.
ARG OPENWRT_VERSION=24.10.6
ARG OPENWRT_IMG_URL=https://downloads.openwrt.org/releases/24.10.6/targets/x86/64/openwrt-24.10.6-x86-64-generic-ext4-combined.img.gz
ARG OPENWRT_IMG_SHA256=23dc6904ede514e37e9938604c9951a0601c375efdaf093c0d191d12e463f9b2

# qemu-system-x86 -> qemu-system-x86_64 binary (with TCG; no KVM needed)
# qemu-utils      -> qemu-img (resize / convert)
# e2fsprogs       -> mkfs/fsck/resize2fs/debugfs (ext4 tooling)
# mount, util-linux -> losetup, mount
# openssh-client  -> for in-container probes only; host orchestrator does
#                    the real SSH dial-in
# socat           -> serial console plumbing if needed
# procps          -> kill/pgrep
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        qemu-system-x86 \
        qemu-utils \
        e2fsprogs \
        util-linux \
        fdisk \
        mount \
        openssh-client \
        curl \
        ca-certificates \
        wget \
        gzip \
        jq \
        tar \
        procps \
        socat \
 && rm -rf /var/lib/apt/lists/*

# ----------------------------- pre-download OpenWRT --------------------------
# We download at build time so the image is self-contained and re-runs don't
# burn time on the network. Validate SHA256 against the pinned value above
# (which we manually verified against the upstream sha256sums file).
#
# We keep the gz under /srv (read-only in spirit). The entrypoint decompresses
# it to /data/openwrt.img on first run.
RUN set -eux; \
    mkdir -p /srv; \
    curl -fSL --retry 3 --max-time 600 -o /srv/openwrt.img.gz "${OPENWRT_IMG_URL}"; \
    echo "${OPENWRT_IMG_SHA256}  /srv/openwrt.img.gz" > /srv/openwrt.img.gz.sha256; \
    sha256sum -c /srv/openwrt.img.gz.sha256; \
    ls -lh /srv/openwrt.img.gz

# Tag the image for traceability.
LABEL org.openwrt-skill.openwrt-version="${OPENWRT_VERSION}"
LABEL org.openwrt-skill.openwrt-sha256="${OPENWRT_IMG_SHA256}"

COPY entrypoint.sh /srv/entrypoint.sh
RUN chmod +x /srv/entrypoint.sh

# Volume for ssh key + decompressed image persistence between runs.
VOLUME ["/data"]

# 22  -> guest sshd (dropbear)
# 4000 -> sing-box mixed/SOCKS inbound (added by install-vpn --add-proxy-port).
EXPOSE 22 4000

ENTRYPOINT ["/srv/entrypoint.sh"]
