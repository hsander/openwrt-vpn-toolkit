#!/bin/sh
# Run OpenWrt safety smoke tests in an OpenWrt rootfs container.

set -eu

IMAGE="${OPENWRT_IMAGE:-openwrt/rootfs:x86-64}"
PLATFORM="${OPENWRT_PLATFORM:-linux/amd64}"
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

docker run --rm --platform "$PLATFORM" \
  -v "$ROOT:/work/openwrt-vpn-kit:ro" \
  "$IMAGE" \
  sh -lc '
    if ! command -v jq >/dev/null 2>&1; then
      apk update >/dev/null
      apk add jq >/dev/null
    fi
    /work/openwrt-vpn-kit/tests/openwrt-safety-smoke.sh
  '
