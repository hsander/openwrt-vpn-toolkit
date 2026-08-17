#!/usr/bin/env bash
# Restore one VPS peer config snapshot without invoking risky live peer removal.

set -euo pipefail

usage() {
  echo "Usage: bin/rollback-vps-awg-peer.sh --ssh-alias <trusted-alias> --snapshot <vps-awg-peer-NAME-YYYYMMDDTHHMMSSZ> [--interface awg-hub]" >&2
  exit 64
}

ssh_alias=""; snapshot=""; interface="awg-hub"
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --snapshot) snapshot="${2:-}"; shift 2 ;;
    --interface) interface="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
[[ "$snapshot" =~ ^vps-awg-peer-[A-Za-z0-9_-]{1,32}-[0-9]{8}T[0-9]{6}Z$ ]] || exit 13
[[ "$interface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || exit 13

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 "$ssh_alias" 'bash -s' -- "$snapshot" "$interface" <<'REMOTE_SH'
set -euo pipefail
snapshot="$1"; interface="$2"
backup_dir="/var/backups/openwrt-skill/$snapshot"
manifest="$backup_dir/manifest"
config="/etc/amnezia/amneziawg/$interface.conf"
sudo -n true
sudo test -f "$manifest"
sudo test -f "$backup_dir/hub.conf.before"

peer_name="$(sudo sed -n 's/^peer_name=//p' "$manifest")"
peer_lan="$(sudo sed -n 's/^peer_lan=//p' "$manifest")"
paired_lan="$(sudo sed -n 's/^paired_lan=//p' "$manifest")"
[[ "$peer_name" =~ ^[A-Za-z0-9_-]{1,32}$ ]]
[[ "$peer_lan" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]]
if [ -n "$paired_lan" ]; then [[ "$paired_lan" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]]; fi

sudo cp -a "$backup_dir/hub.conf.before" "$config"
sudo ip -4 route del "$peer_lan" dev "$interface" >/dev/null 2>&1 || true
if [ -n "$paired_lan" ]; then
  sudo ufw --force delete route allow in on "$interface" out on "$interface" from "$peer_lan" to "$paired_lan" >/dev/null 2>&1 || true
  sudo ufw --force delete route allow in on "$interface" out on "$interface" from "$paired_lan" to "$peer_lan" >/dev/null 2>&1 || true
fi

# The peer remains only in volatile kernel state until reboot. This avoids the
# reported DKMS peer-removal/teardown crash path while persistent routing and
# firewall access are already gone.
echo "vps_awg_peer=rolled_back"
echo "peer_name=$peer_name"
echo "persistent_config=restored"
echo "forwarding_removed=true"
echo "reboot_required=true"
REMOTE_SH
