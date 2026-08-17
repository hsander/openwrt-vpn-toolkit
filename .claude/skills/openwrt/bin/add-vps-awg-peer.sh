#!/usr/bin/env bash
# Persist and live-add one routed peer to the VPS AWG hub without interface teardown.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: bin/add-vps-awg-peer.sh --ssh-alias <trusted-alias> --peer-name <home|router-001|router-002>
  --peer-public-key <key> --peer-ip <10.69.0.x> --peer-lan <cidr>
  [--paired-lan <cidr>] [--interface awg-hub]
EOF
  exit 64
}

ssh_alias=""; peer_name=""; peer_public_key=""; peer_ip=""; peer_lan=""
paired_lan=""; interface="awg-hub"
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --peer-name) peer_name="${2:-}"; shift 2 ;;
    --peer-public-key) peer_public_key="${2:-}"; shift 2 ;;
    --peer-ip) peer_ip="${2:-}"; shift 2 ;;
    --peer-lan) peer_lan="${2:-}"; shift 2 ;;
    --paired-lan) paired_lan="${2:-}"; shift 2 ;;
    --interface) interface="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
[[ "$peer_name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || exit 13
[[ "$peer_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || exit 13
[[ "$peer_ip" =~ ^10\.69\.0\.([0-9]{1,3})$ ]] || exit 13
(( BASH_REMATCH[1] >= 2 && BASH_REMATCH[1] <= 254 )) || exit 13
[[ "$peer_lan" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] || exit 13
if [ -n "$paired_lan" ]; then
  [[ "$paired_lan" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] || exit 13
fi
[[ "$interface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || exit 13
paired_arg="${paired_lan:--}"

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 "$ssh_alias" 'bash -s' -- "$interface" "$peer_name" \
  "$peer_public_key" "$peer_ip" "$peer_lan" "$paired_arg" "$ssh_alias" <<'REMOTE_SH'
set -euo pipefail
interface="$1"; peer_name="$2"; peer_public_key="$3"; peer_ip="$4"
peer_lan="$5"; paired_lan="$6"; ssh_alias="$7"
[ "$paired_lan" != - ] || paired_lan=""
config="/etc/amnezia/amneziawg/$interface.conf"
unit="awg-quick@$interface.service"
begin_marker="# openwrt-skill-peer-begin: $peer_name"
end_marker="# openwrt-skill-peer-end: $peer_name"
sudo -n true
sudo grep -Fq '# managed by openwrt-skill: resilient-awg-hub' "$config"
sudo systemctl is-active --quiet "$unit"
ip link show dev "$interface" >/dev/null
default_before="$(ip -4 route show default)"

if sudo grep -Fxq "$begin_marker" "$config"; then
  block="$(sudo sed -n "/^${begin_marker//\//\\\/}$/,/^${end_marker//\//\\\/}$/p" "$config")"
  printf '%s\n' "$block" | grep -Fq "PublicKey = $peer_public_key"
  printf '%s\n' "$block" | grep -Fq "AllowedIPs = $peer_ip/32, $peer_lan"
  sudo awg show "$interface" peers | grep -Fxq "$peer_public_key"
  # Idempotent repair: older runs may have installed the peer before the
  # narrow UFW relay/LAN forwarding rules were added.
  sudo ufw route allow in on "$interface" out on "$interface" from 10.69.0.0/24 to "$peer_lan" comment "openwrt-skill overlay to $peer_name" >/dev/null || true
  sudo ufw route allow in on "$interface" out on "$interface" from "$peer_lan" to 10.69.0.0/24 comment "openwrt-skill $peer_name to overlay" >/dev/null || true
  if [ -n "$paired_lan" ]; then
    sudo ufw route allow in on "$interface" out on "$interface" from "$peer_lan" to "$paired_lan" comment "openwrt-skill $peer_name to paired" >/dev/null || true
    sudo ufw route allow in on "$interface" out on "$interface" from "$paired_lan" to "$peer_lan" comment "openwrt-skill paired to $peer_name" >/dev/null || true
  fi
  echo "vps_awg_peer=already_configured"
  echo "peer_name=$peer_name"
  exit 0
fi

sudo awg show "$interface" allowed-ips | grep -Fq "$peer_ip/32" && {
  echo "peer_ip_already_in_use=true" >&2; exit 13;
}
sudo awg show "$interface" allowed-ips | grep -Fq "$peer_lan" && {
  echo "peer_lan_already_in_use=true" >&2; exit 13;
}
if ip -4 route show "$peer_lan" | grep -q .; then
  echo "peer_lan_route_already_exists=true" >&2
  exit 13
fi
# Every peer needs relay-to-LAN forwarding.  An optional paired LAN adds the
# second site-to-site pair (router-001 <-> home, etc.).
sudo ufw --dry-run route allow in on "$interface" out on "$interface" from 10.69.0.0/24 to "$peer_lan" >/dev/null
sudo ufw --dry-run route allow in on "$interface" out on "$interface" from "$peer_lan" to 10.69.0.0/24 >/dev/null
if [ -n "$paired_lan" ]; then
  sudo ufw --dry-run route allow in on "$interface" out on "$interface" from "$peer_lan" to "$paired_lan" >/dev/null
  sudo ufw --dry-run route allow in on "$interface" out on "$interface" from "$paired_lan" to "$peer_lan" >/dev/null
fi

backup_id="vps-awg-peer-${peer_name}-$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="/var/backups/openwrt-skill/$backup_id"
sudo install -d -m 700 "$backup_dir"
sudo cp -a "$config" "$backup_dir/hub.conf.before"
sudo ufw status verbose | sudo tee "$backup_dir/ufw.before" >/dev/null
sudo chmod 600 "$backup_dir/ufw.before"
sudo bash -c "printf '%s\n' 'peer_name=$peer_name' 'peer_ip=$peer_ip' 'peer_lan=$peer_lan' 'paired_lan=$paired_lan' >'$backup_dir/manifest'"
sudo chmod 600 "$backup_dir/manifest"

success=0
route_added=0
forward_added=0
relay_forward_added=0
rollback() {
  [ "$success" = 1 ] && return 0
  sudo cp -a "$backup_dir/hub.conf.before" "$config"
  if [ "$route_added" = 1 ]; then sudo ip -4 route del "$peer_lan" dev "$interface" >/dev/null 2>&1 || true; fi
  if [ "$forward_added" = 1 ]; then
    sudo ufw --force delete route allow in on "$interface" out on "$interface" from "$peer_lan" to "$paired_lan" >/dev/null 2>&1 || true
    sudo ufw --force delete route allow in on "$interface" out on "$interface" from "$paired_lan" to "$peer_lan" >/dev/null 2>&1 || true
  fi
  if [ "$relay_forward_added" = 1 ]; then
    sudo ufw --force delete route allow in on "$interface" out on "$interface" from 10.69.0.0/24 to "$peer_lan" >/dev/null 2>&1 || true
    sudo ufw --force delete route allow in on "$interface" out on "$interface" from "$peer_lan" to 10.69.0.0/24 >/dev/null 2>&1 || true
  fi
  # Deliberately retain a transient live peer until reboot: current DKMS
  # releases have upstream faults in peer-removal/interface-teardown paths.
}
on_exit() { rollback; unset peer_public_key; }
on_signal() { trap - EXIT INT TERM HUP; on_exit; exit 130; }
trap on_exit EXIT
trap on_signal INT TERM HUP

tmp="$(sudo mktemp "$config.tmp.XXXXXX")"
sudo cp "$config" "$tmp"
sudo tee -a "$tmp" >/dev/null <<EOF

$begin_marker
[Peer]
PublicKey = $peer_public_key
AllowedIPs = $peer_ip/32, $peer_lan
$end_marker
EOF
sudo chmod 600 "$tmp"
sudo mv -f "$tmp" "$config"

sudo awg set "$interface" peer "$peer_public_key" allowed-ips "$peer_ip/32,$peer_lan"
sudo ip -4 route replace "$peer_lan" dev "$interface" metric 20
route_added=1
sudo ufw route allow in on "$interface" out on "$interface" from 10.69.0.0/24 to "$peer_lan" comment "openwrt-skill overlay to $peer_name"
sudo ufw route allow in on "$interface" out on "$interface" from "$peer_lan" to 10.69.0.0/24 comment "openwrt-skill $peer_name to overlay"
relay_forward_added=1
if [ -n "$paired_lan" ]; then
  sudo ufw route allow in on "$interface" out on "$interface" from "$peer_lan" to "$paired_lan" comment "openwrt-skill $peer_name to paired"
  sudo ufw route allow in on "$interface" out on "$interface" from "$paired_lan" to "$peer_lan" comment "openwrt-skill paired to $peer_name"
  forward_added=1
fi

sudo awg show "$interface" peers | grep -Fxq "$peer_public_key"
sudo awg show "$interface" allowed-ips | grep -Fq "$peer_ip/32"
sudo awg show "$interface" allowed-ips | grep -Fq "$peer_lan"
ip -4 route show "$peer_lan" | grep -Fq "dev $interface"
[ "$(ip -4 route show default)" = "$default_before" ]

success=1
trap - EXIT INT TERM HUP
unset peer_public_key
echo "vps_awg_peer=added"
echo "peer_name=$peer_name"
echo "peer_ip=$peer_ip"
echo "peer_lan=$peer_lan"
echo "default_route_unchanged=true"
echo "snapshot=$backup_id"
echo "rollback=bin/rollback-vps-awg-peer.sh --ssh-alias $ssh_alias --snapshot $backup_id"
REMOTE_SH
