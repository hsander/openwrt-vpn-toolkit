#!/bin/sh
# bin/_doctor_remote.sh — runs on the router via SSH stdin. Emits JSON to stdout.
# POSIX/busybox safe. No bash-isms.

# Note: we DO NOT use 'set -e' — every probe should run independently and report
# whatever it finds. Failures of individual checks must NOT abort the whole probe.

# ---------- helpers ----------
json_escape() {
  # stdin -> stdout, escapes \, ", \n, \r, \t
  awk 'BEGIN { ORS = "" }
       {
         gsub(/\\/, "\\\\")
         gsub(/"/, "\\\"")
         gsub(/\r/, "\\r")
         gsub(/\t/, "\\t")
         if (NR > 1) printf("\\n")
         printf("%s", $0)
       }'
}

b() {
  # 1 -> "true", 0 -> "false"
  [ "$1" = "1" ] && echo "true" || echo "false"
}

j_str() { printf '"%s"' "$(printf '%s' "$1" | json_escape)"; }
j_num() {
  case "$1" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------- probe ----------

openwrt_release_file=/etc/openwrt_release
openwrt_version=""
openwrt_target=""
if [ -f "$openwrt_release_file" ]; then
  openwrt_version="$(awk -F\' '/DISTRIB_RELEASE/ {print $2}' "$openwrt_release_file" 2>/dev/null)"
  openwrt_target="$(awk -F\' '/DISTRIB_TARGET/ {print $2}' "$openwrt_release_file" 2>/dev/null)"
fi

arch="$(uname -m 2>/dev/null)"
ram_mb="$(awk '/^MemTotal/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null)"

# Package install check — apk on 24.10+, opkg fallback
if command -v apk >/dev/null 2>&1; then
  pkg_check() { apk info --installed "$1" >/dev/null 2>&1; }
  pkg_mgr="apk"
elif command -v opkg >/dev/null 2>&1; then
  pkg_check() { opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; }
  pkg_mgr="opkg"
else
  pkg_check() { return 1; }
  pkg_mgr="unknown"
fi

pkg_singbox=0;     pkg_check sing-box && pkg_singbox=1
pkg_httpsdns=0;    pkg_check https-dns-proxy && pkg_httpsdns=1
pkg_nft_tproxy=0;  pkg_check kmod-nft-tproxy && pkg_nft_tproxy=1
pkg_nft_queue=0;   pkg_check kmod-nft-queue && pkg_nft_queue=1
pkg_jq=0;          pkg_check jq && pkg_jq=1
pkg_curl=0;        pkg_check curl && pkg_curl=1

singbox_version=""
if command -v sing-box >/dev/null 2>&1; then
  singbox_version="$(sing-box version 2>/dev/null | awk 'NR==1 {print $NF}')"
fi

# sing-box config
config_present=0; [ -f /etc/sing-box/config.json ] && config_present=1
config_valid=0
if [ "$config_present" = "1" ] && command -v sing-box >/dev/null 2>&1; then
  sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 && config_valid=1
fi

rules_present=0; [ -f /etc/sing-box/rules/vpn-domains.json ] && rules_present=1

# tproxy
tproxy_installed=0; [ -f /etc/init.d/sing-box-tproxy ] && tproxy_installed=1
tproxy_running=0
if [ "$tproxy_installed" = "1" ]; then
  /etc/init.d/sing-box-tproxy status >/dev/null 2>&1 && tproxy_running=1
fi

# outbounds
outbound_count=0
outbound_tags=""
has_failover=0
if [ "$config_valid" = "1" ] && command -v jq >/dev/null 2>&1; then
  outbound_count="$(jq -r '.outbounds | length' /etc/sing-box/config.json 2>/dev/null)"
  outbound_tags="$(jq -r '.outbounds | map(.tag) | join(",")' /etc/sing-box/config.json 2>/dev/null)"
  echo "$outbound_tags" | grep -q 'auto-failover' && has_failover=1
fi

# DNS chain
peerdns="$(uci -q get network.wan.peerdns 2>/dev/null)"
[ -z "$peerdns" ] && peerdns="?"
dnsmasq_server="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)"
[ -z "$dnsmasq_server" ] && dnsmasq_server="?"
httpsdns_port="$(uci -q get https-dns-proxy.@https-dns-proxy[0].listen_port 2>/dev/null)"
[ -z "$httpsdns_port" ] && httpsdns_port="?"
dns_redirect_present=0
[ -f /etc/nftables.d/10-dns-redirect.nft ] && dns_redirect_present=1

# zapret
zapret_installed=0
[ -d /opt/zapret ] && zapret_installed=1
zapret_running=0
if [ "$zapret_installed" = "1" ] && [ -f /etc/init.d/zapret-custom ]; then
  /etc/init.d/zapret-custom status >/dev/null 2>&1 && zapret_running=1
fi

# watchdog
watchdog_conf_present=0
watchdog_conf_mode=""
if [ -f /etc/router-watchdog.conf ]; then
  watchdog_conf_present=1
  watchdog_conf_mode="$(stat -c %a /etc/router-watchdog.conf 2>/dev/null)"
  [ -z "$watchdog_conf_mode" ] && watchdog_conf_mode="$(stat -f %A /etc/router-watchdog.conf 2>/dev/null)"
fi
watchdog_cron_count="$(crontab -l 2>/dev/null | grep -c 'watchdog' 2>/dev/null)"
[ -z "$watchdog_cron_count" ] && watchdog_cron_count=0

# fakeip cache
fakeip_cache_present=0
[ -f /usr/share/sing-box/cache.db ] && fakeip_cache_present=1

# skill state
skill_state_present=0
[ -f /etc/vpn-kit/install-state.json ] && skill_state_present=1

# snapshots
snapshot_count=0
if [ -d /etc/vpn-kit/snapshots ]; then
  snapshot_count="$(ls /etc/vpn-kit/snapshots 2>/dev/null | wc -l | awk '{print $1}')"
fi

probed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
hostname="$(uname -n 2>/dev/null)"

# ---------- emit JSON ----------
printf '{\n'
printf '  "hostname": %s,\n' "$(j_str "$hostname")"
printf '  "openwrt_version": %s,\n' "$(j_str "$openwrt_version")"
printf '  "openwrt_target": %s,\n' "$(j_str "$openwrt_target")"
printf '  "arch": %s,\n' "$(j_str "$arch")"
printf '  "ram_mb": %s,\n' "$(j_num "$ram_mb")"
printf '  "package_manager": %s,\n' "$(j_str "$pkg_mgr")"
printf '  "packages": {\n'
printf '    "sing-box": %s,\n' "$(b "$pkg_singbox")"
printf '    "https-dns-proxy": %s,\n' "$(b "$pkg_httpsdns")"
printf '    "kmod-nft-tproxy": %s,\n' "$(b "$pkg_nft_tproxy")"
printf '    "kmod-nft-queue": %s,\n' "$(b "$pkg_nft_queue")"
printf '    "jq": %s,\n' "$(b "$pkg_jq")"
printf '    "curl": %s\n' "$(b "$pkg_curl")"
printf '  },\n'
printf '  "singbox_version": %s,\n' "$(j_str "$singbox_version")"
printf '  "config": {\n'
printf '    "present": %s,\n' "$(b "$config_present")"
printf '    "valid": %s,\n' "$(b "$config_valid")"
printf '    "outbound_count": %s,\n' "$(j_num "$outbound_count")"
printf '    "outbound_tags": %s,\n' "$(j_str "$outbound_tags")"
printf '    "has_auto_failover": %s\n' "$(b "$has_failover")"
printf '  },\n'
printf '  "rules": { "present": %s },\n' "$(b "$rules_present")"
printf '  "tproxy": { "installed": %s, "running": %s },\n' "$(b "$tproxy_installed")" "$(b "$tproxy_running")"
printf '  "dns": {\n'
printf '    "peerdns": %s,\n' "$(j_str "$peerdns")"
printf '    "dnsmasq_server": %s,\n' "$(j_str "$dnsmasq_server")"
printf '    "httpsdns_port": %s,\n' "$(j_str "$httpsdns_port")"
printf '    "redirect_nft_present": %s\n' "$(b "$dns_redirect_present")"
printf '  },\n'
printf '  "zapret": { "installed": %s, "running": %s },\n' "$(b "$zapret_installed")" "$(b "$zapret_running")"
printf '  "watchdog": {\n'
printf '    "conf_present": %s,\n' "$(b "$watchdog_conf_present")"
printf '    "conf_mode": %s,\n' "$(j_str "$watchdog_conf_mode")"
printf '    "cron_count": %s\n' "$(j_num "$watchdog_cron_count")"
printf '  },\n'
printf '  "fakeip_cache_present": %s,\n' "$(b "$fakeip_cache_present")"
printf '  "skill_state_present": %s,\n' "$(b "$skill_state_present")"
printf '  "snapshot_count": %s,\n' "$(j_num "$snapshot_count")"
printf '  "probed_at": %s\n' "$(j_str "$probed_at")"
printf '}\n'
