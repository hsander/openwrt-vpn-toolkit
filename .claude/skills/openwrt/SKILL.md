---
name: openwrt
description: >-
  Safely configure and operate OpenWrt routers through the repository's predefined scripts: onboarding, backups and rollback, LAN migration, Wi-Fi uplinks, Travelmate travel-router profiles, hidden private AP recovery buttons, AWG2 site-to-site access, sing-box VLESS Reality routing, zapret, and watchdogs. Use for OpenWrt router setup or recovery, hotel or hotspot uplinks, travel Wi-Fi, Wireless Pairing visibility control, remote home-LAN access, VPN/domain/device routing, or any router named in memory/routers.yaml. Безопасная настройка OpenWrt: первичная настройка, миграция LAN, внешние Wi-Fi-сети, travel router, скрытый MobileHub и кнопка Wireless Pairing, AWG2, VPN, маршрутизация, backup и rollback.
---

# openwrt — инструкции для Claude

Этот навык управляет OpenWRT-роутером **только** через скрипты из `bin/`. Сырой SSH запрещён (escape hatch требует явного подтверждения пользователя).

## Когда срабатывает

- Пользователь упоминает имя роутера из `memory/routers.yaml`
- "Настрой роутер", "первичная настройка openwrt", "добавь домен в VPN", "добавь новый VPN", "пробрось proxy", "сделай backup", "откати"
- "Сделай роутер для путешествий", "подключи к Wi-Fi гостиницы/телефона", "настрой Travelmate", "дай доступ домой через AWG2", "как подключить внешнюю сеть с планшета"
- "Скрой/покажи MobileHub", "показывай Wi-Fi на 10 минут кнопкой", "настрой Wireless Pairing/WPS button"
- "Travel router", "hotel Wi-Fi", "captive portal", "Wi-Fi uplink", "site-to-site", "AWG2", "change/migrate LAN subnet"
- "Адоптируй роутер", "синхронизируй memory", "у меня уже настроен sing-box, помоги управлять", "install-vpn упал с existing-sing-box-config-not-owned" → **runbook `runbooks/06-adopt-existing.md` + `bin/adopt.sh`** (read-only sync без модификации роутера)
- В чате видишь `vless://...`, `bot<digits>:<token>`, host `192.168.1.1` или подобный

## Жёсткие правила

1. **НЕ запускай сырой `ssh root@...`.** Все операции — через `bin/<op>.sh --router <alias> [args]`.
2. **Перед любой mutating-операцией — `bin/backup-now.sh --router <alias> --label "<reason>"`.** Скрипты `add-*/remove-*/install-*` делают это сами; если делаешь руками — не пропускай.
3. **Секреты никогда не пишутся в memory/, journal, MD-файлы, git.** Паттерны: `vless://`, `bot<d>:`, `TG_TOKEN=`, `BOT_TOKEN=`, любые UUID/private_key. Если случайно прилетело в команду — отказывайся и проси перевводить.
4. **Валидация перед записью.** Скрипты вызывают `sing-box check` и `sing-box rule-set format` сами. Если они вернули exit ≠ 0 — операция уже откатилась, не «дожимай».
5. **Memory обновляется ТОЛЬКО после успешного exit 0** скрипта. Скрипты делают это сами через `lib/notes-write.sh` и `lib/journal-append.sh`.
6. **Не модифицируй `bin/_lib/` и `lib/`.** Это контракт. Если нужна новая операция — новый скрипт в `bin/`.
7. **Не редактируй файлы на роутере напрямую** (через ssh + редактор). Только через скрипты, которые делают atomic write + validate + rollback.
8. **Доверяй doctor probe только при `probe_reliable=true`.** В отчёте `state.md` поля `outbound_count`, `outbounds_detail`, `rule_set_domains` зависят от наличия `jq` на роутере и парсабельности `/etc/sing-box/config.json`. Если `probe_reliable=false` (jq отсутствует, config битый):
   - Строки чек-листа 11 и 14 показываются как `⚠` с пояснением, **не как `✗`**. Не утверждай пользователю «у тебя нет VPN/outbound'ов» — ты этого не знаешь.
   - `adopt.sh` **откажется работать** (exit 2) — иначе он рендерит ложную `vpns.md`/`domains.md`/`proxies.md`. Сначала установи jq: `ssh <alias> 'apk add jq || (opkg update && opkg install jq)'`, затем повтори.
   - Реальный инцидент, из которого это правило выросло: на чужом роутере без jq doctor выдал `outbound_count: 0`, adopt записал «пустую» память, а в действительности там было 6 mixed-inbound прокси и работающий VLESS-outbound.

## Структура

```
bin/                   # ← safe API: read-only probe или guarded mutation
  doctor.sh            # probe состояния роутера (drives state.md)
  setup-ssh.sh         # gen ed25519 + install + ~/.ssh/config alias
  setup-watchdog.sh    # /etc/router-watchdog.conf + cron
  install-vpn.sh       # парсит vless://, поднимает sing-box на чистом роутере
  adopt.sh             # уже настроенный роутер → snapshot + probe + рендер memory (read-only)
  add-domain.sh        # → rules/vpn-domains.json (auto-failover) или rules/user-<tag>-domains.json (per-tag), validate, hot reload
  remove-domain.sh
  set-rule-set-outbound.sh # сменить outbound у существующего route.rules rule_set (например telegram/tg-pin)
  add-vpn.sh           # outbound + auto-failover + zapret2 ip-exclude
  remove-vpn.sh
  remove-pool-members.sh # убрать ноды только из urltest-пула, сохранив outbounds
  add-proxy.sh         # mixed-inbound :400X + route rule
  remove-proxy.sh
  add-ip.sh            # add IP/CIDR в proxy_subnets nft-set (общий, через --via auto). Per-tag pin TBD.
  pin-device.sh        # pin source IP/CIDR from br-lan or an explicit input interface.
  unpin-device.sh      # снять pin LAN-устройства (обратная операция pin-device.sh).
  backup-now.sh        # snapshot of /etc/sing-box, init.d/*, /etc/config, watchdogs
  inspect-awg2.sh      # secret-free AWG2/platform/uplink inventory
  awg2-public-key.sh   # print only an existing interface public key
  install-awg2-packages.sh # pinned AWG2 packages for supported SmartBox/OpenWrt target
  configure-awg2-client.sh # AWG2 client; private key is generated on-router
  add-awg2-home-peer.sh # persist and live-add a travel peer on home
  setup-wifi-uplink.sh # WPA2 station uplink; password only through stdin/env
  clone-wifi-uplink.sh # copy one uplink credential router-to-router without disclosure
  install-travelmate.sh # official Travelmate + LuCI packages; service stays disabled
  configure-travel-router.sh # dual-band private AP + uncommon LAN + AWG site route
  configure-home-travel-route.sh # home-side AllowedIPs + route, live via awg set
  inspect-travel-router.sh # read-only travel profile inventory
  inspect-router-buttons.sh # read-only button labels, handlers and recent events
  install-travel-ap-button.sh # short press toggles timed private-AP visibility
  verify-travel-ap-button.sh # installed hashes, timer and hidden-state proof
  verify-awg2-link.sh # secret-free AWG2 runtime verification
  verify-wifi-uplink.sh # association, DHCP, route, internet and DNS proof
  verify-travel-router.sh # AP/DHCP/LuCI/split-route/site-to-site verification
  inspect-lan-migration.sh # read-only migration baseline
  install-lan-migration-runtime.sh # install rollback runtime without network reload
  test-lan-migration-runtime.sh # non-network timer/lock/restore self-test
  prepare-home-lan-migration.sh # build and prepare the home migration bundle
  supervise-home-lan-migration.sh # external three-pass verifier and confirmer
  migrate-lan.sh       # transactional prepare/cutover/confirm/rollback client
  audit-lan99-cleanup.sh # read-only proof before removing compatibility subnet
  prepare-home-lan-cleanup.sh # prepare final legacy-subnet removal
  supervise-home-lan-cleanup.sh # external cleanup verifier and confirmer
  migrate-home-server-lan.sh # home-server gateway/DNS transaction
  finalize-home-server-lan99.sh # remove the home-server compatibility address
  finalize-lan99-metadata.sh # remove stale non-routing LAN metadata
  cleanup-lan-migration-builds.sh # remove only unprepared /tmp bundle builds
  set-root-password.sh # password via stdin; never argv/journal/memory
  reboot-router.sh     # reboot through a stable alias and wait for SSH recovery
  snapshot-list.sh
  restore.sh           # staged-apply из snapshot
  health.sh            # sing-box status, nft, DNS resolve, SOCKS exit IP
  logs.sh              # tail sing-box / watchdog / zapret2
  raw-ssh.sh           # ⚠ escape hatch — требует явное "yes" в чате

lib/                   # утилиты, которые source'ятся скриптами (НЕ для агента)
  vpn-kit-common.sh    # flock/atomic-write/secrets-filter/sha256
  state-{read,write}.sh
  notes-{read,write}.sh
  journal-append.sh
  staged-apply.sh      # snapshot → write → restart → reachability → auto-rollback
  rollback-snapshot.sh
  reachability-check.sh
  ...

memory/                # ← агент-сайд память. Источник правды для агента
  routers.yaml         # реестр: alias → host, user, ssh_key, добавленные домены счётчик
  _templates/          # болванки для нового роутера (копируются в memory/<alias>/)
  <router-alias>/      # одна папка на роутер
    state.md           # чек-лист настроек (✅/❌ по 20 пунктам)
    domains.md         # таблица: домен → outbound (auto-failover|tag)
    vpns.md            # таблица: tag → server-host, port (БЕЗ uuid/private_key)
    proxies.md         # таблица: port (4000-4099) → outbound
    quirks.md          # выученные нюансы этого роутера
    journal.md         # лог: time | op | snapshot_id | result

templates/             # шаблоны конфигов (jinja-like {{vars}}) — для скриптов
schemas/               # JSON-схемы для валидации
runbooks/              # пошаговые гайды для агента (под каждый сценарий)
openwrt/               # файлы, которые ставятся НА роутер (init.d/, etc)
```

## Поток "первый запуск" для нового роутера

Триггер: пользователь просит «настрой роутер», или нет папки `memory/<alias>/`.

1. **Спроси alias и host**. Сохрани в `memory/routers.yaml` (если нет ещё).
2. **Запусти `bin/doctor.sh --router <alias>`**. Если SSH не работает — сначала `bin/setup-ssh.sh`.
3. **Покажи `memory/<alias>/state.md`** пользователю. Спроси, что настраивать. Минимум стоит предложить (в порядке зависимостей):
   - SSH key + alias (если не сделано)
   - watchdog с TG_TOKEN
   - первичный VPN (нужна `vless://...` ссылка)
   - DNS chain + dnsmasq + nft DNS redirect (часть `install-vpn.sh --activate`)
4. **На запрос VPN-ссылки**: если пользователь не хочет вставлять секрет в чат — выведи ему инструкцию `runbooks/01-first-time.md §VPN-manual` и попроси сообщить когда готово (после ручной правки `/etc/sing-box/config.json` запусти `bin/doctor.sh` снова).
5. После каждой успешной операции — `state.md` и `journal.md` обновлены скриптом; **прочитай их и подтверди**, что всё применилось.

## Scope V1 (чёткие границы)

**Поддержано:**
- VLESS Reality outbounds (только эта схема URL).
- **Country-pool routing**: `--outbound usa` / `--outbound pl` / `--outbound sg` резолвится в `usa-pool` / `pl-pool` / `sg-pool` через `lib/country-resolve.sh` + `memory/<alias>/countries.yaml`. Работает в `add-domain`, `add-proxy`, `pin-device`. `auto-failover` = urltest над пулами.
- `add-vpn --country <code>` — новая нода идёт в pool страны (создаёт pool если нет), а не в `auto-failover` напрямую.
- `add-domain` с `--outbound auto-failover` (→ `vpn-domains.json`) и с `--outbound <tag|страна>` (→ `user-<tag>-domains.json`, файл + маршрут создаются автоматически).
- `remove-domain` сканирует все `*.json` в `/etc/sing-box/rules/` — работает для любого rule-set файла, включая JSONC с `//`-комментариями.
- `set-rule-set-outbound.sh` — меняет outbound у уже существующего `route.rules` rule-set без ручного редактирования `config.json`; нужен для сервисных rule-set'ов (`telegram`, `tg-pin`, `spotify-usa`, etc.), которые могут перекрывать новые доменные правила.
- LAN proxy на mixed-inbound портах 4000-4099.
- `add-ip.sh` — IPv4-адреса/CIDR в общий nft-сет `proxy_subnets` (`--via auto`, без per-tag pin).
- `pin-device.sh` — pin source IP/CIDR на конкретный outbound через
  `route.rules` + nft tproxy. Default input — `br-lan`; для трафика из туннеля
  используй проверенный `--input-interface <ifname>`.
- Telegram-watchdog, snapshot/restore, raw-ssh escape hatch.
- Travel-router profile: official Travelmate/LuCI, protected dual-band AP,
  uncommon `/24` LAN, split routing to home over an existing AWG2 tunnel, and
  bidirectional home/travel reachability.
- Optional hidden-by-default private AP recovery: a short Wireless Pairing/WPS
  press exposes both MobileHub bands for 600 seconds; another short press hides
  them immediately. Require physical proof per router before recording success.
- AWG2 management/site-to-site interfaces for the supported SmartBox target,
  including live peer updates without restarting the home WAN.
- Transactional LAN migration with prepare/cutover/confirm/rollback and explicit
  recovery endpoints.

**НЕ поддержано в V1** — если пользователь просит, агент должен прямо отказаться и сослаться на эту секцию:
- Прошивка OEM/stock firmware, bootloader recovery и model-specific rescue до
  установки OpenWrt — для них пока нет безопасного `bin/*` workflow.
- AmneziaWG / WireGuard **outbounds inside sing-box** (`awg://`, `.conf`-файлы)
  — нет рендеринга в sing-box config. Это не относится к поддержанному AWG2
  site-to-site интерфейсу OpenWrt для управления и доступа в домашнюю LAN.
- vmess/trojan/shadowsocks — парсер только под `vless://`.
- IPv6 для `add-ip.sh` — TBD (V1 поддерживает только IPv4).
- Per-tag pinning для `add-ip.sh` (`--via <tag>`) — TBD; работает только `--via auto`.
- `remove-ip.sh` — TBD; откат — через `bin/raw-ssh.sh` либо `bin/restore.sh --snapshot <id>`.
- Multi-router fleet операции (всё всегда per-`--router`).
- Реконсиляция `domains.md`/`vpns.md`/`proxies.md` после `restore` или после `raw-ssh` — память остаётся «stale-with-warning».
- Geo-листы доменов (RU/CN/etc) — `add-domain` принимает только одиночные домены.

## Внутренние скрипты (НЕ вызывать напрямую)

Эти файлы вызываются только публичными `bin/*` workflow или устанавливаются на
целевую систему. Не запускай их напрямую:

- `install-minimal.sh`, `install-safety.sh`, `render-minimal-config.sh` — внутренности `install-vpn.sh`.
- `preflight-minimal.sh`, `detect-system.sh`, `detect-lan.sh`, `check-conflicts.sh` — pre-flight чеки.
- `adopt-safety-state.sh`, `session-sync.sh` — sync-машинерия (унаследовано).
- `_doctor_remote.sh` — runs ON router, вызывается только `doctor.sh`.
- `build-home-lan-cleanup-bundle-remote.sh`,
  `home-server-lan99-{rollback,finalize-remote,finalize-rollback}.sh`,
  `lan99-reconcile-rollback-remote.sh` — payload/rollback helpers сценария LAN99.
- `reconcile-home-lan-runtime.sh`, `reconcile-home-lan-final-runtime.sh`,
  `renew-legacy-lan-clients.sh`, `verify-router-core-via-ssh.sh` и
  `verify-ssh-endpoint.sh` — вызывай только в порядке из
  `runbooks/11-lan-migration.md`, а не как самостоятельные изменения.
- `lib/build-home-lan-bundle-remote.sh` и `lib/lan-migrate-runtime.sh` — bundle
  builder и router-local transaction engine.

Если непонятно, что вызывать — посмотри в этот файл (`SKILL.md`) и `README.md`. Эти два — source of truth для safe API.

## Поток "добавить домен"

```
bin/add-domain.sh --router <alias> --domain <domain> [--outbound <tag|страна>]
```

`--outbound` по умолчанию = `auto-failover`. Поддерживает страну (`usa`, `pl`, `sg`) и любой outbound-tag:

| `--outbound` | rule-set файл | config.json |
|---|---|---|
| `auto-failover` | `rules/vpn-domains.json` (tag: `vpn-domains`) | добавляется в auto-failover rule |
| `<tag>` (напр. `usa-4`) | `rules/user-<tag>-domains.json` (tag: `user-<tag>`) | создаётся новый route rule перед auto-failover + DNS fakeip |

Outbound `<tag>` должен уже существовать в `config.json` (иначе exit 13). Файл rule-set создаётся при первом добавлении домена.

Что скрипт делает:
1. Pre-backup → snapshot ID запоминается.
2. Тянет rule-set файл (или создаёт v3-болванку), мерджит домен.
3. Атомарная запись на роутере → `sing-box rule-set format` → `sing-box check`.
4. Если нужно — прописывает rule_set в `dns.rules` (fakeip) и `route.rules` в `config.json`.
5. Hot-reload sing-box (без restart).
6. `memory/<alias>/domains.md` и `journal.md` обновлены.

Если exit ≠ 0 — snapshot уже восстановлен. Прочитай stderr и сообщи пользователю.

## Поток "переключить существующий rule-set на другой outbound"

```
bin/set-rule-set-outbound.sh --router <alias> --rule-set <rule_set_tag> --outbound <tag|pool>
```

Используй, когда пользователь просит переключить уже настроенный сервис/набор правил на другой сервер/страну: например «переключи Telegram на Польшу». Сначала проверь `doctor.sh` и `state.md`: если нужный домен уже попадает в более ранний rule-set (`telegram`, `tg-pin`, `spotify-usa`, etc.), обычный `add-domain.sh` не изменит реальный маршрут — нужно менять outbound у самого `route.rules` rule-set.

Скрипт делает snapshot, проверяет наличие outbound, скачивает `config.json`,
меняет только правила с указанным `rule_set`, валидирует число `route.rules`,
запускает `sing-box check`, применяет конфиг, сбрасывает FakeIP cache и
перезапускает `sing-box-tproxy`. После exit 0 запусти
`bin/doctor.sh --router <alias> --json` и проверь `rule_set_outbound_map`.

Если скрипт предупредил, что FakeIP reset/restart не прошёл, не открывай сырой
SSH автоматически: сначала выполни `bin/health.sh` и `bin/logs.sh`, затем либо
откати snapshot, либо запроси явное подтверждение на escape hatch.

**⚠ Тег rule_set — это tag из `route.rules[].rule_set`, не имя файла.** Они
могут различаться. Получай теги из `bin/doctor.sh --router <alias> --json`, не
через сырой SSH.

## Поток "добавить VPN"

```
bin/add-vpn.sh --router <alias> --url "vless://..." [--tag <name>] [--add-proxy-port 4001]
```
Скрипт:
1. Парсит URL → outbound JSON, валидирует.
2. Snapshot.
3. Добавляет outbound, обновляет `auto-failover.outbounds`, добавляет server-IP в zapret2 ip-exclude (`/opt/zapret2/ipset/zapret-ip-user-exclude.txt`) — чтобы DPI-десинк не ломал хендшейк туннеля к новому серверу.
4. Опционально `mixed`-inbound на указанном порту + route rule.
5. `sing-box check` → staged-apply restart с reachability watchdog (TCP к роутеру каждые 5s, если потеряли — auto-rollback).
6. `memory/<alias>/vpns.md` + journal.

**Никогда не пиши UUID/private_key/short_id в чат, в журнал, в MD.** Скрипт сам шифрует то, что попадает в memory (только server-host:port + tag).

## Поток "восстановление"

```
bin/snapshot-list.sh --router <alias>
bin/restore.sh --router <alias> --snapshot <id>
```
Restore тоже делает pre-snapshot (двойной), чтобы можно было откатить откат.

## Поток "travel router / роутер для путешествий"

Триггер: пользователь хочет подключать роутер к Wi-Fi гостиницы, телефона или
другой внешней сети с телефона/планшета и сохранять доступ к домашней LAN.

1. Прочитай `runbooks/12-travel-router.md` целиком.
2. Проверь уникальность travel-LAN: не используй распространённые upstream-сети
   `192.168.0.0/24` и `192.168.1.0/24` и не повторяй subnet другого travel peer.
3. До смены LAN докажи стабильный SSH alias через AWG2 и сделай snapshot через
   этот alias.
4. Пароли private AP и внешнего Wi-Fi принимай только через stdin. Не помещай их
   в argv, чат-вывод, memory, journal или Markdown.
5. Настрой Travelmate с `trm_autoadd=0` и `trm_vpn=0`: внешние сети добавляются
   пользователем явно, а AWG2 восстанавливается независимо через netifd.
6. Если нужен скрытый MobileHub, сначала проверь travel-профиль с видимым SSID,
   затем выполни read-only inventory кнопок и установи handler строго по
   `runbooks/12-travel-router.md`. Software event не заменяет физическое нажатие.
7. После применения докажи отдельно: private AP/DHCP/LuCI, Wi-Fi uplink,
   internet/DNS, AWG2 handshake, маршрут только домашней LAN через AWG2,
   обратный маршрут на home, физический toggle кнопкой и полный recovery после
   reboot. Не записывай button feature в memory конкретного роутера до этого.

Короткую инструкцию для пользователя на английском и русском бери из секции
`Connect to a new external Wi-Fi / Подключение к новой внешней Wi-Fi сети` в
`runbooks/12-travel-router.md`.

## Escape hatch (raw ssh)

```
bin/raw-ssh.sh --router <alias>
```
**Прежде чем запустить** — спроси у пользователя явное подтверждение: «нужно открыть прямой SSH к <alias>, потому что <причина>. Ok?». Без «yes/ok/да» — не запускай. Каждый вызов пишется в `memory/<alias>/journal.md` с тегом `raw_ssh_session`.

Когда оправдано:
- доктор показывает что-то странное, что не покрыто скриптами (например, неизвестная UCI секция)
- нужна разовая диагностика, которой нет в `health.sh`
- пользователь явно просит

Когда НЕ оправдано:
- «лень делать через add-domain» → используй add-domain
- любая mutating операция, для которой есть скрипт

Для старой OEM-прошивки без SSH-ключа допустим только явно подтверждённый
`bin/raw-ssh.sh --password-auth`: TCP/22 проверяется без BatchMode, пароль
вводится интерактивно и нигде не сохраняется, а legacy `ssh-rsa` разрешается
только в этой сессии. Это диагностический escape hatch, не workflow прошивки.

## Exit codes (общие для всех bin/*)

| Code | Значение |
|------|----------|
| 0 | OK, memory обновлена |
| 1 | Generic error (см. stderr) |
| 2 | Не нашёл роутер в `memory/routers.yaml` или нет SSH-доступа |
| 11 | STALE state — кто-то изменил memory параллельно, retry |
| 12 | LOCK — другая операция в процессе |
| 13 | VALIDATION — невалидный ввод (битый URL, секрет в публичном поле) |
| 20 | Rollback сработал — операция отменена, состояние = до операции |

## Env vars

| Var | Default | Назначение |
|-----|---------|------------|
| `OPENWRT_SKILL_HOME` | dir со SKILL.md | корень навыка (для `memory/`, `bin/`, `lib/`) |
| `OPENWRT_SKILL_MEMORY` | `$HOME/.openwrt-skill/memory` или `<repo>/memory` | где живут MD-файлы |
| `OPENWRT_SKILL_DRY_RUN` | unset | если 1, ничего не пишется ни на роутер, ни в memory |
| `OPENWRT_SKILL_NO_BACKUP` | unset | **только для тестов**. В обычной работе backup обязателен |

## Runbooks (читай при первой встрече со сценарием)

- `01-first-time.md` — полная первичная настройка чистого роутера
- `02-add-domain.md` — добавление домена в VPN-список
- `03-add-vpn.md` — добавление новой VPN-ноды
- `04-add-proxy.md` — пробрасывание mixed-inbound proxy на LAN
- `05-restore.md` — откат изменений
- `06-adopt-existing.md` — адоптировать ранее настроенный роутер
- `07-add-ip.md` — завернуть IP/CIDR в VPN (proxy_subnets nft-set)
- `08-pin-device.md` — pin LAN-устройства на конкретный outbound
- `09-country-pools.md` — страны как единица маршрутизации (usa-pool, pl-pool, sg-pool)
- `10-set-rule-set-outbound.md` — переключение существующего rule-set с FakeIP reset
- `11-lan-migration.md` — безопасная миграция LAN с router-local rollback
- `11-zapret2.md` — установка zapret2, дефолтная стратегия (tcpseg), подбор через blockcheck2
- `12-travel-router.md` — Travelmate, tablet onboarding, AWG2 site-to-site и reboot proof
- `99-escape-hatch.md` — когда и как использовать `raw-ssh.sh`

## Country-pool routing

Страна — основная единица маршрутизации. Ноды одной страны объединяются в urltest-пул, `auto-failover` работает над пулами.

```
memory/<alias>/countries.yaml   # реестр: country → pool → nodes
lib/country-resolve.sh          # resolve_country_to_pool home usa → usa-pool
```

**Текущие пулы (home):**

| Страна | Pool tag | Ноды |
|--------|----------|------|
| usa | usa-pool | usa-4, usa-6-dev, usa-4-crip |
| pl | pl-pool | polsha |
| sg | sg-pool | redshield-sg |

**Алиасы:** `us` → usa, `poland` → pl, `polsha` → pl, `singapore` → sg.

**Использование:**
```bash
bin/add-domain.sh --router home --domain example.com --outbound usa
bin/pin-device.sh --router home --source-ip 192.168.99.x --outbound usa
bin/add-proxy.sh  --router home --port 4010 --outbound usa
bin/add-vpn.sh    --router home --url "vless://..." --country usa
```

`--outbound usa-4` (конкретная нода) по-прежнему работает — backward-compat.

Подробнее: `runbooks/09-country-pools.md`.

## References (для архитектурного контекста)

- `PROPOSAL.md` — оригинальный дизайн (heritage, не следуй буквально — этот SKILL.md приоритетнее)
- `lib/staged-apply.sh` — паттерн safe-restart с auto-rollback
- `lib/vpn-kit-common.sh` — общие хелперы + secret patterns
- `schemas/install-state.schema.json` — структура per-router state (если решим вернуть JSON state позже)
