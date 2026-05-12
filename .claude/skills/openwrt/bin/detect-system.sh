#!/bin/sh
# detect-system.sh — detect OpenWrt version, arch, RAM, flash, pkg manager, radios.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LIB_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/vpn-kit-common.sh
. "$LIB_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

read_release_var() {
  _name="$1"
  if [ -f /etc/openwrt_release ]; then
    sed -n "s/^${_name}='\(.*\)'/\1/p" /etc/openwrt_release | head -1
  fi
}

release="$(read_release_var DISTRIB_RELEASE)"
revision="$(read_release_var DISTRIB_REVISION)"
target="$(read_release_var DISTRIB_TARGET)"
arch="$(read_release_var DISTRIB_ARCH)"
description="$(read_release_var DISTRIB_DESCRIPTION)"

[ -n "$release" ] || release="unknown"
[ -n "$revision" ] || revision="unknown"
[ -n "$target" ] || target="unknown"
[ -n "$arch" ] || arch="$(uname -m 2>/dev/null || echo unknown)"
[ -n "$description" ] || description="unknown"

pkg_mgr="none"
if command -v apk >/dev/null 2>&1; then
  pkg_mgr="apk"
elif command -v opkg >/dev/null 2>&1; then
  pkg_mgr="opkg"
fi

ram_kb="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
case "$ram_kb" in ''|*[!0-9]*) ram_kb=0 ;; esac
ram_mb=$((ram_kb / 1024))

flash_free_kb="$(df -k / 2>/dev/null | awk 'NR==2 {print $4; exit}')"
case "$flash_free_kb" in ''|*[!0-9]*) flash_free_kb=0 ;; esac
flash_free_mb=$((flash_free_kb / 1024))

openwrt_major=0
case "$release" in
  SNAPSHOT) openwrt_major=99 ;;
  [0-9]*) openwrt_major="${release%%.*}" ;;
esac
case "$openwrt_major" in ''|*[!0-9]*) openwrt_major=0 ;; esac

has_procd=false
command -v procd >/dev/null 2>&1 && has_procd=true
has_start_stop_daemon=false
command -v start-stop-daemon >/dev/null 2>&1 && has_start_stop_daemon=true
has_uci=false
command -v uci >/dev/null 2>&1 && has_uci=true
has_nft=false
command -v nft >/dev/null 2>&1 && has_nft=true

radios='[]'
if command -v uci >/dev/null 2>&1; then
  radios="$(uci -q show wireless 2>/dev/null | awk -F'[.=]' '
    $3 == "type" && $4 ~ /wifi-device/ {print $2}
  ' | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')"
fi

jq -n \
  --arg openwrt_version "$release" \
  --arg openwrt_revision "$revision" \
  --arg target "$target" \
  --arg arch "$arch" \
  --arg description "$description" \
  --arg package_manager "$pkg_mgr" \
  --argjson openwrt_major "$openwrt_major" \
  --argjson ram_mb "$ram_mb" \
  --argjson flash_free_mb "$flash_free_mb" \
  --argjson procd "$has_procd" \
  --argjson start_stop_daemon "$has_start_stop_daemon" \
  --argjson uci "$has_uci" \
  --argjson nft "$has_nft" \
  --argjson wifi_radios "$radios" \
  '{
    openwrt_version:$openwrt_version,
    openwrt_major:$openwrt_major,
    openwrt_revision:$openwrt_revision,
    target:$target,
    arch:$arch,
    description:$description,
    package_manager:$package_manager,
    ram_mb:$ram_mb,
    flash_free_mb:$flash_free_mb,
    commands:{procd:$procd, start_stop_daemon:$start_stop_daemon, uci:$uci, nft:$nft},
    wifi_radios:$wifi_radios
  }'
