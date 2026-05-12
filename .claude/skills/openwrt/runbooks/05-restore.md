# Runbook 05 — Восстановление из snapshot

## Когда использовать

Триггеры от пользователя: «откати», «верни как было», «что-то сломалось после <операция>», «restore», «откати к snapshot <id>», «верни вчерашнюю конфигурацию».

Pre-conditions:
- Роутер достижим по SSH (`bin/doctor.sh --router <alias>` должен возвращать exit 0). Если SSH упал — restore не сделать; нужен LuCI/физический доступ или escape hatch.
- На роутере есть хотя бы один snapshot. Проверяется через `bin/snapshot-list.sh`.

## Шаг 1. Показать список snapshots

```bash
bin/snapshot-list.sh --router <alias>
```

Что делает: печатает таблицу `ID | Created (ISO) | Label | Size` из `/etc/vpn-kit/snapshots/*.meta.json` на роутере, отсортировано **новейшие сверху**.

Exit codes:
- `0` — таблица напечатана (или пусто). Если пусто — скажи: «Snapshot'ов нет. Возможно, на роутере никогда не делалось backup-now или их подчистил retention. Откатить нечего.»
- `2` — SSH упал / роутер не найден в реестре.
- `64` — bad CLI args.

Покажи таблицу пользователю в человеко-читаемом виде. Параллельно прочитай `memory/<alias>/journal.md` (последние записи) — там у каждого `snapshot_created` event есть контекст (label, что делалось до).

## Шаг 2. Выбрать snapshot

Спроси пользователя: «К какому откатить? Можешь дать ID (`snap-YYYYMMDDTHHMMSSZ`) или описать логику ("последний", "перед добавлением youtube.com")».

Если пользователь говорит «последний» → бери первую строку из `snapshot-list.sh` (она и есть самая свежая).

Если пользователь говорит «перед таким-то изменением» → прочитай `journal.md`, найди событие до этого изменения (event `snapshot_created` ИЛИ `snapshot_before` поле в событии mutating-операции, например `add_domain`). Подтверди ID у пользователя, не угадывай.

Если пользователь говорит «откати на час назад» → найди snapshot с `created` ближайшим к (сейчас − 1 час), сообщи его ID, попроси подтверждение.

### Валидация ID
- Формат: `snap-` + 16 цифр/букв ISO timestamp (`snap-20260511T134205Z`).
- ID должен быть в выводе `snapshot-list.sh`. Если нет — НЕ запускай restore, скажи «такого snapshot'а нет на роутере».

## Шаг 3. ⚠ Объяснить последствия и получить ЯВНОЕ подтверждение

Это **обязательно**. До запуска `restore.sh` скажи пользователю **дословно** (адаптируй под язык):

```
Сейчас откачу роутер <alias> к snapshot <snap-id> (создан <created>, label: <label>).

Что произойдёт:
- Будет создан safety_snapshot (на случай если откат сам сломает) — двойной snapshot.
- Восстановятся файлы: /etc/sing-box/, init.d/sing-box-tproxy, /etc/config/*,
  /etc/nftables.d/, /etc/router-watchdog.conf, /etc/vpn-kit/install-state.json,
  watchdog-скрипты — всё, что попало в snapshot.
- Перезапустятся сервисы (sing-box-tproxy, dnsmasq, firewall).
- Возможен downtime несколько секунд — клиенты могут потерять интернет/VPN на 5-30s.
- memory/<alias>/{domains,vpns,proxies}.md могут перестать соответствовать реальности
  на роутере — после restore я обязательно запущу doctor.sh для re-sync.

Подтверди ("да"/"ok"/"yes") если согласен — без явного подтверждения не запускаю.
```

Если пользователь не ответил «да/ok/yes» (или эквивалентом) — НЕ запускай restore. Если ответил «отмена» / «не надо» — закрой ветку.

## Шаг 4. Выполнение

```bash
bin/restore.sh --router <alias> --snapshot <id>
```

Что делает (по контракту SKILL.md и PROPOSAL.md):
1. **Safety snapshot** — pre-restore snapshot текущего состояния (чтобы откатить откат).
2. Распаковка `<id>.tar.gz` в staging-директорию.
3. Atomic restore файлов.
4. Restart затронутых сервисов через `lib/staged-apply.sh` — reachability watchdog, auto-rollback при потере SSH (что значит exit 20).
5. Обновление `memory/<alias>/journal.md` с событием `restore`, ссылающимся на оба snapshot ID (откатываемый + safety).

Exit codes:
- `0` — восстановление успешно. Идти к шагу 5.
- `2` — SSH упал, или snapshot ID не найден на роутере.
- `13` — невалидный ID (не та форма / запрещённые символы).
- `20` — **rollback fired**: после restore роутер не достижим, safety_snapshot восстановлен **автоматически**. Состояние = до запуска `restore.sh`. Это значит, что выбранный snapshot был «сломан» (например, содержал config с уже неработающим VPN-сервером). Скажи пользователю: «Snapshot оказался сам по себе сломан, я вернул всё как было до попытки отката. Нужно разобраться, что в этом snapshot не так — попробуем diff с предыдущим, или другой snapshot». Дальше → `bin/logs.sh --router <alias> --source sing-box --lines 50` (см. ниже).
- `64` — bad CLI args.

## Шаг 5. Re-sync memory (ОБЯЗАТЕЛЬНО)

```bash
bin/doctor.sh --router <alias>
```

После любого `restore.sh --snapshot <id>` exit 0 — memory может быть рассинхронизирована с реальностью на роутере. `state.md` будет перерендерен из реального probe.

Скажи пользователю:
> Обрати внимание: `domains.md`, `vpns.md`, `proxies.md` могут больше не соответствовать тому, что сейчас реально на роутере (snapshot мог иметь другие домены/ноды/прокси). `state.md` я уже перерендерил, но `domains.md` / `vpns.md` / `proxies.md` — это табличные «истории», скрипт их сейчас не реконсилит автоматически. Если они важны — могу запросить актуальный список через `bin/doctor.sh --router <alias> --json` и помочь пересоздать таблицы вручную. Или просто иди дальше — на роутере всё в порядке, memory наверстаем при следующих изменениях.

(Это явное ограничение V1: автоматическая реконсиляция таблиц memory из снапшота — post-V1 feature.)

## Шаг 6. Sanity check

```bash
bin/health.sh --router <alias>
```

Что делает: sing-box status, nft set summary, DNS resolve через 127.0.0.42, SOCKS exit IP через mixed-proxy (если есть).

Прочитай вывод, покажи пользователю: «VPN живой, exit IP = <ip>, DNS отвечает». Если что-то красное — обсуди.

## Что обновляется в memory/

- `memory/<alias>/state.md` — перерендерен через `doctor.sh`.
- `memory/<alias>/journal.md` — событие `restore` с `from_snapshot`, `safety_snapshot`, `reason` (если пользователь дал контекст), `result`.
- `domains.md`, `vpns.md`, `proxies.md` — **НЕ** автоматически реконсилятся (см. шаг 5).

## Что сказать пользователю (после успеха)

```
Готово. Роутер <alias> восстановлен:
- Откатили к: <snap-id> (created <created>, label: <label>)
- Safety snapshot (для отката этого отката): <safety-id>
- Сервисы перезапущены, reachability подтверждена

Проверил через health.sh:
- sing-box: <running|stopped>
- DNS: <resolves|fails>
- Exit IP через :4000: <ip>

⚠ memory/<alias>/{domains,vpns,proxies}.md могут не соответствовать. Если важно —
скажи, синхронизируем вручную.

Откатить этот откат: «откати к <safety-id>».
```

## Edge cases / частые ошибки

- **Exit 20 (rollback fired)**: safety_snapshot вернулся, ничего страшного, но **разберись почему**. Запусти `bin/logs.sh --router <alias> --source sing-box --lines 50` — там обычно видно почему sing-box не стартовал из snapshot'а (битый JSON, удалённый outbound, EOL пакеты). НЕ предлагай повторить restore сразу — это бесполезно.
- **Пользователь хочет откатить откат (Ctrl-Z over Ctrl-Z)** → ок, восстанавливаем из `safety_snapshot` тем же `restore.sh --snapshot <safety-id>`. По контракту, это тоже создаст свой safety_snapshot.
- **Snapshot очень старый (> 30 дней)** → формат файлов мог измениться, восстановление *возможно* приведёт к exit 20. Предупреди пользователя.
- **Snapshot был сделан до `setup-watchdog.sh`** → после restore watchdog-conf и cron уйдут. Скажи пользователю, что watchdog придётся подняли заново.
- **Параллельный mutating-скрипт** → restore может вернуть `12` (LOCK) если кто-то делает `add-domain` прямо сейчас. Подожди / попроси пользователя завершить и retry.

## НЕ ДЕЛАТЬ

- **НЕ запускать `restore.sh` без явного подтверждения пользователя**. Это самая разрушительная операция в навыке.
- НЕ пропускать `bin/doctor.sh` после restore. Без него state.md останется старым и врать будет.
- НЕ повторять `restore.sh` после exit 20 не разобравшись.
- НЕ пытаться отредактировать `memory/<alias>/domains.md` руками для «синхронизации» — единственный валидный путь это `bin/doctor.sh --router <alias>` (state) или повторное добавление через `add-domain.sh`/`add-vpn.sh`.
