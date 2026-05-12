# memory/ — агент-сайд память о роутерах

Эта папка — **источник правды для агента** про состояние и конфигурацию роутеров, которые он обслуживает.

## Структура

```
memory/
  routers.yaml         # реестр всех известных роутеров
  _templates/          # болванки для нового роутера (не редактируется агентом)
  <router-alias>/      # одна папка на каждый роутер
    state.md           # чек-лист 20 пунктов: SSH/key/dns/sing-box/watchdog/...
    domains.md         # таблица доменов → outbound
    vpns.md            # таблица VPN-нод (tag, host, port — БЕЗ секретов)
    proxies.md         # таблица mixed-inbound портов → outbound
    quirks.md          # выученные нюансы (ISP, регион, baudrate, etc)
    journal.md         # append-only лог изменений
```

## Правила обновления

1. **Только скрипты `bin/*` пишут сюда.** Агент НЕ редактирует эти файлы напрямую. Если поправил руками — запусти `bin/doctor.sh --router <alias>`, и `state.md` перерендерится из реального состояния роутера. Файлы `domains.md` / `vpns.md` / `proxies.md` руками не реконсилируются — это известное ограничение V1; см. `runbooks/05-restore.md`.
2. **Никаких секретов.** Запрещены: VLESS UUID/short_id/public_key, Telegram токены, WG private/preshared keys, пароли. Это enforced скриптами через `lib/memory-journal.sh` — он отвергает значения, матчащие secret regex, плюс ключи не из allowlist'а под текущий event_kind.
3. **Журнал append-only.** Старые записи никогда не удаляются. Per-router flock защищает от гонок при параллельных вызовах скриптов.
4. **Если файл `state.md` устарел** (роутер был изменён руками или другим инструментом) — `bin/doctor.sh --router <alias>` перерендерит из реального probe.

## Что НЕ хранится здесь

- VPN-секреты (uuid, private keys) — только на роутере, в `/etc/sing-box/config.json` (chmod 600)
- TG_TOKEN — только на роутере, в `/etc/router-watchdog.conf` (chmod 600)
- SSH private keys — только в `~/.ssh/openwrt_<alias>_ed25519`
- Snapshots — на роутере под `/etc/vpn-kit/snapshots/`, здесь только индекс в `journal.md`

## Если потерял memory/

- Запусти `bin/doctor.sh --router <alias>` — он перерендерит `state.md`, `domains.md`, `vpns.md`, `proxies.md` из реального состояния роутера.
- `journal.md` и `quirks.md` потеряны навсегда — это «история», её на роутере нет.
- Поэтому стоит держать `memory/` под git (приватный репо или зашифрованный).
