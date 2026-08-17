#!/usr/bin/env bash
# Restore the VPS network/service state saved by install-vps-awg-hub.sh.

set -euo pipefail

usage() {
  echo "Usage: bin/rollback-vps-awg-hub.sh --ssh-alias <trusted-alias> --snapshot <vps-awg-hub-YYYYMMDDTHHMMSSZ> [--interface awg-hub]" >&2
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
[[ "$snapshot" =~ ^vps-awg-hub-[0-9]{8}T[0-9]{6}Z$ ]] || exit 13
[[ "$interface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || exit 13

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 "$ssh_alias" 'bash -s' -- "$snapshot" "$interface" <<'REMOTE_SH'
set -euo pipefail
snapshot="$1"; interface="$2"
backup_dir="/var/backups/openwrt-skill/$snapshot"
config="/etc/amnezia/amneziawg/$interface.conf"
sysctl_file=/etc/sysctl.d/90-openwrt-skill-awg-hub.conf
unit="awg-quick@$interface.service"
sudo -n true
sudo test -f "$backup_dir/manifest"

peers_present=0
if ip link show dev "$interface" >/dev/null 2>&1 && sudo awg show "$interface" peers 2>/dev/null | grep -q .; then
  peers_present=1
fi

# First make the relay unreachable and prevent it from returning at boot.
sudo ufw --force delete allow 443/udp >/dev/null 2>&1 || true
sudo systemctl disable "$unit" >/dev/null 2>&1 || true

if [ "$peers_present" = 0 ]; then
  sudo systemctl stop "$unit" >/dev/null 2>&1 || true
  runtime_state=stopped
else
  # Current AWG DKMS releases have upstream teardown reports. Do not remove a
  # live interface containing peers; firewall it now and finish on reboot.
  runtime_state=blocked_until_reboot
fi

sudo install -d -m 700 "$(dirname "$config")"
if sudo test -f "$backup_dir/hub.conf.before"; then
  sudo cp -a "$backup_dir/hub.conf.before" "$config"
else
  sudo rm -f "$config"
fi
if sudo test -f "$backup_dir/sysctl.before"; then
  sudo cp -a "$backup_dir/sysctl.before" "$sysctl_file"
else
  sudo rm -f "$sysctl_file"
fi
sudo sysctl --system >/dev/null

enabled_before="$(sudo cat "$backup_dir/unit.enabled" 2>/dev/null || true)"
active_before="$(sudo cat "$backup_dir/unit.active" 2>/dev/null || true)"
if [ "$enabled_before" = enabled ]; then sudo systemctl enable "$unit" >/dev/null; fi
if [ "$active_before" = active ] && sudo test -f "$config" && [ "$peers_present" = 0 ]; then
  sudo systemctl start "$unit"
fi

echo "vps_awg_hub=rolled_back"
echo "snapshot=$snapshot"
echo "runtime_state=$runtime_state"
echo "packages_retained=true"
if [ "$runtime_state" = blocked_until_reboot ]; then echo "reboot_required=true"; else echo "reboot_required=false"; fi
REMOTE_SH
