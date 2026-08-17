#!/usr/bin/env bash
# Safe client for the home-server LAN99 finalizer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_USER="${HOME_SERVER_USER:-root}"
SERVER_HOST="${HOME_SERVER_PRIMARY_HOST:-192.168.99.50}"
REMOTE='/usr/local/sbin/vpn-kit-lan99-finalize'
ROLLBACK_REMOTE='/usr/local/sbin/vpn-kit-lan99-finalize-rollback'

phase=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) phase="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: $0 --phase prepare|cutover|status|confirm|rollback"; exit 0 ;;
    *) echo "finalize-home-server-lan99: unknown arg: $1" >&2; exit 13 ;;
  esac
done
[[ "$phase" =~ ^(prepare|cutover|status|confirm|rollback)$ ]] || exit 13

ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)
server_ssh() { ssh "${ssh_opts[@]}" "$SERVER_USER@$SERVER_HOST" "$1"; }

if [[ "$phase" == prepare ]]; then
  scp -q "${ssh_opts[@]}" \
    "$SCRIPT_DIR/home-server-lan99-finalize-remote.sh" \
    "$SCRIPT_DIR/home-server-lan99-finalize-rollback.sh" \
    "$SERVER_USER@$SERVER_HOST:/tmp/"
  server_ssh "sudo install -o root -g root -m 0700 /tmp/home-server-lan99-finalize-remote.sh '$REMOTE'; sudo install -o root -g root -m 0700 /tmp/home-server-lan99-finalize-rollback.sh '$ROLLBACK_REMOTE'; rm -f /tmp/home-server-lan99-finalize-remote.sh /tmp/home-server-lan99-finalize-rollback.sh; sudo '$REMOTE' prepare"
  echo "rollback=ssh $SERVER_USER@$SERVER_HOST sudo $REMOTE rollback"
  exit 0
fi

server_ssh "sudo '$REMOTE' '$phase'"

if [[ "$phase" == cutover ]]; then
  for _ in {1..30}; do
    if server_ssh "sudo '$REMOTE' validate" >/dev/null 2>&1; then
      echo validation=ok
      exit 0
    fi
    sleep 2
  done
  echo 'finalize-home-server-lan99: validation failed; rollback remains armed' >&2
  exit 20
fi
