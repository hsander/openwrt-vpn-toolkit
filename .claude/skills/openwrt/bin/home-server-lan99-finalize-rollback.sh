#!/bin/sh
# Installed on home-server before removing the final 192.168.1.0/24 references.

set -eu

backup="${1:-}"
case "$backup" in /var/backups/vpn-kit-lan99-finalize/*) ;; *) exit 13 ;; esac
[ -f "$backup/files.tar.gz" ]

ethernet_uuid="${HOME_SERVER_ETHERNET_UUID:-00000000-0000-0000-0000-000000000001}"
wifi_uuid="${HOME_SERVER_WIFI_UUID:-00000000-0000-0000-0000-000000000002}"
state_dir='/var/lib/vpn-kit-lan99-finalize'

systemctl stop vpn-kit-lan99-finalize-rollback.timer >/dev/null 2>&1 || true
tar -xzpf "$backup/files.tar.gz" -C /
nmcli connection reload
nmcli connection up uuid "$ethernet_uuid"
nmcli connection up uuid "$wifi_uuid" >/dev/null 2>&1 || true

(cd /opt/openclaw && docker compose up -d --force-recreate openclaw-gateway) >/dev/null 2>&1 || true
(cd /opt/remna-bot && docker compose up -d --force-recreate remna-bot) >/dev/null 2>&1 || true
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true

mkdir -p "$state_dir"
printf 'rolled_back\n' > "$state_dir/state"
