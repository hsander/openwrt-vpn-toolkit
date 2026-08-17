#!/usr/bin/env bash
# Read-only audit of a Linux VPS before installing an AWG relay hub.

set -euo pipefail

usage() {
  echo "Usage: bin/audit-vps-awg-hub.sh --ssh-alias <trusted-ssh-alias>" >&2
  exit 64
}

ssh_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-alias) ssh_alias="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ "$ssh_alias" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 13

ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 \
  "$ssh_alias" 'bash -s' <<'REMOTE_SH'
set -euo pipefail

echo "audit=begin"
echo "hostname=$(hostname)"
echo "kernel=$(uname -srmo)"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "os_id=${ID:-unknown}"
  echo "os_version=${VERSION_ID:-unknown}"
  echo "os_pretty=${PRETTY_NAME:-unknown}"
fi
echo "user=$(id -un)"
if sudo -n true >/dev/null 2>&1; then
  echo "passwordless_sudo=true"
else
  echo "passwordless_sudo=false"
fi

echo "resources_begin"
free -m
df -h / /var/lib/docker 2>/dev/null || df -h /
echo "resources_end"

echo "network_begin"
ip -brief address
ip -4 route show
echo "ipv4_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
echo "network_end"

echo "listeners_begin"
sudo -n ss -H -lntup 2>/dev/null || ss -H -lntup
echo "listeners_end"

echo "tcp443_owner_begin"
tcp443="$(sudo -n ss -H -lntp '( sport = :443 )' 2>/dev/null || true)"
printf '%s\n' "$tcp443" | sed -E 's/(pid=[0-9]+,fd=[0-9]+)/pid=<redacted>,fd=<redacted>/g'
if printf '%s\n' "$tcp443" | grep -Eq '(^|[[:space:]])(\*|0.0.0.0|\[::\]|\[::0\]):443([[:space:]]|$)'; then
  echo "tcp443_listener=present"
else
  echo "tcp443_listener=absent"
fi
for path in /etc/xray /etc/sing-box /etc/remnawave /opt/remnawave; do
  if sudo -n test -d "$path"; then echo "tcp443_config_dir=$path"; fi
done
echo "tcp443_owner_end"

echo "services_begin"
for service in docker fail2ban unattended-upgrades ufw; do
  state="$(systemctl is-active "$service" 2>/dev/null || true)"
  echo "service=$service state=${state:-not-found}"
done
echo "services_end"

echo "containers_begin"
if command -v docker >/dev/null 2>&1; then
  sudo -n docker ps --format 'name={{.Names}} image={{.Image}} status={{.Status}} ports={{.Ports}}'
else
  echo "docker=absent"
fi
echo "containers_end"

echo "vless_runtime_begin"
if command -v docker >/dev/null 2>&1; then
  while IFS= read -r container; do
    [ -n "$container" ] || continue
    image="$(sudo -n docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)"
    case "$image $container" in
      *remnawave*|*xray*)
        echo "candidate_container=$container image=$image"
        sudo -n docker exec "$container" sh -c 'xray version 2>/dev/null | head -n 1 || /usr/local/bin/xray version 2>/dev/null | head -n 1 || true'
        ;;
    esac
  done < <(sudo -n docker ps --format '{{.Names}}')
fi
echo "vless_runtime_end"

echo "firewall_begin"
if command -v ufw >/dev/null 2>&1; then
  sudo -n ufw status verbose
else
  echo "ufw=absent"
fi
echo "firewall_end"

echo "awg_capability_begin"
command -v awg >/dev/null 2>&1 && echo "awg_tool=present" || echo "awg_tool=absent"
command -v wg >/dev/null 2>&1 && echo "wg_tool=present" || echo "wg_tool=absent"
command -v tcpdump >/dev/null 2>&1 && echo "tcpdump=present" || echo "tcpdump=absent"
if [ -e /dev/net/tun ]; then echo "tun_device=present"; else echo "tun_device=absent"; fi
if lsmod 2>/dev/null | grep -Eq '(^|[[:space:]])(amneziawg|wireguard)([[:space:]]|$)'; then
  echo "awg_or_wireguard_module=loaded"
else
  echo "awg_or_wireguard_module=not_loaded"
fi
if apt-cache show amneziawg-tools >/dev/null 2>&1; then
  echo "apt_amneziawg_tools=available"
else
  echo "apt_amneziawg_tools=unavailable"
fi
if apt-cache show wireguard-tools >/dev/null 2>&1; then
  echo "apt_wireguard_tools=available"
else
  echo "apt_wireguard_tools=unavailable"
fi
echo "awg_capability_end"

echo "awg_hub_runtime_begin"
hub_unit='awg-quick@awg-hub.service'
echo "hub_enabled=$(systemctl is-enabled "$hub_unit" 2>/dev/null || true)"
echo "hub_active=$(systemctl is-active "$hub_unit" 2>/dev/null || true)"
if sudo -n test -f /etc/amnezia/amneziawg/awg-hub.conf; then
  echo "hub_config=present"
  if sudo -n grep -Fq '# managed by openwrt-skill: resilient-awg-hub' /etc/amnezia/amneziawg/awg-hub.conf; then
    echo "hub_config_managed=true"
  else
    echo "hub_config_managed=false"
  fi
else
  echo "hub_config=absent"
fi
if ip link show dev awg-hub >/dev/null 2>&1; then echo "hub_interface=present"; else echo "hub_interface=absent"; fi
if ip link show dev awg-hub >/dev/null 2>&1; then
  echo "hub_params_begin"
  sudo -n awg showconf awg-hub 2>/dev/null | grep -E '^(ListenPort|Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1)[[:space:]]*=' || true
  echo "hub_params_end"
  peer_count="$(sudo -n awg show awg-hub peers 2>/dev/null | grep -c . || true)"
  echo "hub_peer_count=$peer_count"
  sudo -n awg show awg-hub allowed-ips 2>/dev/null | awk '{ $1="<redacted-public-key>"; print "hub_allowed_ips=" $0 }' || true
  sudo -n awg show awg-hub latest-handshakes 2>/dev/null | awk '{ print "hub_handshake_epoch=" $2 }' || true
  sudo -n awg show awg-hub transfer 2>/dev/null | awk '{ print "hub_transfer_rx=" $2 " hub_transfer_tx=" $3 }' || true
fi
echo "hub_recent_log_begin"
sudo -n journalctl -u "$hub_unit" -n 40 --no-pager 2>/dev/null | \
  sed -E 's/((private|public|preshared)[_-]?key[=: ]+)[A-Za-z0-9+\/=]+/\1<redacted>/Ig' || true
echo "hub_recent_log_end"
echo "hub_snapshots_begin"
sudo -n find /var/backups/openwrt-skill -maxdepth 1 -mindepth 1 -type d -name 'vps-awg-hub-*' -printf '%f\n' 2>/dev/null | sort || true
echo "hub_snapshots_end"
echo "awg_hub_runtime_end"
echo "audit=end"
REMOTE_SH
