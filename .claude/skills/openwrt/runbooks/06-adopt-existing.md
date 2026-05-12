# Runbook 02 — Adopt уже-настроенного роутера

Этот runbook описывает, как **взять под управление скилла** роутер, на котором sing-box (и, возможно, DNS chain, zapret, watchdog) уже стоят — настроены вручную, другим инструментом или прошлой инсталляцией прототипа. **Adopt не модифицирует роутер**: он делает **снапшот**, читает реальное состояние и рендерит `memory/<alias>/` так, чтобы дальнейшие `add-*/remove-*` работали поверх существующей конфигурации.

## Когда использовать

Триггеры от пользователя:
- «У меня уже стоит sing-box на роутере X, помоги управлять им через скилл».
- «Возьми под контроль текущий конфиг — я настраивал руками».
- «Синхронизируй memory с тем, что реально на роутере, я там что-то правил».
- «Можно ли подружить твой скилл с моим существующим VPN-сетапом?».

Триггеры от скрипта:
- `bin/install-vpn.sh` упал с preflight-fail `existing-sing-box-config-not-owned` (есть `/etc/sing-box/config.json`, но `/etc/vpn-kit/install-state.json` отсутствует — значит роутер настроен **не** этим скиллом).
- `bin/doctor.sh` показал sing-box запущенным, но `install-state.json` нет → роутер в режиме **stale-without-ownership**.
- В `memory/<alias>/state.md` стоит `❌` против пункта «install-state owned by skill» при `✅` против «sing-box running».

Pre-conditions:
- Роутер уже зарегистрирован в `memory/routers.yaml` (alias + host). Если нет — сначала `bin/setup-ssh.sh --router <alias> --host <host>` (см. `01-first-time.md §Шаг 2`).
- `bin/doctor.sh --router <alias>` отвечает без exit `2` (SSH работает). Иначе сначала чини SSH, потом возвращайся сюда.
- Пользователь подтвердил, что роутер **его** и что он согласен, чтобы скилл прочитал текущее состояние. Adopt — read-only по роутеру, но **снапшот** будет создан (это нормально и желательно).

Если `memory/<alias>/state.md` уже показывает «install-state owned by skill: ✅» — adopt **не нужен в первый раз**, но **idempotent**: можно перезапустить, чтобы пересобрать `vpns.md`/`domains.md`/`proxies.md` после ручных правок. См. §Граничные случаи.

## Шаг 1. Запустить adopt

```bash
bin/adopt.sh --router <alias>
```

Что скрипт делает (агенту знать только это):
1. **Pre-adopt snapshot** через `bin/backup-now.sh --router <alias> --label "pre-adopt"` — на случай, если что-то в дальнейшем пойдёт не так, у нас есть точка возврата к моменту "до прихода скилла".
2. **Probe** реального состояния роутера (тот же путь, что у `doctor.sh`): что установлено, что запущено, какие порты слушаются.
3. **Read** `/etc/sing-box/config.json` (если есть и валиден), `/etc/sing-box/rules/*.json`, `/etc/router-watchdog.conf`, nft set'ы `vpn_servers`, init.d/* — без модификации.
4. **Render** `memory/<alias>/{state,vpns,domains,proxies}.md` из реально прочитанного.
5. **Создаёт** (или обновляет) `/etc/vpn-kit/install-state.json` на роутере с пометкой `source=adopted`, чтобы скрипты `add-*/remove-*/install-*` понимали, что роутер теперь "под скиллом".
6. **Журналит** событие `adopted_existing_setup` в `memory/<alias>/journal.md` с указанием snapshot ID и сводкой найденных компонентов.

Сам роутер **НЕ модифицируется** в части runtime: ни пакеты, ни сервисы, ни конфиг. Единственная запись на роутер — `install-state.json` (это **owner marker**, не runtime).

Exit codes:
- `0` — adopt прошёл. memory собрана. Идти к шагу 2.
- `2` — роутер не найден в `memory/routers.yaml` ИЛИ SSH упал. Чини SSH (`bin/setup-ssh.sh`) и возвращайся.
- `13` — валидация не прошла (например, alias содержит запрещённые символы, ИЛИ на роутере лежит `config.json`, который не парсится как JSON — adopt не угадывает, см. §Граничные случаи).
- `64` — bad CLI args.

В V1 скрипт принимает **только** `--router <alias>`. Дополнительные опции (selective adopt по компонентам, dry-run на memory, force-overwrite) — future work; не выдумывай флаги.

## Шаг 2. Прочитать state.md и показать пользователю

```bash
# агент сам читает локальный файл
memory/<alias>/state.md
```

Покажи пользователю в человеко-читаемом виде, что нашлось:
- **sing-box**: установлен / версия / запущен ли как `sing-box-tproxy`.
- **DNS chain**: есть ли `https-dns-proxy` + dnsmasq + nft DNS redirect.
- **zapret**: установлен ли, есть ли nft set `vpn_servers`, заполнен ли он.
- **watchdog**: есть ли `/etc/router-watchdog.conf` и cron-задача.
- **outbounds** (из `vpns.md`): список tag → server-host:port.
- **домены** (из `domains.md`): сколько и куда.
- **LAN proxies** (из `proxies.md`): какие mixed-inbound порты подняты и на какой outbound маршрутизируются.

Также проговори:
> Сделал adopt роутера `<alias>`. Snapshot pre-adopt: `<snap-id>` (если что — откатимся). Теперь memory скилла соответствует реальному состоянию роутера. Роутер я не трогал — только прочитал конфиг и записал owner-marker.

## Шаг 3. Спросить, что делать дальше

После adopt роутер находится **в обычном режиме скилла**, как если бы его настраивал `install-vpn.sh`. Спроси пользователя:

- Добавить домен в VPN-список → `runbooks/02-add-domain.md` (`bin/add-domain.sh`).
- Добавить ещё одну VPN-ноду → `runbooks/03-add-vpn.md` (`bin/add-vpn.sh`).
- Пробросить LAN proxy на порт 4000-4099 → `runbooks/04-add-proxy.md` (`bin/add-proxy.sh`).
- Ничего не менять, просто наблюдать → периодически `bin/doctor.sh --router <alias>` и `bin/health.sh --router <alias>`.

Если пользователь не уверен — рекомендуй сначала `bin/health.sh --router <alias>` для smoke-теста (проверит, что текущий setup реально работает: sing-box up, DNS, exit IP через outbound).

## Граничные случаи

- **sing-box не установлен совсем** (нет `/usr/bin/sing-box`, `/etc/sing-box/`).
  → **НЕ запускай adopt.** Adopt не делает bootstrap. Иди в `runbooks/01-first-time.md` и используй `bin/install-vpn.sh` для полной установки с нуля.
- **sing-box установлен, но `/etc/sing-box/config.json` пустой / битый JSON.**
  → adopt **запустится** и пройдёт. `vpns.md`/`domains.md`/`proxies.md` будут пустыми (или с одной строкой-предупреждением). `install-state.json` создастся с пустым profile. После adopt **обсуди с пользователем**: либо они правят конфиг руками (escape hatch), либо стартуют чисто (`bin/install-vpn.sh` с новой `vless://`-ссылкой — но это перезапишет текущий конфиг, snapshot уже есть).
- **`install-state.json` уже есть на роутере** (роутер уже под скиллом).
  → adopt **idempotent**. Перезапишет `vpns.md`/`domains.md`/`proxies.md` из реального состояния. `install-state.json` **не пересоздаётся** заново — обновляется только `last_modified_at` и пишется journal event `adopted_existing_setup` с пометкой "re-adopt". Это **полезный сценарий**, если пользователь руками правил `/etc/sing-box/config.json` через escape hatch и хочет, чтобы memory снова соответствовала реальности.
- **Rollback runtime (`/usr/lib/vpn-kit/`) есть, `install-state.json` нет.**
  → adopt.sh внутри сам вызовет `bin/adopt-safety-state.sh`, чтобы пересобрать `install-state.json` под существующий rollback-рантайм. Агенту делать ничего не нужно — это деталь реализации.
- **Конфликт: outbound в `config.json` имеет tag, который уже есть в `vpns.md`, но с другим `server`.**
  → adopt **всегда пишет реальное состояние** (источник правды — роутер, а не memory). При конфликте в `memory/<alias>/journal.md` будет добавлен warning `adopt_tag_conflict` с обоими значениями. Покажи warning пользователю.
- **Watchdog есть, но `TG_TOKEN` пустой / placeholder.**
  → adopt запишет в `state.md` `watchdog: configured but TG_TOKEN missing`. Предложи пользователю `bin/setup-watchdog.sh --router <alias>` для перенастройки (см. `01-first-time.md §Шаг 4`).
- **Несколько sing-box init.d wrapper'ов** (например, и `sing-box`, и `sing-box-tproxy`).
  → adopt запишет оба в `state.md`. Это redundancy, но не блокер. Дальше — на усмотрение пользователя; чистить руками через escape hatch.

## Что adopt НЕ делает (критично)

Проговори это пользователю явно, особенно если он переживает за работающий setup:

- **НЕ устанавливает пакеты** (`apk install` не вызывается).
- **НЕ запускает и не перезапускает сервисы** (никаких `service sing-box-tproxy restart`).
- **НЕ модифицирует конфиг на роутере** — `config.json`, init.d, dnsmasq, nft rules остаются как есть.
- **НЕ удаляет** ничего на роутере.
- **НЕ читает** клиентские секреты из конфига (см. §Безопасность секретов).

Adopt делает **ровно четыре** вещи: snapshot + read + render memory + journal. Плюс одна крошечная запись на роутер: `install-state.json` (owner marker, не runtime).

## Безопасность секретов

Adopt **намеренно** не читает из `/etc/sing-box/config.json` следующие поля:
- `uuid` (VLESS client ID)
- `password` (для trojan/ss/etc, если когда-то будут)
- `reality.private_key` / `reality.public_key`
- `reality.short_id`
- любые `*_key`, `*_secret`, `*_token`

В `memory/<alias>/vpns.md` после adopt лежит только: `tag`, `type`, `server` (host), `server_port`. Этого достаточно, чтобы агент мог ссылаться на outbound по tag в `add-domain` / `remove-vpn` и т.п. — но недостаточно, чтобы восстановить рабочий outbound из memory.

Это **сознательное ограничение V1**: memory остаётся безопасной для git / для пересылки в чате / для логов. Если пользователю когда-нибудь понадобится "пересоздать конфиг из memory" — это потребует нового `vless://` URL от провайдера, не из memory.

Если в `config.json` нашлась нестандартная схема (vmess/trojan/shadowsocks) — adopt запишет в `vpns.md` `type=<схема>`, `server=<host>:<port>`, `tag=<tag>` без секретов; но **редактировать** такие outbound через `add-vpn.sh`/`remove-vpn.sh` в V1 нельзя (см. `SKILL.md §Scope V1`). Только просмотр.

## Что обновляется в memory/

- `memory/<alias>/state.md` — полный чек-лист, как после `bin/doctor.sh`.
- `memory/<alias>/vpns.md` — все outbound'ы из `config.json`, без секретов.
- `memory/<alias>/domains.md` — все домены из `rules/vpn-domains.json` и других rule-set'ов.
- `memory/<alias>/proxies.md` — все mixed-inbound порты 4000-4099 (и более широко — все mixed-inbound'ы, если есть нестандартные).
- `memory/<alias>/journal.md` — событие `adopted_existing_setup` с полем `snapshot_id` (pre-adopt snapshot) и сводкой найденных компонентов; опционально warnings (`adopt_tag_conflict`, `adopt_config_unparseable_section`, etc).
- `memory/<alias>/quirks.md` — **не трогается**. Если хочешь зафиксировать что-то про этот роутер (например, "конфиг изначально настраивал X через инструмент Y") — попроси пользователя дописать руками.
- `memory/routers.yaml` — **не трогается**. Регистрация alias-а должна быть **до** adopt.

## Exit codes (общие для adopt.sh)

| Code | Значение |
|------|----------|
| 0 | OK, memory собрана, install-state записан, journal обновлён |
| 2 | router не найден в `memory/routers.yaml`, ИЛИ SSH unreachable |
| 13 | VALIDATION (битый alias, или невалидный JSON в `config.json` на роутере) |
| 64 | bad CLI args (что-то кроме `--router <alias>`) |

Кода `20` (rollback) тут **нет** — adopt не делает mutating-операций на runtime, откатывать нечего. Pre-adopt snapshot создаётся через `backup-now.sh` (его exit codes — отдельная история, но если упадёт, adopt вернёт `1` или `2` и не пойдёт дальше).

## Что сказать пользователю (шаблон финального сообщения)

```
Готово, роутер <alias> теперь под управлением скилла.

Pre-adopt snapshot: <snap-id> (откат через `bin/restore.sh --router <alias> --snapshot <snap-id>`)

Что нашёл на роутере:
- sing-box: <версия>, status: <running|stopped>
- Outbounds: <N> штук — <tag1>, <tag2>, ...
- Домены под VPN: <M> штук
- LAN proxy: <list of port → outbound | нет>
- DNS chain: <ok | частично | нет>
- Watchdog: <ok | TG_TOKEN missing | нет>

Memory обновлена:
- memory/<alias>/state.md (полный чек-лист)
- memory/<alias>/vpns.md, domains.md, proxies.md

Что я НЕ делал: не ставил пакеты, не рестартил sing-box, не правил конфиг — только прочитал.

Что дальше — добавить домен / VPN / proxy, или просто наблюдать через `bin/doctor.sh`?
```

## НЕ ДЕЛАТЬ

- НЕ запускай `bin/adopt.sh`, если sing-box на роутере **не установлен**. Это не bootstrap; используй `01-first-time.md`.
- НЕ запускай `bin/install-vpn.sh` после adopt в надежде "довести до состояния скилла" — adopt уже привёл состояние к нужному, install-vpn перезапишет существующий конфиг.
- НЕ редактируй вручную сгенерированный `memory/<alias>/vpns.md`, чтобы дописать туда `uuid`/`private_key` "для удобства". Это нарушает контракт `SKILL.md §Жёсткие правила п.3`.
- НЕ пропускай шаг 2 (показ state.md пользователю). После adopt пользователь должен **подтвердить**, что то, что нашлось, — действительно его setup, и в нём нет неожиданностей.
- НЕ ретраить adopt при exit `13` "битый config.json" — конфиг невалиден на роутере, это нужно чинить руками (escape hatch, см. `99-escape-hatch.md`) **до** повторного adopt.

## См. также

- `bin/doctor.sh` — probe состояния (adopt использует тот же путь probe'а внутри).
- `bin/install-vpn.sh` — путь bootstrap для **чистого** роутера (когда adopt не применим).
- `bin/add-domain.sh` / `bin/add-vpn.sh` / `bin/add-proxy.sh` — что делать после успешного adopt.
- `bin/adopt-safety-state.sh` — низкоуровневая утилита для пересборки `install-state.json` под существующий rollback-рантайм; вызывается из `adopt.sh` автоматически, агенту напрямую не нужна.
- `runbooks/01-first-time.md` — альтернативный путь (полный bootstrap с нуля).
- `runbooks/05-restore.md` — откат, если после adopt пользователь решит вернуть всё к pre-adopt состоянию.
- `SKILL.md §Scope V1` — что поддерживается (VLESS Reality) и что нет (vmess/trojan/awg) — важно при описании пользователю того, что нашлось на adopt-нутом роутере.
