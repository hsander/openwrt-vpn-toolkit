# Runbook 08 — Pin LAN-устройства на конкретный outbound

## Когда использовать

Триггеры от пользователя: «всегда через DE для моего ноута 192.168.1.158», «pin device X на outbound Y», «conn по source IP», «192.168.1.X должен ходить через Германию», «закрепи телек за нодой US», «весь VLAN гостей в outbound guests-de».

Pre-conditions (что должно быть в `memory/<alias>/state.md`):
- Пункт 11 «`config.json` валиден» = ✅
- Пункт 13 «tproxy запущен» = ✅
- Пункт 14 «≥1 VPN outbound + auto-failover» = ✅
- Конкретный outbound `<tag>` существует в `memory/<alias>/vpns.md`.

Дополнительно: на роутере должен присутствовать `/etc/vpn-kit/install-state.json` — `pin-device.sh` требует install-state (exit 13 «install-state.json отсутствует» иначе). Если так — отправь на `01-first-time.md` или `06-adopt-existing.md`.

Различие:
- `add-ip.sh` — заворачивает **destination IP** в VPN (через общий `proxy_subnets` set; маршрутизируется через auto-failover).
- `pin-device.sh` — заворачивает **source IP** (LAN-клиент) на **конкретный outbound** (минуя auto-failover). Это two-way: и для отдельного устройства, и для всей подсети.

## Шаг 1. Что спросить у пользователя

1. **Source: один IP или подсеть?**
   - **Конкретный IP** (одно устройство, например IPTV-приставка) → `--source-ip <ip>`. Только `/32` (или bare IPv4 без слэша → нормализуется в `/32`).
   - **Подсеть** (несколько устройств, например VLAN или гостевая сеть) → `--source-cidr <cidr>`. **ВАЖНО**: переспроси:
     > Pin'ить подсеть = pin'ить **ВСЕ** устройства в ней. Уверен? Если хочется одно устройство — `--source-ip <ip>`.

2. **Outbound tag (обязательно).** Должен быть в `memory/<alias>/vpns.md` (`pin-device.sh` сам проверит через `jq` на роутере). Если пользователь сказал «через Германию» — найди соответствующий tag в `vpns.md` и подтверди.

3. **Если outbound = `direct`** (т.е. отключить VPN для устройства) — это валидный use-case (например, smart-TV который не должен ходить через VPN из-за geo-блокировок). Но **переспроси**: «`direct` — это значит **выключить VPN** для этого устройства. Правильно понял?»

### Валидация source локально (до запуска скрипта)
- IPv4 формат — стандартная dotted-quad, октеты 0-255.
- **Запрещены без вариантов** (bogon refuse, `--force` не помогает):
  - `0.0.0.0/8` (unspecified)
  - `127.0.0.0/8` (loopback)
  - `169.254.0.0/16` (link-local)
  - `224.0.0.0/4` (multicast)
  - `240.0.0.0/4` (reserved)
  - `255.x` (broadcast)
- IPv6 — только с `--allow-ipv6`, и init.d должен содержать `ip6 saddr|ip6 daddr` правила (иначе exit 13).

### Спец-случай: подсеть пользователя ⊇ LAN
Если `--source-cidr` накрывает LAN (например, `0.0.0.0/0` или `192.168.0.0/16` при LAN `192.168.1.0/24`) — `pin-device.sh` сам откажет с exit 13. Это значит **весь LAN, включая роутер, уйдёт в outbound** — путь к разрыву SSH. С `--force` пропустит, но это почти всегда ошибка — для «весь LAN через VPN» правильнее `add-ip --ip <LAN-CIDR>` (см. `07-add-ip.md`), а не pin-device.

## Шаг 2. Выполнение

Single device:
```bash
bin/pin-device.sh --router <alias> --outbound <tag> --source-ip <ip>
```

Subnet:
```bash
bin/pin-device.sh --router <alias> --outbound <tag> --source-cidr <cidr> [--force]
```

Опции:
- `--force` — (a) перепишет существующий pin для того же source (без `--force` exit 13 «уже привязан к outbound X»), (b) разрешит `/0` catch-all или CIDR ⊇ LAN. НЕ используй сам, спроси пользователя.
- `--allow-ipv6` — IPv6 source. По умолчанию только IPv4.
- `--no-backup` — **только для тестов**. Rollback недоступен без snapshot'а.

Что делает:
1. Валидация CLI + source (IPv4/CIDR, bogon refuse, LAN-overlap для `--source-cidr`).
2. SSH preflight + verify что outbound существует в `/etc/sing-box/config.json` (через `jq` на роутере).
3. snapshot (`backup-now.sh`) → `snapshot_id`.
4. CAS preflight install-state + ownership-expand (добавляет `config.json` в `files_owned_by_skill`).
5. Drift-check `config.json` через `adopted_config_sha256` (exit 30 без `--force`).
6. Idempotency: если pin уже есть на тот же outbound → no-op (exit 0). На другой outbound → exit 13 без `--force` / overwrite с `--force`.
7. `jq` mutation: вставляет `{action:"route", source_ip_cidr:[<src>], outbound:<tag>}` в `.route.rules` **перед catch-all rule**.
8. `sing-box check` на роутере → atomic mv в `/etc/sing-box/config.json`.
9. Patch `/etc/init.d/sing-box-tproxy`: вставляет `nft add rule ... <pin_id>` **перед FakeIP rule**. Comment-based idempotency (`vpn-kit-pin-<sha256(src)[:12]>`).
10. Atomic mv init.d.
11. Runtime `nft insert rule ... position <fakeip_handle>` — нужно чтобы порядок persistent==runtime.
12. CAS-write `install-state.dynamic_additions[]` с retry ×3.
13. Restart `sing-box-tproxy` + 30s reachability watch → auto-rollback на потере SSH.
14. Sanity: sing-box процесс жив.
15. Render `memory/<alias>/pins.md` + journal.

Exit codes:
- `0` — pin применён (или no-op idempotent).
- `2` — router/ssh / backup упал / scp упал / mv упал.
- `11` — install-state CAS STALE на ownership-expand.
- `12` — install-state LOCK contention.
- `13` — валидация (bad IP, bogon, LAN overlap без `--force`, outbound не найден, install-state отсутствует, FakeIP layout incompatibility, конфликт pin'а без `--force`, IPv6 без `--allow-ipv6`).
- `20` — staged-apply: restart/reachability fail → rollback сработал.
- `30` — drift detected без `--force` / runtime nft insert упал.
- `64` — bad CLI args / mutually-exclusive `--source-ip` + `--source-cidr`.

## Шаг 3. Подтверждение

- Output показывает `source`, `outbound`, `pin_id` (`vpn-kit-pin-<hash>`), `snapshot`, `tproxy_port`.
- Прочитай `memory/<alias>/pins.md` — должна появиться новая строка с source, scope (device/subnet), outbound, pin_id, временем, origin.
- **Пользователь тестирует с устройства**: `curl --interface <pin-ip> https://api.ipify.org` (или с самого устройства просто `curl https://api.ipify.org`) — должен вернуть exit IP outbound'а, а не дефолтный.

Если был **no-op idempotent** (тот же source → тот же outbound уже зафиксирован) — скажи пользователю, refresh `pins.md` сделался.

## Жёсткие правила безопасности

(Симметрично «реальный инцидент» секции из `03-add-vpn.md` — pin-device может разорвать SSH сильнее чем add-vpn.)

1. **Source pin'а — ТОЛЬКО из LAN-диапазона роутера.** Если `<ip>` не в `network.lan.ipaddr/network.lan.netmask` — пакеты от него никогда не дойдут до tproxy chain (mangle_prerouting срабатывает только на LAN-входящих). Pin будет «висеть» в config'е без эффекта. `pin-device.sh` сам **не** проверяет это (только LAN-overlap для `--source-cidr`); ты должен проверить сам через `vpns.md` / `network.lan.ipaddr`. Если `<ip>` не из LAN — переспроси: «`<ip>` не из LAN роутера (`192.168.1.0/24`). Pин не сработает — pакеты не дойдут до tproxy. Уверен?»

2. **CIDR ⊇ LAN требует `--force`** (скрипт C.1 проверяет автоматически). Если пользователь хочет «весь LAN через VPN» — это `add-ip --ip <LAN-CIDR> --force` (см. `07-add-ip.md`), а не pin-device. pin-device на LAN-superset = SSH-suicide.

3. **FakeIP layout incompatibility.** Если `/etc/init.d/sing-box-tproxy` не содержит FakeIP rule (`tproxy.*(198.18|fakeip)`), или содержит **несколько** таких rule (ambiguous), скрипт exit 13 «FakeIP-правило не найдено» / «ambiguous layout». Это значит install-vpn был кастомным, или drift, или старая версия. **НЕ пробуй `--force` через add-ip / raw-ssh** — нужна ручная проверка через `bin/raw-ssh.sh --reason "review tproxy layout"`, потом `bin/adopt.sh` для повторной адопции.

4. **Reachability lost после restart**. `pin-device.sh` следит за SSH 30s после restart sing-box-tproxy. Если SSH потерян → автоматический rollback через `bin/restore.sh --snapshot <id>` + best-effort `nft delete rule` по comment. Если **rollback тоже не дотянулся** (SSH полностью мёртв) — нужен IPMI/console доступ + ручной `vpn-kit-rollback` (см. `99-escape-hatch.md`). Скажи пользователю заранее: «если SSH упадёт и rollback не сработает — нужен физический доступ к роутеру».

5. **Несколько pin'ов на один и тот же source IP** — без `--force` exit 13 «source уже привязан к outbound X (не Y)». С `--force` — old pin удаляется, new вставляется (single source of truth). Журналируется как overwrite. **НЕ запускай `--force` молча** — спроси пользователя, действительно ли хочет перепривязать.

6. **`config.json` drift** (кто-то правил руками) — exit 30 без `--force`. С `--force` — скрипт продолжит, но журналируется как `drift_overridden`. Лучше — `bin/adopt.sh` для повторной адопции, потом снова pin-device.

7. **CAS desync после apply** (config.json + init.d + runtime nft применены, но install-state не обновился после 3 retries) — скрипт **не** откатывается (это сломает рабочий pin), а warn'ит. Сделай `bin/doctor.sh --router <alias>` чтобы найти desync, или просто запусти `pin-device.sh` ещё раз (no-op idempotent подхватит state).

## Что обновляется в memory/

- `memory/<alias>/pins.md` — новая строка (source, scope, outbound, pin_id, время, origin).
- `memory/<alias>/journal.jsonl` — событие `pin_device` (`source_ip`, `outbound`, `snapshot_before`, `pin_id`, `tproxy_port`, `revision`).
- `state.md` и `vpns.md` **не меняются** (outbound уже существует, мы только добавили route.rule).

## Что сказать пользователю

```
✅ Устройство <ip> теперь жёстко идёт через <outbound>.
- Pin ID: <pin_id>  (для отката по handle в nft)
- tproxy_port: <port>
- Snapshot до: <snap-id>
- install-state revision: <rev>

Откат: bin/restore.sh --router <alias> --snapshot <snap-id>
Тест с устройства: curl --interface <ip> https://api.ipify.org
  (должен вернуть exit IP <outbound>, а не твой провайдерский)
```

Если был no-op idempotent: «`<ip>` → `<outbound>` уже зафиксирован, ничего не менял. Обновил `pins.md`.»

## Edge cases / частые ошибки

- **Outbound не существует в config.json** → exit 13. Скажи пользователю: «outbound `<tag>` не найден; список tag'ов — в `memory/<alias>/vpns.md`. Опечатка?».
- **FakeIP layout не распарсился** (incompatible / ambiguous) → exit 13. Эскалация: попроси пользователя описать как был сделан tproxy (custom install-vpn? старая версия? правил руками?). Возможно нужно `bin/raw-ssh.sh` для ручного review + `bin/adopt.sh` для re-фиксации SHA.
- **CIDR ⊇ LAN без `--force`** → exit 13 «перекрывает LAN-сеть, весь LAN уйдёт в outbound». Объясни пользователю; если хочет именно весь LAN — отправь на `add-ip` с RFC1918 + `--force`.
- **`--source-cidr 0.0.0.0/0` без `--force`** → exit 13 «catch-all запрещён без `--force`». С `--force` — это «весь LAN-трафик в outbound». Переспроси.
- **config.json drift (`adopted_sha256` mismatch)** → exit 30. Решение: `bin/adopt.sh` для re-adopt, либо `--force` (журналируется как drift_overridden).
- **CAS desync после apply** → warn на stderr, exit 0. Скажи пользователю; запусти `pin-device.sh` ещё раз или `doctor.sh`.
- **Конфликт pin'а без `--force`** → exit 13 «source `<ip>` уже привязан к outbound `<other>`». Переспроси пользователя: «переписать на `<new>` (`--force`) или оставить как есть?».
- **Restart sing-box-tproxy не дал reachability в 30s** → exit 20 + auto-rollback. Не делай retry — выясни причину через `bin/logs.sh --router <alias> --source sing-box --lines 80`.
- **`--source-ip` с prefix ≠ /32 (или /128 для IPv6)** → exit 13 «--source-ip принимает только /32». Скажи пользователю: «для подсетей используй `--source-cidr`».
- **IPv6 source при init.d без `ip6` rules** → exit 13 «init.d/sing-box-tproxy не содержит ip6-правил». Решение: V1.2 / ручная правка init.d через raw-ssh.

## НЕ ДЕЛАТЬ

- НЕ pin'ить IP, который не из LAN роутера (бесполезно — пакеты не дойдут до tproxy chain).
- НЕ pin'ить `--source-cidr 0.0.0.0/0` или CIDR ⊇ LAN без явного запроса пользователя и **громкого** предупреждения про SSH-suicide.
- НЕ pin'ить device на outbound, который сам = `direct`, без переспроса (это **отключение** VPN для устройства — валидно, но редко; убедись что пользователь это понимает).
- НЕ запускать `--force` для overwrite существующего pin без явного запроса пользователя.
- НЕ запускать `--no-backup` нигде кроме smoke-тестов — rollback невозможен.
- НЕ делать ретрай после exit 20 (reachability lost) — снимок уже откатан, симптом остался; иди в `bin/logs.sh` или `99-escape-hatch.md`.
- НЕ редактировать `pins.md` руками — только через `pin-device.sh` (unpin в V1.2).
- НЕ запускать `pin-device.sh` если outbound не существует — exit 13, потери данных нет, но проверь `vpns.md` сначала.
- НЕ restart'ить `sing-box-tproxy` вручную сразу после `pin-device.sh` — скрипт уже сам restart'нул с reachability watch. Лишний restart сломает watch.
