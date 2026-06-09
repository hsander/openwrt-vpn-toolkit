# Runbooks

Пошаговые гайды для агента под каждый сценарий. Читать ПЕРЕД первой встречей со сценарием.

Основной читатель — Claude (агент). Пользователь увидит часть, переданную ему явно (template'ы финального сообщения и инструкции по ssh-copy-id / conf-файлу); всё остальное — agent-side инструкции.

| Файл | Сценарий | Статус |
|------|----------|:------:|
| [`01-first-time.md`](./01-first-time.md) | Полная первичная настройка чистого роутера (SSH → doctor → watchdog → VPN → verify) | ✅ |
| [`02-add-domain.md`](./02-add-domain.md) | Добавление домена в VPN-список (rule_set hot-reload) | ✅ |
| [`03-add-vpn.md`](./03-add-vpn.md) | Добавление новой VPN-ноды (outbound + auto-failover + zapret nft set) | ✅ |
| [`04-add-proxy.md`](./04-add-proxy.md) | LAN HTTP/SOCKS5 proxy на mixed-inbound порту 4000-4099 | ✅ |
| [`05-restore.md`](./05-restore.md) | Откат изменений из snapshot (safety_snapshot + re-sync memory) | ✅ |
| [`06-adopt-existing.md`](./06-adopt-existing.md) | Адопция уже настроенного роутера (snapshot + probe + render memory, без модификации роутера) | ✅ |
| [`07-add-ip.md`](./07-add-ip.md) | Завернуть IP/CIDR в VPN (proxy_subnets nft-set, общий маршрут через `--via auto`) | ✅ |
| [`08-pin-device.md`](./08-pin-device.md) | Pin LAN-устройства (source-ip/CIDR) на конкретный outbound (route.rules + nft tproxy) | ✅ |
| [`10-set-rule-set-outbound.md`](./10-set-rule-set-outbound.md) | Переключить существующий rule-set/service route на другой outbound без ручного `config.json` | ✅ |
| [`99-escape-hatch.md`](./99-escape-hatch.md) | Когда и как использовать `bin/raw-ssh.sh` (требует явное «yes») | ✅ |

## Структура каждого runbook'а

1. **Когда использовать** — триггер-фразы пользователя + pre-conditions из `state.md`.
2. **Что спросить у пользователя** — список вопросов, валидаций и спец-случаев.
3. **Выполнение** — какой `bin/*` скрипт, с какими аргументами, в каком порядке. Exit codes и что делать на каждом.
4. **Что обновляется в `memory/<alias>/`** — конкретные файлы и события journal.
5. **Что сказать пользователю** — шаблон финального сообщения.
6. **Edge cases / частые ошибки**.
7. **НЕ ДЕЛАТЬ** — анти-паттерны, нарушающие контракт `SKILL.md`.

## Как агент использует runbooks

- При триггере, который маппится на сценарий, агент **читает соответствующий runbook целиком** до начала действий.
- Если pre-conditions не выполнены — runbook явно перенаправляет на другой (обычно `01-first-time.md`).
- Каждый mutating-скрипт в runbook'е сопровождён описанием **всех** значимых exit codes (0/2/13/20/64), потому что обработка их различна.
- При сомнениях между «через скрипт» и «через сырой SSH» — всегда через скрипт. `99-escape-hatch.md` — последний резерв.

## Связанные документы

- [`../SKILL.md`](../SKILL.md) — общий контракт навыка (жёсткие правила, поток, exit codes). Runbook'и операционализируют его.
- [`../memory/README.md`](../memory/README.md) — структура и правила обновления memory.
- [`../memory/_templates/`](../memory/_templates/) — болванки md-файлов, рендерящихся в `memory/<alias>/` при первом запуске.
