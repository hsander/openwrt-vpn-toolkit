#!/usr/bin/env bash
# bin/pin-device.sh — STUB. Pin a LAN device (source IP) to a specific outbound.
#
# В V1 НЕ реализовано — этот файл явный stub. См. логику в add-ip.sh.
#
# Что бы делала полная версия:
#   - в /etc/sing-box/config.json вставляла route.rules[] с
#       { "source_ip_cidr": ["192.168.1.X/32"], "outbound": "<tag>" }
#     ПЕРЕД auto-failover catch-all;
#   - в /etc/init.d/sing-box-tproxy — nft tproxy rule в mangle_prerouting
#     ПЕРЕД FakeIP rule (порядок критичен — см. ROUTER_ADMIN_GUIDE.md §520-558);
#   - делала snapshot и staged-apply.

set -euo pipefail

cat >&2 <<'EOF'
pin-device: НЕ реализовано в V1.

Что нужно: жёстко пробросить конкретное LAN-устройство (по source IP) через
конкретный VPN-outbound, минуя auto-failover.

Варианты:
  1) Подождать V1.1.
  2) Escape hatch:
       bin/raw-ssh.sh --router <alias> --reason "manual: pin device to outbound"
     Затем на роутере отредактируй:
       /etc/sing-box/config.json     — добавь route.rule с source_ip_cidr
       /etc/init.d/sing-box-tproxy   — добавь nft mangle_prerouting tproxy rule
     ОБЯЗАТЕЛЬНО:
       sing-box check -c /etc/sing-box/config.json
       /etc/init.d/sing-box-tproxy restart
       bin/doctor.sh --router <alias>

Cм. также ROUTER_ADMIN_GUIDE.md §180-211 (per-device routing).
EOF
exit 64
