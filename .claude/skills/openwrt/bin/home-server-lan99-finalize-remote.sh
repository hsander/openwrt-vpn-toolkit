#!/bin/sh
# Router-independent home-server LAN99 finalizer. Installed and run as root.

set -eu

phase="${1:-}"
ethernet_uuid='08428cd5-3e84-37ae-9112-8b9863e956aa'
wifi_uuid='53486aa4-d172-4d85-b29a-4f5f83ba8df8'
state_dir='/var/lib/vpn-kit-lan99-finalize'
rollback='/usr/local/sbin/vpn-kit-lan99-finalize-rollback'
timer='vpn-kit-lan99-finalize-rollback.timer'

validate_state() {
  [ "$(ip -4 -o address show dev eno1 | awk '{print $4}')" = 192.168.99.50/24 ]
  ! ip -4 -o address show | grep -q '192\.168\.1\.'
  ip -4 route show default | grep -q '^default via 192\.168\.99\.1 dev eno1'
  ! grep -Rqs -- '192\.168\.1\.' \
    /opt/openclaw/docker-compose.yml \
    /opt/openclaw-data/config/openclaw.json \
    /opt/openclaw-data/config/agents/main/agent/models.json \
    /opt/remna-bot/docker-compose.yml \
    /opt/remnawave/caddy/Caddyfile
  docker ps --format '{{.Names}} {{.Status}}' | grep -q '^openclaw-openclaw-gateway-1 Up '
  docker ps --format '{{.Names}} {{.Status}}' | grep -q '^remna-telegram-bot Up '
  docker ps --format '{{.Names}} {{.Status}}' | grep -q '^caddy Up '
}

case "$phase" in
  prepare)
    mkdir -p "$state_dir" /var/backups/vpn-kit-lan99-finalize
    chmod 0700 "$state_dir" /var/backups/vpn-kit-lan99-finalize
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup="/var/backups/vpn-kit-lan99-finalize/$stamp"
    mkdir -p "$backup"
    chmod 0700 "$backup"
    tar -czpf "$backup/files.tar.gz" \
      /etc/NetworkManager/system-connections \
      /etc/netplan/90-NM-08428cd5-3e84-37ae-9112-8b9863e956aa.yaml \
      /opt/openclaw/docker-compose.yml \
      /opt/openclaw-data/config/openclaw.json \
      /opt/openclaw-data/config/agents/main/agent/models.json \
      /opt/remna-bot/docker-compose.yml \
      /opt/remnawave/caddy/Caddyfile
    printf '%s\n' "$backup" > "$state_dir/backup"
    printf 'prepared\n' > "$state_dir/state"
    printf 'state=prepared\nbackup=%s\n' "$backup"
    ;;
  cutover)
    [ "$(cat "$state_dir/state")" = prepared ]
    backup="$(cat "$state_dir/backup")"
    [ -f "$backup/files.tar.gz" ]
    systemctl stop "$timer" vpn-kit-lan99-finalize-rollback.service >/dev/null 2>&1 || true
    systemctl reset-failed "$timer" vpn-kit-lan99-finalize-rollback.service >/dev/null 2>&1 || true
    systemd-run --quiet --unit=vpn-kit-lan99-finalize-rollback --on-active=5min \
      --timer-property=AccuracySec=1s "$rollback" "$backup"
    printf 'applying\n' > "$state_dir/state"

    nmcli connection modify uuid "$ethernet_uuid" \
      ipv4.method manual ipv4.addresses '192.168.99.50/24' \
      ipv4.gateway '192.168.99.1' ipv4.dns '192.168.99.1' ipv4.ignore-auto-dns yes
    nmcli connection up uuid "$ethernet_uuid"
    nmcli connection modify uuid "$wifi_uuid" connection.autoconnect no
    nmcli connection down uuid "$wifi_uuid" >/dev/null 2>&1 || true

    for file in \
      /opt/openclaw/docker-compose.yml \
      /opt/openclaw-data/config/openclaw.json \
      /opt/openclaw-data/config/agents/main/agent/models.json \
      /opt/remna-bot/docker-compose.yml \
      /opt/remnawave/caddy/Caddyfile; do
      sed -i \
        -e 's/192\.168\.1\.0\/24/192.168.99.0\/24/g' \
        -e 's/192\.168\.1\.50/192.168.99.50/g' \
        -e 's/192\.168\.1\.165/192.168.99.165/g' \
        -e 's/192\.168\.1\.104/192.168.99.104/g' "$file"
    done

    python3 -m json.tool /opt/openclaw-data/config/openclaw.json >/dev/null
    python3 -m json.tool /opt/openclaw-data/config/agents/main/agent/models.json >/dev/null
    (cd /opt/openclaw && docker compose config -q)
    (cd /opt/remna-bot && docker compose config -q)
    docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

    (cd /opt/openclaw && docker compose up -d --force-recreate openclaw-gateway)
    (cd /opt/remna-bot && docker compose up -d --force-recreate remna-bot)
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    printf 'applied_unconfirmed\n' > "$state_dir/state"
    echo state=applied_unconfirmed
    ;;
  validate)
    validate_state
    echo validation=ok
    ;;
  status)
    printf 'state=%s\n' "$(cat "$state_dir/state" 2>/dev/null || echo unknown)"
    printf 'backup=%s\n' "$(cat "$state_dir/backup" 2>/dev/null || true)"
    printf 'timer=%s\n' "$(systemctl is-active "$timer" 2>/dev/null || true)"
    ip -4 -o address show
    ip -4 route show default
    ;;
  confirm)
    [ "$(cat "$state_dir/state")" = applied_unconfirmed ]
    validate_state
    systemctl stop "$timer" >/dev/null
    systemctl reset-failed "$timer" vpn-kit-lan99-finalize-rollback.service >/dev/null 2>&1 || true
    printf 'committed\n' > "$state_dir/state"
    echo state=committed
    ;;
  rollback)
    backup="$(cat "$state_dir/backup")"
    exec "$rollback" "$backup"
    ;;
  *) exit 13 ;;
esac
