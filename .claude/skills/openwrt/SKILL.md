---
name: openwrt
description: Безопасная настройка и обслуживание OpenWRT-роутера (sing-box VLESS Reality + zapret + watchdog) через узкий набор предопределённых скриптов. Триггеры: "настрой роутер", "добавь домен", "добавь VPN", "openwrt", упоминание sing-box/VLESS, имя роутера из memory/routers.yaml.
---

# openwrt — инструкции для Claude

Этот навык управляет OpenWRT-роутером **только** через скрипты из `bin/`. Сырой SSH запрещён (escape hatch требует явного подтверждения пользователя).

## Когда срабатывает

- Пользователь упоминает имя роутера из `memory/routers.yaml`
- "Настрой роутер", "первичная настройка openwrt", "добавь домен в VPN", "добавь новый VPN", "пробрось proxy", "сделай backup", "откати"
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
bin/                   # ← safe API. Каждый скрипт — атомарная операция
  doctor.sh            # probe состояния роутера (drives state.md)
  setup-ssh.sh         # gen ed25519 + install + ~/.ssh/config alias
  setup-watchdog.sh    # /etc/router-watchdog.conf + cron
  install-vpn.sh       # парсит vless://, поднимает sing-box на чистом роутере
  adopt.sh             # уже настроенный роутер → snapshot + probe + рендер memory (read-only)
  add-domain.sh        # → rules/vpn-domains.json, validate, hot reload
  remove-domain.sh
  add-vpn.sh           # outbound + auto-failover + zapret vpn_servers set
  remove-vpn.sh
  add-proxy.sh         # mixed-inbound :400X + route rule
  remove-proxy.sh
  add-ip.sh            # STUB (V1.1) — выдаёт инструкцию по escape hatch
  pin-device.sh        # STUB (V1.1) — выдаёт инструкцию по escape hatch
  backup-now.sh        # snapshot of /etc/sing-box, init.d/*, /etc/config, watchdogs
  snapshot-list.sh
  restore.sh           # staged-apply из snapshot
  health.sh            # sing-box status, nft, DNS resolve, SOCKS exit IP
  logs.sh              # tail sing-box / watchdog / zapret
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
- `add-domain` ТОЛЬКО с `--outbound auto-failover` (per-tag pinning отложен в V1.1).
- LAN proxy на mixed-inbound портах 4000-4099.
- Telegram-watchdog, snapshot/restore, raw-ssh escape hatch.

**НЕ поддержано в V1** — если пользователь просит, агент должен прямо отказаться и сослаться на эту секцию:
- AmneziaWG / WireGuard outbounds (`awg://`, `.conf`-файлы) — нет рендеринга в sing-box config.
- vmess/trojan/shadowsocks — парсер только под `vless://`.
- `add-ip.sh` и `pin-device.sh` — stubs, выдают инструкцию по escape hatch.
- Multi-router fleet операции (всё всегда per-`--router`).
- Реконсиляция `domains.md`/`vpns.md`/`proxies.md` после `restore` или после `raw-ssh` — память остаётся «stale-with-warning».
- Geo-листы доменов (RU/CN/etc) — `add-domain` принимает только одиночные домены.

## Heritage скрипты (НЕ вызывать напрямую)

Файлы в `bin/`, которые остались от прототипа `openwrt-vpn-kit` и ОБЯЗАНЫ вызываться только из других скриптов (агент к ним не обращается):

- `install-minimal.sh`, `install-safety.sh`, `render-minimal-config.sh` — внутренности `install-vpn.sh`.
- `preflight-minimal.sh`, `detect-system.sh`, `detect-lan.sh`, `check-conflicts.sh` — pre-flight чеки.
- `adopt-safety-state.sh`, `session-sync.sh` — sync-машинерия (унаследовано).
- `_doctor_remote.sh` — runs ON router, вызывается только `doctor.sh`.

Если непонятно, что вызывать — посмотри в этот файл (`SKILL.md`) и `README.md`. Эти два — source of truth для safe API.

## Поток "добавить домен"

```
bin/add-domain.sh --router <alias> --domain <domain> [--outbound auto-failover]
```
В V1 `--outbound` принимает **только** `auto-failover`. Любой другой tag → exit 13 с понятным сообщением (full pinning — в V1.1).

Что скрипт делает (агенту знать только это):
1. Pre-backup → snapshot ID запоминается.
2. Читает `/etc/sing-box/rules/vpn-domains.json`, мерджит, валидирует.
3. Атомарная запись на роутере → `sing-box rule-set format` → `sing-box check`.
4. Rule-set перечитывается горячо (без restart).
5. `memory/<alias>/domains.md` и `journal.md` обновлены.

Если exit ≠ 0 — snapshot уже восстановлен. Прочитай stderr и сообщи пользователю.

## Поток "добавить VPN"

```
bin/add-vpn.sh --router <alias> --url "vless://..." [--tag <name>] [--add-proxy-port 4001]
```
Скрипт:
1. Парсит URL → outbound JSON, валидирует.
2. Snapshot.
3. Добавляет outbound, обновляет `auto-failover.outbounds`, добавляет server-IP в `vpn_servers` nft set (`zapret-custom`).
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
- `99-escape-hatch.md` — когда и как использовать `raw-ssh.sh`

## References (для архитектурного контекста)

- `PROPOSAL.md` — оригинальный дизайн (heritage, не следуй буквально — этот SKILL.md приоритетнее)
- `lib/staged-apply.sh` — паттерн safe-restart с auto-rollback
- `lib/vpn-kit-common.sh` — общие хелперы + secret patterns
- `schemas/install-state.schema.json` — структура per-router state (если решим вернуть JSON state позже)
