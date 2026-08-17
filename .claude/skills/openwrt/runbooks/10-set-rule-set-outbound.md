# Runbook 10 — Переключить существующий rule-set на другой outbound

## Когда использовать

Триггеры от пользователя:
- «переключи Telegram на Польшу»
- «переведи Spotify на США»
- «этот сервис пусть идёт через другой сервер»
- «перенеси rule-set `<tag>` на `<outbound>`»

Используй этот runbook, когда в `doctor.sh --json` / `memory/<alias>/state.md` видно, что сервис уже маршрутизируется через `route.rules[].rule_set`, например `telegram`, `tg-pin`, `spotify-usa`, `polsha-only`, `user-usa-4`.

Не пытайся решать это только через `add-domain.sh` / `remove-domain.sh`: новые доменные rule-set'ы могут стоять ниже в `route.rules`, а более ранний сервисный rule-set продолжит выигрывать и вести трафик по старому outbound.

## Pre-conditions

- `config.json` валиден по `doctor.sh`.
- `probe_reliable=true`.
- Целевой outbound существует в `outbounds_detail` или как country-pool (`usa-pool`, `pl-pool`, `sg-pool`).
- Есть snapshot/restore support.

Если `doctor.sh` не может надёжно прочитать config — сначала исправь это, не меняй маршруты вслепую.

## Шаг 1. Найти rule-set

Запусти:

```bash
bin/doctor.sh --router <alias> --json
```

Проверь:
- `rule_set_outbound_map`: какой `rule_set` сейчас ведёт на старый outbound.
- `domain_outbound_map`: не перекрывает ли этот rule-set конкретные домены.
- `selector_groups`: если пользователь сказал страну, какой pool соответствует стране.

Пример: если `telegram` и `tg-pin` оба в одном `route.rules` и outbound там `usa-4-crip`, то менять нужно rule-set `telegram` один раз; `doctor` после изменения покажет оба tag'а в этом правиле уже на новом outbound.

## Шаг 2. Выполнение

```bash
bin/set-rule-set-outbound.sh --router <alias> --rule-set <rule_set_tag> --outbound <outbound_tag_or_pool>
```

Примеры:

```bash
bin/set-rule-set-outbound.sh --router home --rule-set telegram --outbound pl-pool
bin/set-rule-set-outbound.sh --router home --rule-set spotify-usa --outbound usa-4
```

Что делает скрипт:
1. проверяет SSH и наличие target outbound;
2. делает pre-backup;
3. скачивает `/etc/sing-box/config.json`;
4. меняет `outbound` только у `route.rules`, где `rule_set` содержит указанный tag;
5. guard: количество `route.rules` до/после не должно измениться;
6. guard: все найденные matching rules должны получить новый outbound;
7. `sing-box check`;
8. atomic apply + reload;
9. удаляет FakeIP `cache.db` и перезапускает `sing-box-tproxy`, чтобы уже
   разрешённые домены не продолжили идти через старый outbound;
10. journal event `set_rule_set_outbound`.

Exit codes:
- `0` — применено.
- `2` — SSH/backup/SCP проблема.
- `13` — rule-set не найден, outbound не найден, локальный guard не прошёл.
- `20` — remote validation/reload failed, snapshot restored.
- `64` — bad CLI args.

Если reset/restart FakeIP-кэша не удался, скрипт сообщает warning: изменение
конфига уже применено, но старые соединения могут временно использовать прежний
outbound. Запусти `bin/health.sh` и `bin/logs.sh`; не исправляй это скрытым raw SSH.

## Шаг 3. Подтверждение

Сразу после exit 0 запусти:

```bash
bin/doctor.sh --router <alias> --json
```

Подтверди:
- `config.valid=true`;
- `tproxy.running=true`;
- `rule_set_outbound_map` показывает нужный `rule_set -> outbound`;
- `domain_outbound_map` для доменов сервиса показывает ожидаемый outbound или более ранний ожидаемый rule-set;
- `inbound_outbound_map` не пропал.

Если `inbound_outbound_map` пустой или резко изменился — это регрессия config rewrite. Откати к snapshot, который скрипт вывел как `snapshot`, и исправь скрипт перед повтором.

## НЕ ДЕЛАТЬ

- НЕ редактировать `/etc/sing-box/config.json` руками через SSH.
- НЕ решать смену сервисного rule-set только переносом доменов в новый `user-<outbound>-domains.json`, если старый rule-set стоит выше в `route.rules`.
- НЕ продолжать изменения после guard/validation failure.
