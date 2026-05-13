---
router: {{ROUTER_ALIAS}}
revision: 0
last_updated: {{LAST_UPDATED_ISO}}
---

# Pin'ы LAN-клиентов: {{ROUTER_ALIAS}}

Это источник правды о том, какие конкретные LAN-устройства (IP/CIDR) жёстко прибиты к конкретному sing-box outbound. Файл обновляется скриптом `bin/pin-device.sh` (V1.1: удаление — вручную через `bin/raw-ssh.sh`).

Каждый pin живёт одновременно в трёх местах: `route.rules[]` в `/etc/sing-box/config.json` (source_ip_cidr → outbound), persistent nft-правило с комментарием `vpn-kit-pin-*` в `/etc/init.d/sing-box-tproxy`, и runtime nft в цепочке `inet sing_box_tproxy mangle_prerouting`.

## Активные pin'ы

| Source | Scope | Outbound | Pin ID | Added at | Source-of-pin |
|--------|-------|----------|--------|----------|---------------|
{{PIN_TABLE_ROWS}}

## Файлы на роутере

| Файл | Назначение |
|------|------------|
| `/etc/sing-box/config.json` | `route.rules[]` с `source_ip_cidr: [<ip>]` → `outbound: <tag>` |
| `/etc/init.d/sing-box-tproxy` | persistent nft-правило в `mangle_prerouting` с маркером `vpn-kit-pin-<hash>` |
| runtime `nft list chain inet sing_box_tproxy mangle_prerouting` | живая запись с тем же комментарием; должна совпадать с init.d |

## Как добавить

```bash
bin/pin-device.sh --router {{ROUTER_ALIAS}} --outbound <tag> --source-ip 192.168.1.42
bin/pin-device.sh --router {{ROUTER_ALIAS}} --outbound <tag> --source-cidr 192.168.50.0/24
```

Safeguards: 0.0.0.0/0, loopback/link-local/multicast и перекрытие всей LAN-сети будут отказаны (LAN-overlap снимается флагом `--force`).

## Как удалить (V1.1 — вручную)

В V1.1 нет `bin/unpin-device.sh`. Откат — через `bin/raw-ssh.sh`:

1. Удалить запись из `route.rules[]` (`jq` по `source_ip_cidr`) и записать обратно в `/etc/sing-box/config.json`.
2. Удалить строку с комментарием `vpn-kit-pin-<hash>` из `/etc/init.d/sing-box-tproxy`.
3. Удалить запись из `install-state.json` → `dynamic_additions[]` (по `id`).
4. `/etc/init.d/sing-box-tproxy restart`.

В худшем случае (потеря SSH после restart) — IPMI/console-доступ + ручной откат через `restore.sh --snapshot <id>` из последнего snapshot перед pin'ом (snapshot ID записан в `journal.md`).

## Заметки

{{NOTES}}
