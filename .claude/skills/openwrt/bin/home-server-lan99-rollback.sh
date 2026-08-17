#!/bin/sh
# Installed on home-server before gateway cutover. Safe to run repeatedly.

set -eu

connection_uuid="${HOME_SERVER_CONNECTION_UUID:-00000000-0000-0000-0000-000000000001}"
state_dir='/var/lib/vpn-kit-lan99-server'

systemctl stop vpn-kit-lan99-server-rollback.timer >/dev/null 2>&1 || true
nmcli connection modify uuid "$connection_uuid" \
  ipv4.method manual \
  ipv4.addresses '192.168.1.50/24,192.168.99.50/24' \
  ipv4.gateway '192.168.1.1' \
  ipv4.dns '192.168.1.1' \
  ipv4.ignore-auto-dns yes
nmcli connection up uuid "$connection_uuid"
mkdir -p "$state_dir"
printf 'rolled_back\n' > "$state_dir/state"
