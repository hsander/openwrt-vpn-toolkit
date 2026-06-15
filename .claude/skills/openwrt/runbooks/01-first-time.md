# Runbook 01 — Первичная настройка чистого роутера

## Когда использовать

Триггеры от пользователя: «настрой роутер», «первичная настройка openwrt», «у меня свежий роутер», «помоги поднять VPN с нуля», «купил роутер, что дальше».

Pre-conditions:
- Нет папки `memory/<alias>/` ИЛИ `memory/<alias>/state.md` показывает большинство пунктов 1–14 как `❌`.
- Пользователь имеет физический/сетевой доступ к роутеру (LuCI/SSH password или dropbear).
- На роутере OpenWRT 24.10+ (минимум для sing-box ≥ 1.10).

Если `memory/<alias>/state.md` уже показывает «Готово к работе: yes» → НЕ перезапускай первичный сетап. Спроси, что именно человек хочет (добавить домен → `02-add-domain.md`, добавить VPN → `03-add-vpn.md`).

## Шаг 1. Что спросить у пользователя

1. **`alias`** — короткое имя (a-zA-Z0-9_-). Это будет ключ в `memory/routers.yaml`. Примеры: `home`, `office`, `dacha`. Если пользователь не предлагает — спроси.
2. **`host`** — IP (обычно `192.168.1.1`) или DNS-имя роутера. Валидация: только IPv4/IPv6/доменное имя; никаких `vless://` / токенов.
3. **`user`** — SSH-юзер. Default: `root`. Спрашивай только если пользователь сам сказал, что нерутовый.
4. **`port`** — SSH порт. Default: `22`. Спрашивай только если пользователь сам сказал.

Не спрашивай SSH-пароль и не предлагай его передавать в чат.

## Шаг 2. Завести SSH-ключ и Host-блок

```bash
bin/setup-ssh.sh --router <alias> --host <host> [--user root] [--port 22]
```

Что делает: генерирует `~/.ssh/openwrt_<alias>_ed25519`, добавляет Host-блок в `~/.ssh/config`, регистрирует роутер в `memory/routers.yaml`, проверяет BatchMode SSH.

Exit codes:
- `0` — ключ уже работает, идти к шагу 3.
- `2` — внутренняя ошибка (например, ssh-keygen упал). Прочитай stderr, сообщи пользователю.
- `13` — невалидный `--router` (только `a-zA-Z0-9_-`) или порт. Спроси заново.
- `64` — нужна ручная авторизация ключа. Скрипт уже напечатал инструкцию вида `ssh-copy-id -i ~/.ssh/openwrt_<alias>_ed25519.pub root@<host>` (или fallback для dropbear). Покажи её пользователю **целиком и дословно**, попроси выполнить, дождись «готово/done/ок», и **повтори ту же команду** `bin/setup-ssh.sh ...`.

Edge case (dropbear): на старых OpenWRT-сборках нет `ssh-copy-id`. Если пользователь говорит «нет ssh-copy-id» — предложи альтернативу:
```
cat ~/.ssh/openwrt_<alias>_ed25519.pub | ssh root@<host> 'mkdir -p /etc/dropbear && cat >> /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys'
```
Потом снова `bin/setup-ssh.sh --router <alias> --host <host>`.

## Шаг 3. Probe + покажи чек-лист

```bash
bin/doctor.sh --router <alias>
```

Что делает: ходит по SSH, проверяет 20 пунктов, рендерит `memory/<alias>/state.md`.

Exit codes:
- `0` — состояние записано в `memory/<alias>/state.md`. Прочитай его.
- `2` — `memory/routers.yaml` не содержит alias ИЛИ SSH упал. Если SSH упал — вернись на шаг 2.

После `0` — **прочитай `memory/<alias>/state.md`** и **покажи пользователю чек-лист в человеко-читаемом виде**: что готово (✅), что нет (❌), и блок «Что предложить пользователю» как список следующих шагов.

Спроси: «Хочешь поднять watchdog (TG-алерты) и VPN? Обычно идём в порядке: watchdog → VPN. Watchdog не обязателен, можно отложить.»

## Шаг 4. (Опционально) Watchdog

Если пользователь согласен на watchdog:

### 4a. Получить шаблон
```bash
bin/setup-watchdog.sh --router <alias>
```
Скрипт всегда выходит с `64` в этой фазе — это нормально. Он печатает шаблон conf-файла и инструкцию.

### 4b. Объясни пользователю
Скажи пользователю **дословно**: «Сохрани этот шаблон в локальный файл, например `~/router-watchdog.conf`. Заполни `TG_TOKEN=...` и `TG_CHAT_ID=...`. **НЕ присылай этот файл в чат — токены не попадают в наш разговор.** Когда готово, сообщи мне путь к файлу.»

Дождись пути. Валидация пути:
- Это локальный путь, не URL.
- В пути нет `vless://`, `bot<digits>:`, и других маркеров секрета (иначе пользователь, видимо, перепутал «путь» с «содержимым» — попроси перевводить).

### 4c. Залить
```bash
bin/setup-watchdog.sh --router <alias> --conf-file <path>
```

Exit codes:
- `0` — watchdog встал, cron взведён. Скажи «watchdog поднят, TG-алерты пойдут на твой chat_id». Локальный conf-файл по умолчанию **удаляется** (shred); если пользователь хочет его сохранить — добавь `--keep-local`.
- `2` — SSH упал. Скажи и не пытайся повторять.
- `13` — формат conf-файла невалидный (regex не сошёлся на `TG_TOKEN=` / `TG_CHAT_ID=`). Покажи stderr, попроси проверить файл.
- `64` — bad CLI args.

## Шаг 5. VPN (главное)

Спроси у пользователя `vless://...` URL.

**КРИТИЧНО про секреты:** скажи: «Vless-URL содержит UUID и приватные параметры Reality. Можешь либо вставить его сюда (я не запишу его в memory/journal/git — только парсну локально и закину на роутер), либо сохранить в локальный файл и сообщить путь. Что удобнее?»

### Вариант A: пользователь вставил URL в чат
Проверь, что выглядит как `vless://<uuid>@<host>:<port>?...&type=tcp...#<fragment>`. Если нет — переспроси.

```bash
bin/install-vpn.sh --router <alias> --url '<url>'
```
Опционально добавь `--add-proxy-port 4000` если пользователь сразу хочет LAN-proxy (рекомендуй — удобно для тестов).

### Вариант B: пользователь дал путь к файлу
Прочитай URL из файла **локально**, передай в `--url`. Не показывай URL обратно в чат.

```bash
url="$(head -1 <path>)"
bin/install-vpn.sh --router <alias> --url "$url"
```

### Что делает `install-vpn.sh`
1. snapshot существующего config (если есть).
2. preflight: версия OpenWRT, пакеты, RAM, конфликты с zapret/zapret2/awg.
3. `apk install sing-box`, DNS chain (https-dns-proxy + dnsmasq + nft redirect), init.d/sing-box-tproxy.
4. рендер `config.json` с outbound, auto-failover, базовым правилом.
5. staged-apply: старт сервиса, reachability watchdog, авто-rollback при потере SSH.
6. обновляет `state.md`, `vpns.md`, `proxies.md`, `journal.md`.

Exit codes:
- `0` — VPN поднят. Идти к шагу 6.
- `2` — SSH упал / preflight не прошёл (нет места, нет интернета на роутере, занят порт). Покажи stderr.
- `13` — URL битый, tag невалидный, или порт не из диапазона 4000-4099. Попроси перевводить.
- `20` — **rollback сработал**: после рестарта sing-box роутер стал недостижим, snapshot восстановлен. Это значит URL/конфигурация некорректны для этой сети (часто — неверный `sni`, `pbk`, или провайдер режет TCP к серверу). НЕ ретраить молча. Скажи пользователю, попроси проверить URL у провайдера VPN. Можно предложить пользователю запустить `bin/logs.sh --router <alias> --source sing-box --lines 80` (см. `99-escape-hatch.md`, шаг диагностики).
- `64` — bad CLI args.

## Шаг 6. Повторный doctor + подтверждение

```bash
bin/doctor.sh --router <alias>
```

Прочитай новый `state.md`. Должны зажечься `✅` для пунктов 5–14 как минимум (sing-box installed, config valid, tproxy running, ≥1 outbound + auto-failover, DNS chain). Если что-то осталось `❌` — покажи пользователю и обсуди.

## Шаг 7. (Опционально) Первый smoke-test

```bash
bin/health.sh --router <alias> --ip-exit-only
```

Что делает (по контракту SKILL.md): возвращает только exit-IP через текущий outbound (через mixed-proxy на 4000 или прямой curl через outbound).

Если IP совпадает с обычным (не VPN'ным) — что-то с правилами роутинга. Дальше — `bin/health.sh --router <alias>` без флагов, посмотреть полный отчёт (sing-box status, nft set'ы, DNS resolve).

## Что обновляется в memory/

- `memory/routers.yaml` — alias → host/user/ssh_key (после `setup-ssh.sh`).
- `memory/<alias>/state.md` — после каждого `doctor.sh`.
- `memory/<alias>/vpns.md` — после `install-vpn.sh` появляется первая строка.
- `memory/<alias>/proxies.md` — если был `--add-proxy-port`.
- `memory/<alias>/journal.md` — события `ssh_setup`, `watchdog_installed`, `vpn_installed`, `snapshot_created`.
- `memory/<alias>/quirks.md` — пусто, заполнится по мере выявления нюансов ISP/железа.

## Что сказать пользователю (шаблон финального сообщения)

```
Готово. Резюме настройки роутера <alias>:
- SSH-ключ: ~/.ssh/openwrt_<alias>_ed25519, alias openwrt-<alias>
- Watchdog: [установлен / не ставили]
- VPN: outbound <tag>, сервер <host>:<port>, auto-failover активен
- LAN proxy: [http://<host>:4000 → auto-failover / не ставили]
- Snapshot до изменений: <snap-id>

Что дальше:
- Добавить домен в VPN: «добавь youtube.com»
- Добавить ещё одну VPN-ноду: «добавь vpn ...»
- Откатиться: «откати к snapshot <id>»

Полный чек-лист: memory/<alias>/state.md
```

## Edge cases / частые ошибки

- **`ssh-copy-id` не работает (dropbear)** → fallback на ручной `cat ... | ssh ... >> authorized_keys` (см. шаг 2).
- **`install-vpn.sh` exit 20** → НЕ повторять, обсуждать с пользователем.
- **Пользователь вставил vless-URL в чат, потом передумал** → URL уже в моём контексте, но в memory/git не уйдёт (скрипт парсит локально и не логирует секреты). Скажи это явно, успокой.
- **Роутер на старом OpenWRT (< 23.05)** → `install-vpn.sh` сразу скажет `exit 2` через preflight. Объясни пользователю что нужен апгрейд sysupgrade, и **не** пытайся это сделать сам.
- **На роутере уже есть sing-box (от другого setup'а)** → `install-vpn.sh` снимет snapshot, но если конфликт реальный (порт занят / другой init.d) — preflight упадёт с `exit 2`. Тогда `04-add-proxy.md` / `03-add-vpn.md` могут подойти лучше, или escape hatch.

## НЕ ДЕЛАТЬ

- НЕ выполнять `ssh root@... <command>` напрямую — только через `bin/*`.
- НЕ записывать `vless://`-URL в `journal.md`/`state.md`/`vpns.md`/чат-сводку.
- НЕ запускать `install-vpn.sh` снова после `exit 20` без обсуждения с пользователем.
- НЕ пропускать `bin/doctor.sh` после `install-vpn.sh` — это единственный способ убедиться, что state синхронизировался.
- НЕ перезаписывать `memory/<alias>/quirks.md` — пользователь может туда писать руками.
