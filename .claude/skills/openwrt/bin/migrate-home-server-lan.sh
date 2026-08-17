#!/usr/bin/env bash
# Home-server gateway/DNS transaction with an autonomous systemd rollback timer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLBACK_SOURCE="$SCRIPT_DIR/home-server-lan99-rollback.sh"
SERVER_USER="${HOME_SERVER_USER:-horuzhenko}"
PRIMARY_HOST="${HOME_SERVER_PRIMARY_HOST:-192.168.99.50}"
RECOVERY_HOST="${HOME_SERVER_RECOVERY_HOST:-192.168.1.103}"
CONNECTION_UUID='08428cd5-3e84-37ae-9112-8b9863e956aa'
STATE_DIR='/var/lib/vpn-kit-lan99-server'
ROLLBACK_REMOTE='/usr/local/sbin/vpn-kit-lan99-server-rollback'
TIMER_UNIT='vpn-kit-lan99-server-rollback.timer'

usage() {
  echo "Usage: $0 --phase prepare|cutover|status|confirm|rollback" >&2
  exit 13
}

phase=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) phase="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ "$phase" =~ ^(prepare|cutover|status|confirm|rollback)$ ]] || usage

ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

server_ssh() {
  local host="$1" command="$2"
  ssh "${ssh_opts[@]}" "$SERVER_USER@$host" "$command"
}

server_scp() {
  local source="$1" host="$2" target="$3"
  scp -q "${ssh_opts[@]}" "$source" "$SERVER_USER@$host:$target"
}

reachable_host() {
  local host
  for host in "$PRIMARY_HOST" "$RECOVERY_HOST"; do
    if server_ssh "$host" true >/dev/null 2>&1; then printf '%s' "$host"; return 0; fi
  done
  return 1
}

case "$phase" in
  prepare)
    host="$(reachable_host)" || { echo 'home-server migration: no SSH recovery path' >&2; exit 20; }
    server_scp "$ROLLBACK_SOURCE" "$host" /tmp/vpn-kit-lan99-server-rollback
    server_ssh "$host" "
set -eu
sudo install -o root -g root -m 0700 /tmp/vpn-kit-lan99-server-rollback '$ROLLBACK_REMOTE'
rm -f /tmp/vpn-kit-lan99-server-rollback
stamp=\$(date -u +%Y%m%dT%H%M%SZ)
backup=/var/backups/vpn-kit-lan99-server/\$stamp
sudo mkdir -p \"\$backup\" '$STATE_DIR'
sudo chmod 0700 /var/backups/vpn-kit-lan99-server \"\$backup\" '$STATE_DIR'
sudo cp -a /etc/NetworkManager/system-connections \"\$backup/\"
sudo systemctl stop vpn-kit-lan99-server-selftest.timer vpn-kit-lan99-server-selftest.service >/dev/null 2>&1 || true
sudo systemctl reset-failed vpn-kit-lan99-server-selftest.timer vpn-kit-lan99-server-selftest.service >/dev/null 2>&1 || true
sudo systemd-run --quiet --unit=vpn-kit-lan99-server-selftest --on-active=1s /bin/true
sleep 2
[ \"\$(systemctl show vpn-kit-lan99-server-selftest.service -p Result --value)\" = success ]
sudo systemctl stop vpn-kit-lan99-server-selftest.timer >/dev/null 2>&1 || true
printf '%s\n' prepared | sudo tee '$STATE_DIR/state' >/dev/null
printf 'state=prepared\\nbackup=%s\\nrollback=%s\\ntimer_selftest=ok\\n' \"\$backup\" '$ROLLBACK_REMOTE'
"
    ;;
  cutover)
    host="$(reachable_host)" || { echo 'home-server migration: no SSH recovery path' >&2; exit 20; }
    server_ssh "$host" "
set -eu
sudo test -x '$ROLLBACK_REMOTE'
[ \"\$(sudo cat '$STATE_DIR/state' 2>/dev/null)\" = prepared ]
sudo systemctl stop '$TIMER_UNIT' vpn-kit-lan99-server-rollback.service >/dev/null 2>&1 || true
sudo systemctl reset-failed '$TIMER_UNIT' vpn-kit-lan99-server-rollback.service >/dev/null 2>&1 || true
sudo systemd-run --quiet --unit=vpn-kit-lan99-server-rollback --on-active=5min \
  --timer-property=AccuracySec=1s '$ROLLBACK_REMOTE'
printf '%s\n' applying | sudo tee '$STATE_DIR/state' >/dev/null
sudo nmcli connection modify uuid '$CONNECTION_UUID' \
  ipv4.method manual \
  ipv4.addresses '192.168.1.50/24,192.168.99.50/24' \
  ipv4.gateway '192.168.99.1' \
  ipv4.dns '192.168.99.1' \
  ipv4.ignore-auto-dns yes
sudo nmcli connection up uuid '$CONNECTION_UUID'
printf '%s\n' applied_unconfirmed | sudo tee '$STATE_DIR/state' >/dev/null
"
    for _ in {1..20}; do
      if server_ssh "$PRIMARY_HOST" true >/dev/null 2>&1; then
        echo 'state=applied_unconfirmed'
        echo "rollback=ssh $SERVER_USER@$RECOVERY_HOST 'sudo $ROLLBACK_REMOTE'"
        exit 0
      fi
      sleep 1
    done
    echo 'home-server migration: primary SSH did not return; timer remains armed' >&2
    exit 20
    ;;
  status)
    host="$(reachable_host)" || { echo 'state=unreachable'; exit 20; }
    server_ssh "$host" "
set -eu
printf 'state=%s\\n' \"\$(sudo cat '$STATE_DIR/state' 2>/dev/null || echo unknown)\"
printf 'addresses=%s\\n' \"\$(nmcli -g ipv4.addresses connection show uuid '$CONNECTION_UUID')\"
printf 'gateway=%s\\n' \"\$(nmcli -g ipv4.gateway connection show uuid '$CONNECTION_UUID')\"
printf 'dns=%s\\n' \"\$(nmcli -g ipv4.dns connection show uuid '$CONNECTION_UUID')\"
printf 'timer=%s\\n' \"\$(systemctl is-active '$TIMER_UNIT' 2>/dev/null || true)\"
ip -4 route show default
"
    ;;
  confirm)
    server_ssh "$PRIMARY_HOST" "
set -eu
[ \"\$(sudo cat '$STATE_DIR/state')\" = applied_unconfirmed ]
[ \"\$(nmcli -g ipv4.gateway connection show uuid '$CONNECTION_UUID')\" = 192.168.99.1 ]
sudo systemctl stop '$TIMER_UNIT' >/dev/null
sudo systemctl reset-failed '$TIMER_UNIT' vpn-kit-lan99-server-rollback.service >/dev/null 2>&1 || true
printf '%s\n' committed | sudo tee '$STATE_DIR/state' >/dev/null
echo state=committed
"
    ;;
  rollback)
    host="$(reachable_host)" || { echo 'home-server rollback: no SSH path; wait for timer' >&2; exit 20; }
    server_ssh "$host" "sudo '$ROLLBACK_REMOTE'"
    echo 'state=rolled_back'
    ;;
esac
