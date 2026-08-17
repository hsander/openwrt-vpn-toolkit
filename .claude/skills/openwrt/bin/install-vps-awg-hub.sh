#!/usr/bin/env bash
# Install a pinned, isolated AmneziaWG relay hub on an Ubuntu VPS.

set -euo pipefail

usage() {
  echo "Usage: bin/install-vps-awg-hub.sh --ssh-alias <trusted-alias> [--interface awg-hub] [--address 10.69.0.1/24]" >&2
  exit 64
}

ssh_alias=""; interface="awg-hub"; address="10.69.0.1/24"
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    --interface) interface="${2:-}"; shift 2 ;;
    --address) address="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13
[[ "$interface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || exit 13
[[ "$address" =~ ^10\.69\.0\.1/24$ ]] || exit 13

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 "$ssh_alias" 'bash -s' -- "$interface" "$address" "$ssh_alias" <<'REMOTE_SH'
set -euo pipefail
interface="$1"; address="$2"; ssh_alias="$3"
[ "$(id -u)" -ne 0 ]
sudo -n true
[ -r /etc/os-release ] && . /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ]

config_dir=/etc/amnezia/amneziawg
config="$config_dir/$interface.conf"
unit="awg-quick@$interface.service"
sysctl_file=/etc/sysctl.d/90-openwrt-skill-awg-hub.conf
backup_id="vps-awg-hub-$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="/var/backups/openwrt-skill/$backup_id"
sudo install -d -m 700 "$backup_dir"

sudo bash -c "dpkg-query -W -f='\${binary:Package}\t\${Version}\n' >'$backup_dir/packages.tsv'"
sudo systemctl is-enabled "$unit" >"/tmp/$backup_id.enabled" 2>/dev/null || true
sudo systemctl is-active "$unit" >"/tmp/$backup_id.active" 2>/dev/null || true
sudo install -m 600 "/tmp/$backup_id.enabled" "$backup_dir/unit.enabled"
sudo install -m 600 "/tmp/$backup_id.active" "$backup_dir/unit.active"
rm -f "/tmp/$backup_id.enabled" "/tmp/$backup_id.active"
sudo ufw status verbose | sudo tee "$backup_dir/ufw.txt" >/dev/null
sudo chmod 600 "$backup_dir/ufw.txt"
[ ! -e "$config" ] || sudo cp -a "$config" "$backup_dir/hub.conf.before"
[ ! -e "$sysctl_file" ] || sudo cp -a "$sysctl_file" "$backup_dir/sysctl.before"
sudo bash -c "printf '%s\n' 'created_by=openwrt-skill' 'interface=$interface' 'address=$address' 'packages_left_installed_on_runtime_rollback=true' >'$backup_dir/manifest'"
sudo chmod 600 "$backup_dir/manifest"

if sudo grep -Fq '# managed by openwrt-skill: resilient-awg-hub' "$config" 2>/dev/null; then
  # Split only at the first assignment delimiter; base64 keys end in `=` and
  # must retain that padding for awg pubkey.
  private_key="$(sudo sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$config" | head -n 1)"
  public_key="$(printf '%s' "$private_key" | sudo awg pubkey)"
  unset private_key
  sudo systemctl is-active --quiet "$unit"
  sudo ss -H -lun | grep -Eq '(^|[[:space:]])(\*|0\.0\.0\.0|\[::\]|\[::0\]):443([[:space:]]|$)'
  # Repair the narrow overlay forwarding rule on idempotent re-runs.  Older
  # versions created the hub before this rule existed, leaving handshakes up
  # but all routed packets dropped by the VPS deny-by-default policy.
  sudo ufw route allow in on "$interface" out on "$interface" from 10.69.0.0/24 to 10.69.0.0/24 comment 'openwrt-skill awg overlay' >/dev/null || true
  echo "vps_awg_hub=already_configured"
  echo "server_public_key=$public_key"
  echo "interface=$interface"
  echo "snapshot=$backup_id"
  exit 0
fi

[ ! -e "$config" ] || { echo "unmanaged_config_exists=$config" >&2; exit 13; }
if sudo ss -H -lun | awk '{print $5}' | grep -Eq '(^|:|\])443$'; then
  echo "udp_443=busy" >&2
  exit 13
fi
if sudo ufw status | grep -Eiq '443/udp|443[[:space:]]+udp'; then
  echo "ufw_udp_443_rule=already_present" >&2
  exit 13
fi
default_before="$(ip -4 route show default)"

work_dir="$(mktemp -d /tmp/openwrt-skill-awg.XXXXXX)"
chmod 700 "$work_dir"
success=0
ufw_added=0
overlay_forward_added=0
interface_started=0
private_key=""
public_key=""

rollback() {
  [ "$success" = 1 ] && return 0
  if [ "$interface_started" = 1 ]; then
    sudo systemctl disable --now "$unit" >/dev/null 2>&1 || true
  fi
  if [ "$ufw_added" = 1 ]; then
    sudo ufw --force delete allow 443/udp >/dev/null 2>&1 || true
  fi
  if [ "$overlay_forward_added" = 1 ]; then
    sudo ufw --force delete route allow in on "$interface" out on "$interface" from 10.69.0.0/24 to 10.69.0.0/24 >/dev/null 2>&1 || true
  fi
  if [ -f "$backup_dir/hub.conf.before" ]; then
    sudo cp -a "$backup_dir/hub.conf.before" "$config"
  else
    sudo rm -f "$config"
  fi
  if [ -f "$backup_dir/sysctl.before" ]; then
    sudo cp -a "$backup_dir/sysctl.before" "$sysctl_file"
  else
    sudo rm -f "$sysctl_file"
  fi
  sudo sysctl --system >/dev/null 2>&1 || true
}
cleanup() { rollback; rm -rf "$work_dir"; unset private_key public_key; }
on_signal() { trap - EXIT INT TERM HUP; cleanup; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP

base_url='https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/pool/main/a'
tools_name='amneziawg-tools_1.0.20210914-0~202608130144+ee0f0a9~ubuntu24.04.1_amd64.deb'
dkms_name='amneziawg-dkms_1.0.0-0~202608140352+4680320~ubuntu24.04.1_all.deb'
tools_version='1.0.20210914-0~202608130144+ee0f0a9~ubuntu24.04.1'
dkms_version='1.0.0-0~202608140352+4680320~ubuntu24.04.1'
if [ "$(dpkg-query -W -f='${Version}' amneziawg-tools 2>/dev/null || true)" = "$tools_version" ] && \
   [ "$(dpkg-query -W -f='${Version}' amneziawg-dkms 2>/dev/null || true)" = "$dkms_version" ] && \
   sudo dkms status -m amneziawg -v 1.0.0 | grep -Fq "$(uname -r)"; then
  echo 'packages=already_exact'
else
  curl -fsSLo "$work_dir/tools.deb" "$base_url/amneziawg/$tools_name"
  curl -fsSLo "$work_dir/dkms.deb" "$base_url/amneziawg-linux-kmod/$dkms_name"
  printf '%s  %s\n' \
    '2c924076be2ba217eea04f9693291f01c5307a9be5aeee60d04525a50ff2804f' "$work_dir/tools.deb" \
    'e4dae7515dbb35d5a900f79c04f0a5551449d2bf2e4872a3d08fd22c858aa078' "$work_dir/dkms.deb" | sha256sum -c -
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dkms "linux-headers-$(uname -r)"
  sudo dpkg -i "$work_dir/dkms.deb" "$work_dir/tools.deb"
fi
sudo dkms status -m amneziawg -v 1.0.0 | grep -Fq "$(uname -r)"
sudo modprobe amneziawg
[ -d /sys/module/amneziawg ]
command -v awg >/dev/null
command -v awg-quick >/dev/null

private_key="$(sudo awg genkey)"
public_key="$(printf '%s' "$private_key" | sudo awg pubkey)"
sudo install -d -m 700 "$config_dir"
sudo tee "$config.tmp" >/dev/null <<EOF
# managed by openwrt-skill: resilient-awg-hub
[Interface]
PrivateKey = $private_key
Address = $address
ListenPort = 443
MTU = 1360
Jc = 4
Jmin = 40
Jmax = 70
S1 = 42
S2 = 16
S3 = 40
S4 = 100
H1 = 65236728
H2 = 2314199929
H3 = 830645635
H4 = 380976151
I1 = <b 0x1a2d0100000100000000000109696e666572656e6365><t><r 15>
EOF
sudo chmod 600 "$config.tmp"
sudo mv -f "$config.tmp" "$config"
unset private_key

printf '%s\n' 'net.ipv4.ip_forward=1' | sudo tee "$sysctl_file.tmp" >/dev/null
sudo chmod 644 "$sysctl_file.tmp"
sudo mv -f "$sysctl_file.tmp" "$sysctl_file"
sudo sysctl -q -p "$sysctl_file"

sudo ufw allow 443/udp comment 'openwrt-skill awg-hub'
ufw_added=1
# Permit only overlay-to-overlay traffic.  The VPS remains closed for
# forwarding between AWG and eth0/docker; per-peer LAN rules are separate.
sudo ufw route allow in on "$interface" out on "$interface" from 10.69.0.0/24 to 10.69.0.0/24 comment 'openwrt-skill awg overlay'
overlay_forward_added=1
interface_started=1
sudo systemctl enable --now "$unit"
sleep 2
sudo systemctl is-active --quiet "$unit" || { echo 'verify_failed=unit_active' >&2; exit 1; }
ip link show dev "$interface" >/dev/null || { echo 'verify_failed=interface_present' >&2; exit 1; }
ip -4 address show dev "$interface" | grep -Fq "inet $address" || { echo 'verify_failed=interface_address' >&2; exit 1; }
sudo awg showconf "$interface" | grep -q '^S3 = 40$' || { echo 'verify_failed=awg_s3' >&2; exit 1; }
sudo awg showconf "$interface" | grep -q '^S4 = 100$' || { echo 'verify_failed=awg_s4' >&2; exit 1; }
sudo ss -H -lun | grep -Eq '(^|[[:space:]])(\*|0\.0\.0\.0|\[::\]|\[::0\]):443([[:space:]]|$)' || {
  echo 'verify_failed=udp_listener' >&2
  sudo ss -H -lun >&2
  exit 1
}
[ "$(ip -4 route show default)" = "$default_before" ] || { echo 'verify_failed=default_route_changed' >&2; exit 1; }
sudo ufw status | grep -Eiq '443/udp|443[[:space:]]+udp' || { echo 'verify_failed=ufw_udp_rule' >&2; exit 1; }
success=1
rm -rf "$work_dir"
trap - EXIT INT TERM HUP
echo "vps_awg_hub=installed"
echo "server_public_key=$public_key"
echo "interface=$interface"
echo "listen=udp/443"
echo "tcp_443_untouched=true"
echo "default_route_unchanged=true"
echo "snapshot=$backup_id"
echo "rollback=bin/rollback-vps-awg-hub.sh --ssh-alias $ssh_alias --snapshot $backup_id"
REMOTE_SH
