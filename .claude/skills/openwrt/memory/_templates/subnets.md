---
router: {{ROUTER_ALIAS}}
revision: 0
last_updated: {{LAST_UPDATED_ISO}}
---

# Подсети через VPN: {{ROUTER_ALIAS}}

Это источник правды о том, какие IP-адреса и CIDR-подсети маршрутизируются через VPN-туннель. Файл обновляется скриптами `bin/add-ip.sh` / `bin/remove-ip.sh`.

Записи живут в nft-сете `proxy_subnets` (внутри table `inet sing_box_tproxy`) и в persistent-файле `/etc/vpn-kit/persistent-sets.nft` на роутере.

## Активные записи

| IP / CIDR | Family | Via | Nft set | Added at | Source |
|-----------|--------|-----|---------|----------|--------|
{{SUBNET_TABLE_ROWS}}

## Файлы на роутере

| Файл | Назначение |
|------|------------|
| `/etc/vpn-kit/persistent-sets.nft` | nft-команды, перечитываемые `sing-box-tproxy` на старте |
| `/etc/init.d/sing-box-tproxy` | hook: `[ -f .../persistent-sets.nft ] && nft -f ...` после создания сетов |
| runtime `nft list set inet sing_box_tproxy proxy_subnets` | живой membership; должен совпадать с persistent + dynamic_additions[] |

## Как добавить

```bash
bin/add-ip.sh --router {{ROUTER_ALIAS}} --ip 1.2.3.4         # /32 implied
bin/add-ip.sh --router {{ROUTER_ALIAS}} --ip 10.20.0.0/16    # CIDR
```

Safeguards: 0.0.0.0/0, RFC1918, loopback/link-local/multicast будут отказаны (RFC1918 и default-route обходятся `--force`, остальные — нет).

## Как удалить

```bash
bin/remove-ip.sh --router {{ROUTER_ALIAS}} --ip 1.2.3.4/32
```

Удаление синхронно стирает запись из nft-сета, persistent-файла и `dynamic_additions[]` в install-state.

## Заметки

{{NOTES}}
