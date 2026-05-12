#!/usr/bin/env bash
# bin/add-ip.sh — STUB. Add an IP/CIDR to the proxy_subnets nft set.
#
# В V1 НЕ реализовано. Этот файл существует как явный stub, чтобы:
#   1) агент, прочитавший SKILL.md и увидевший этот скрипт, получал чёткий
#      отказ, а не "command not found";
#   2) в V1.1 этот файл будет заменён полной реализацией без изменения
#      контракта SKILL.md.
#
# Что бы делала полная версия:
#   - читала /etc/sing-box/rules/vpn-domains.json или отдельный per-tag rule_set
#     и добавляла туда ip_cidr; ИЛИ
#   - правила /etc/init.d/sing-box-tproxy: блок nft `proxy_subnets`
#     (persistent + runtime через `nft add element inet sing_box_tproxy proxy_subnets { ... }`);
#   - делала snapshot и staged-apply, как все остальные mutating-операции.
#
# Пока НЕ готово — есть два пути:
#   а) подождать V1.1 (рекомендуется);
#   б) использовать escape hatch bin/raw-ssh.sh для ручной правки. После руками
#      обязательно запустить `bin/doctor.sh --router <alias>` для синка memory.

set -euo pipefail

cat >&2 <<'EOF'
add-ip: НЕ реализовано в V1.

Что нужно: добавить IP/CIDR в маршрутизацию через VPN (или конкретный outbound).

Варианты:
  1) Подождать V1.1 — будет полноценная реализация с snapshot/staged-apply.
  2) Использовать escape hatch:
       bin/raw-ssh.sh --router <alias> --reason "manual: add IP to proxy_subnets"
     Затем на роутере:
       nft add element inet sing_box_tproxy proxy_subnets { 1.2.3.0/24 }
     И в /etc/init.d/sing-box-tproxy добавь IP в блок `proxy_subnets` для persistence.
     ОБЯЗАТЕЛЬНО потом: bin/doctor.sh --router <alias>

Cм. также:
  - runbooks/99-escape-hatch.md
  - OPENWRT_VPN_ROUTER_GUIDE.md §"маршрутизация по IP"
EOF
exit 64
