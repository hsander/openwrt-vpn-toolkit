---
title: OpenWrt VPN Kit — LLM-driven setup skill для домашних роутеров
status: draft / proposal
created: 2026-04-21
updated: 2026-04-21 (revision 6: commit=state-write atomic, success/rolled-back snapshot split, revision-based sync)
author: project contributors
future_location: отдельный git-репозиторий (пока лежит в ssh-claude/openwrt-vpn-kit/)
---

# OpenWrt VPN Kit

Распространяемый skill-пакет для быстрой настройки OpenWrt-роутера: **VPN-маршрутизация (sing-box tproxy) + DPI-обход (zapret) + LAN HTTP/SOCKS5 прокси + watchdog'и с алертами в Telegram + Wi-Fi 6**. Запускается через Claude Code — LLM читает skill, задаёт вопросы пользователю, ходит на роутер по SSH и настраивает всё сам с автооткатом при потере связи.

## 1. Мотивация

- Сейчас у нас работающий стек на home-router: `sing-box-tproxy` + `zapret` + `dns-watchdog.sh` + `vpn-nodes-watchdog.sh` + LAN-прокси :4000-:4004 + Telegram-алерты. Собирали его вручную несколько недель.
- Хочется **раздавать друзьям**: "запусти эту штуку в Claude Code, ответь на пару вопросов — получишь готовый роутер".
- Пакет должен быть **переиспользуемым** (без личных данных в репо), **гибким по железу** (256 MB – 1 GB+), **безопасно откатываемым при потере связи**, **детерминированным** (pin versions) и **понятным на русском**.

## 2. Ключевые решения

| # | Решение | Комментарий |
|---|---|---|
| 1 | **Стартуем в `ssh-claude/openwrt-vpn-kit/`**, позже переносим в отдельный git-репо | Сейчас черновик в монорепо |
| 2 | **Три RAM-профиля:** `minimal` / `standard` / `advanced` | Для максимальной гибкости по железу |
| 3 | **VPN-протокол v1:** только VLESS XTLS-Reality | Другие (AmneziaWG, WireGuard, Shadowsocks) — позже |
| 4 | **Zapret предлагается всегда**, но опционален | Кто-то пустит YouTube через VPN и zapret не нужен |
| 5 | **Zapret pinned to release tag + checksum** | НЕ `git clone master`. Фиксированный tag (`v72.12`) + SHA-256 проверка, fallback-зеркало |
| 6 | **Язык мастера и документации:** русский | Целевая аудитория — русскоязычные друзья |
| 7 | **Запуск через Claude Code** (LLM исполняет skill) | Юзер вставляет промпт, выдаёт SSH-доступ, отвечает на вопросы |
| 8 | **Telegram setup — текстовая инструкция** в доке | Как создать бота через @BotFather, как узнать `chat_id` |
| 9 | **Staged apply + rollback timer** для всех сетевых изменений | Удалённое изменение firewall/DNS/tproxy без потери доступа — обязательно |
| 10 | **Secrets никогда не попадают в репо/примеры/логи/бэкапы skill'а** | Явный контракт, LLM обязан соблюдать |
| 11 | **Machine-readable state:** `answers.yaml` + `install-state.json` | Детерминизм повторного запуска, rerun с другим профилем, корректный uninstall |
| 12 | **Verification — локальные сигналы + controlled endpoint** | Не дёргаем chatgpt/youtube/ifconfig.me для acceptance |
| 13 | **HTTP/SOCKS5 LAN-прокси (mixed inbound)** | По одному порту на каждую VPN-ноду, как у нас :4000-:4004 |
| 14 | **Динамическое добавление — домен / IP / CIDR / LAN-клиент** | Через команды skill'а после установки, без полного reinstall |
| 15 | **Wi-Fi 6 на первой настройке** | OpenWrt по-умолчанию Wi-Fi disabled — skill предлагает поднять 802.11ax |
| 16 | **Rollback timer primitive:** dedicated procd-daemon (`vpn-kit-rollback`), НЕ `at`/`cron` | Гарантия суб-минутного срабатывания на любом OpenWrt 24.10+. Hard gate в preflight на доступность procd + start-stop-daemon |
| 17 | **Dynamic add persistence contract:** runtime nft/config + persistent file + install-state.json | Без этого добавленное теряется при reboot/firewall reload. Каждое изменение — атомарно в трёх местах |
| 18 | **LAN-адрес и zones вычисляются из UCI**, не захардкожены | Listen-IP прокси, allowed-CIDR firewall, target wifi-bridge — всё из `uci show network` и `uci show firewall` в preflight |
| 19 | **install-state.json — authoritative копия на РОУТЕРЕ** (`/etc/vpn-kit/install-state.json`) | Локальный workspace — cache. Uninstall/diff работают от router-копии, чтобы skill был воспроизводим с любой машины |
| 20 | **Wi-Fi merge strategy, не full regenerate** | v1: патчим только `radio.disabled/country/htmode` + appendим новый wifi-iface. Если уже есть активный iface и не указан `wifi.merge_strategy: overwrite` — skill отказывается трогать wireless |
| 21 | **Операционная память скилла:** `events.jsonl` + `router-notes.md` + `learned-quirks.yaml` | install-state = что сейчас стоит. Отдельно нужен журнал (что происходило), narrative-заметки (что LLM понял про этот роутер) и структурированные "выученные причуды" (ISP/hardware/node behaviors) |

## 3. Архитектура: LLM-driven skill

Ключевое отличие от "шелл-визарда": **setup исполняет LLM в Claude Code**, а не bash-скрипт на роутере.

- **Шаблоны и скрипты** — на роутере, идемпотентные building blocks
- **Runbook'и** — инструкции *для LLM* на естественном языке
- **Мастер-диалог** — LLM ведёт беседу, собирает ответы в `answers.yaml` (валидирует по `answers.schema.yaml`), рендерит шаблоны, ставит на роутер **через staged apply**, записывает `install-state.json`
- **Повторные запуски** читают `install-state.json` → знают что уже стоит → делают diff, а не reinstall

### Поток работы

```
┌─ Юзер в Claude Code ──────────────────────────────────────────────┐
│  1. git clone openwrt-vpn-kit ~/router-setup                       │
│  2. Добавляет SSH-ключ на роутер (инструкция в docs)               │
│  3. Пишет: "Настрой мой роутер, SSH root@192.168.1.1"              │
└────────────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─ Claude Code (LLM) ────────────────────────────────────────────────┐
│  • Читает SKILL.md + runbook'и                                      │
│  • Preflight: SSH OK, OpenWrt version (hard gate), arch, RAM       │
│  • Читает install-state.json если есть → режим diff/update          │
│  • Диалог → answers.yaml (валидация по schema)                      │
│  • Показывает план + ссылки на docs → явный confirm                │
│  • Staged apply:                                                    │
│      → снимок (backup всех затрагиваемых файлов)                    │
│      → применить изменение                                          │
│      → reachability check (SSH ping, DNS probe)                     │
│      → если OK: запланировать commit через N секунд                │
│      → если FAIL после timeout: автооткат из снимка                │
│      → финальный commit (удалить rollback timer)                    │
│  • Пишет install-state.json (что, версии, контрольные суммы)        │
│  • Шлёт тестовое сообщение в TG: "🟢 setup OK"                     │
│  • Секреты записаны ТОЛЬКО в /etc/vpn-kit/secrets.conf (chmod 600) │
│    на роутере. НЕТ копий в ~/router-setup                          │
└────────────────────────────────────────────────────────────────────┘
```

## 4. Структура папки

```
openwrt-vpn-kit/
├── README.md                        — для юзера: что это, как начать
├── SKILL.md                         — для LLM: как исполнять skill
├── PROPOSAL.md                      — этот файл (удалить после реализации)
│
├── schemas/                         — machine-readable контракты
│   ├── answers.schema.yaml          — JSON-Schema для answers.yaml (валидация ввода)
│   ├── install-state.schema.json    — формат install-state.json (что установлено, версии, SHA)
│   ├── event.schema.json            — формат одной записи events.jsonl
│   └── learned-quirks.schema.yaml   — формат learned-quirks.yaml
│
├── docs/                            — читает ЮЗЕР
│   ├── prerequisites.md             — SSH-ключ, минимальные требования
│   ├── telegram-setup.md            — как создать бота, узнать chat_id
│   ├── vpn-sources.md               — где взять VLESS URL
│   ├── profiles.md                  — что в каждом RAM-профиле
│   ├── wifi-setup.md                — как skill поднимет Wi-Fi 6 + выбор канала/страны
│   ├── lan-proxy.md                 — как использовать HTTP/SOCKS5 :4000-:400N
│   ├── dynamic-add.md               — как добавить домен/IP/LAN-клиент после установки
│   ├── security.md                  — контракт по секретам, где что хранится
│   └── troubleshooting.md           — типовые проблемы
│
├── runbooks/                        — инструкции ДЛЯ LLM
│   ├── 00-overview.md               — общая логика + session-start mandatory read (notes + journal + quirks)
│   ├── 01-preflight.md              — SSH, версия (hard gate), arch, RAM, детект install-state, manual_intervention_detected
│   ├── 02-collect-answers.md        — диалог, валидация по answers.schema.yaml, user_decision в journal
│   ├── 03-plan-preview.md           — показать план, дождаться confirm
│   ├── 04-install-minimal.md
│   ├── 05-install-standard.md
│   ├── 06-install-advanced.md
│   ├── 07-verify.md                 — локальные сигналы + controlled endpoint
│   ├── 08-post-install.md           — финальный рассказ юзеру
│   ├── 10-dynamic-add.md            — как LLM обрабатывает "добавь домен/IP/LAN-клиент"
│   ├── 11-wifi-setup.md             — конфигурация Wi-Fi 6 (SSID, пароль, страна, канал)
│   ├── 98-session-close.md          — обязательный checklist: все изменения в journal? notes/quirks обновлены? sync push?
│   └── 99-uninstall.md              — откат всего из install-state.json
│
├── lib/                             — shared скрипты staged apply / rollback
│   ├── staged-apply.sh              — snapshot → apply → reachability → commit/rollback
│   ├── reachability-check.sh        — SSH ping + DNS probe + VPN probe с таймаутами
│   ├── rollback-timer.sh            — откат через N секунд если не пришёл commit
│   ├── state-read.sh                — парсинг install-state.json
│   ├── state-write.sh               — атомарная запись install-state.json
│   ├── secrets-write.sh             — запись /etc/vpn-kit/secrets.conf (chmod 600)
│   ├── integrity-check.sh           — SHA-256 проверка скачанного zapret
│   ├── snapshot-gc.sh               — retention: delete-on-success + keep-last-N + age + watermark
│   ├── journal-append.sh            — append-only запись events.jsonl + ротация
│   ├── journal-query.sh             — поиск по events.jsonl (last N, by type, by step)
│   ├── notes-read.sh / notes-write.sh — работа с router-notes.md (markdown merge)
│   └── quirks-update.sh             — структурные обновления learned-quirks.yaml
│
├── templates/
│   ├── sing-box/
│   │   ├── config-minimal.json.tmpl     — 1 outbound, минимум правил
│   │   ├── config-standard.json.tmpl    — auto-failover, remote rule_sets
│   │   ├── config-advanced.json.tmpl    — + pin-routes + LAN full-VPN
│   │   ├── mixed-inbound.json.tmpl      — HTTP/SOCKS5 LAN прокси (:4000-:400N)
│   │   └── init.d-sing-box-tproxy
│   ├── zapret/
│   │   ├── zapret-custom.init.tmpl
│   │   ├── hosts-default.txt
│   │   ├── install-zapret.sh            — качает ПО PINNED tag + SHA-256
│   │   ├── zapret.versions.yaml         — pinned tag/commit/sha256 + mirrors
│   │   └── zapret-strategies.md         — как подобрать стратегию под провайдера
│   ├── dns-chain/
│   │   ├── dnsmasq-additions.conf
│   │   ├── https-dns-proxy.uci.tmpl
│   │   └── nft-dns-redirect.rules
│   ├── watchdogs/
│   │   ├── dns-watchdog.sh.tmpl
│   │   ├── vpn-nodes-watchdog.sh.tmpl
│   │   ├── tg-send.sh                   — direct + VPN fallback
│   │   └── cron.tmpl
│   ├── wifi/
│   │   └── wireless.uci.tmpl            — 802.11ax, страна, SSID, WPA2/3
│   └── firewall/
│       ├── uci-additions.tmpl
│       └── nft-proxy-subnets.rules
│
├── profiles/                        — готовые RAM-пресеты
│   ├── minimal.yaml
│   ├── standard.yaml
│   └── advanced.yaml
│
├── scripts/                         — идемпотентные building blocks
│   ├── detect-system.sh             — JSON: {arch, openwrt_version, ram_mb, pkg_mgr, wifi_radios}
│   ├── check-conflicts.sh           — podkop, старый zapret, mwan3
│   ├── backup-configs.sh            — снапшот перед staged apply
│   ├── rollback.sh                  — восстановление из снапшота
│   └── add-resource.sh              — dynamic add: домен/IP/CIDR/LAN-клиент
│
└── examples/
    └── sample-answers.yaml          — БЕЗ секретов: токен/UUID/chat_id → <REDACTED>
```

## 5. Три RAM-профиля

### `minimal` (128-256 MB)
**Включено:**
- sing-box (конфиг без remote rule_sets, fakeip cache ≤64 MB, минимум доменных правил)
- zapret (hostlist mode)
- https-dns-proxy × **1** (только Cloudflare DoH)
- dns-watchdog.sh, vpn-nodes-watchdog.sh (shell, ~2 MB RSS во время cron-tick)
- Одна VPN-нода (без auto-failover)
- **HTTP/SOCKS5 LAN-прокси: 1 порт (:4000)** — тот же единственный VPN-outbound
- Wi-Fi 6 (если радио в железе поддерживает; включается в preflight)

**Оценка RAM:** ~50-70 MB поверх системы.

**Не включено:** remote rule_sets, второй DoH, auto-failover pool, LAN full-VPN, routerctl, двусторонний бот.

### `standard` (512 MB – 1 GB)
**Добавлено к minimal:**
- Remote rule_sets itdoginfo (auto-update 1d)
- https-dns-proxy × **2** (Cloudflare + Google)
- Auto-failover pool до 5 VPN-нод
- Pin-routes (обход багов конкретных нод)
- **HTTP/SOCKS5 LAN-прокси: по порту на каждую ноду (:4000-:400N)**
- Больший fakeip cache

**Оценка RAM:** ~120-180 MB поверх системы.

### `advanced` (1 GB+)
**Добавлено к standard:**
- `routerctl` CLI на роутере
- Двусторонний Telegram-бот (/status, /vpn add, /restart) — см. `router-management-automation.md`
- LAN full-VPN клиенты (tproxy для конкретных LAN-IP)
- `nft-tables-watchdog`
- Расширенный dynamic-add через бота (без SSH)

**Оценка RAM:** ~200-300 MB поверх системы.

## 6. Safety contract — staged apply + rollback timer

**Проблема.** Skill удалённо меняет firewall/DNS/tproxy/zapret по SSH, включая опциональный SSH-over-WAN. Один неудачный шаг = потеря доступа к роутеру.

**Решение: staged apply для каждого сетевого изменения.**

### Rollback timer primitive — фиксированный механизм

**НЕ используем `at`** (не гарантирован в OpenWrt 24.10 базовой поставке). **НЕ используем `cron`** (минутная гранулярность — неприемлемо).

**Используем dedicated procd-daemon `vpn-kit-rollback`.** Это наш собственный init-скрипт, который устанавливается на Этапе 0 вместе с safety-каркасом.

```
/etc/init.d/vpn-kit-rollback      — procd service
/usr/sbin/vpn-kit-rollback         — watcher-loop (sh)
/etc/vpn-kit/rollback.d/           — директория с pending timers
```

**Flow одного timer'а:**
1. LLM перед apply: пишет `/etc/vpn-kit/rollback.d/<step>.timer` с полями `{deadline_unix, snapshot_path, on_rollback_script}`
2. `/etc/init.d/vpn-kit-rollback reload` — daemon перечитывает директорию
3. Daemon крутит `while true; do check_timers; sleep 5; done` — шаг 5 секунд, чего более чем достаточно для 30/90с окон
4. Для каждого file: `if now >= deadline && !commit_marker: execute on_rollback_script; remove timer file`
5. На commit: LLM пишет `/etc/vpn-kit/rollback.d/<step>.commit` → daemon на следующем тике удаляет оба файла

**Почему procd:**
- ✅ procd есть на **каждом** OpenWrt (часть системы, не пакет)
- ✅ Переживает SSH-дисконнект
- ✅ Переживает reboot (при желании — `enable` init-скрипт, восстанавливает pending timers из `/etc/vpn-kit/rollback.d/`)
- ✅ Субминутная точность (tick 5s)
- ✅ `start-stop-daemon` (busybox builtin на OpenWrt) для корректного управления PID

### Hard gate в preflight
```
if not procd_available:  fail "procd не найден — это не стандартный OpenWrt"
if not start-stop-daemon_available:  fail "busybox без start-stop-daemon — нестандартная сборка"
if wc -c /etc/init.d/ > 2048:  warn "много сторонних init-скриптов, возможны конфликты"
```
Установка `vpn-kit-rollback` daemon — **первое действие Этапа 0**, до любых сетевых изменений. Если его установка сама провалилась — staged apply невозможен, setup останавливается.

### Протокол (реализован в `lib/staged-apply.sh`)

**Ключевой инвариант:** *"commit" означает "state-write прошёл успешно"*. Отдельного `.commit` файла-маркера больше нет — daemon проверяет не touch-файл, а само `install-state.json`. Это исключает окно "сеть в новом состоянии, state в старом".

```
0. Убедиться что vpn-kit-rollback daemon running

1. SNAPSHOT
   - Бэкап всех файлов, которые будет трогать этот шаг
   - Снимок nft/init.d/procd/UCI
   - **ДОПОЛНИТЕЛЬНО: копия текущего install-state.json → snapshot/state-before.json**
     (без этого rollback не сможет вернуть state к pre-apply revision)
   - snapshot/meta.json: {step_id, timestamp, files: [...], state_revision_before: N}
   - Путь: /etc/vpn-kit/snapshots/<step_id>-<timestamp>/

2. ARM ROLLBACK TIMER
   - Пишем /etc/vpn-kit/rollback.d/<step_id>.timer с полями:
     {step_id, deadline_unix, snapshot_path, state_revision_before}
   - vpn-kit-rollback daemon подхватит на следующем тике

3. APPLY
   - Применить изменение (render template → write file → restart service)

4. REACHABILITY CHECK
   - SSH-ping с нашей стороны (новая сессия)
   - На роутере: nslookup google.com 127.0.0.1, TCP-probe к controlled endpoint
   - При failure → НЕ идём в шаг 5 → timer сработает, снапшот восстановит и файлы, и state

5. COMMIT (= атомарный state-write)
   - state-write.sh --expected-revision N < new-state.json
     где new-state включает step_id в массиве "committed_steps"
   - Если CAS вернул 0 → commit состоялся (state на диске уже при revision N+1
     с записью о шаге) — следующий тик daemon увидит step_id в committed_steps
     и удалит timer
   - Если CAS вернул 11/12 → retry с новой N (см. §9.3)
   - Если после 3 retry всё ещё fail → явно запускаем rollback СРАЗУ (не ждём timer)
     → восстанавливаем файлы И state из snapshot
```

### Что делает daemon на tick'е (обновлённо)

```
для каждого файла /etc/vpn-kit/rollback.d/<step>.timer:
  current_state = read install-state.json
  if step.step_id in current_state.committed_steps:
      → committed → удалить timer
      → (опц) запустить snapshot-gc для delete-on-success
  elif now >= timer.deadline:
      → rollback:
          - restore файлы из snapshot_path
          - restore install-state.json из snapshot/state-before.json через CAS
            (если CAS fail — alert + stop, ручное вмешательство)
          - journal-append "staged_apply_rolled_back"
          - переместить snapshot в /etc/vpn-kit/snapshots/rolled-back/<...>
          - удалить timer
  else:
      → ждём следующего тика
```

**Почему так надёжно:** файл и state синхронизируются **одной** CAS-операцией. Между шагом 3 (сеть уже изменена) и шагом 5 (state записан) — только reachability check, а таймер уже взведён. Если state-write упадёт — daemon не увидит step_id в state, дождётся deadline, откатит ВСЁ (и файлы, и state). Рассинхрона не бывает.

### Таймауты
| Тип изменения | Timer | Reasoning |
|---|---|---|
| Firewall / nft / DNS-цепочка / SSH-over-WAN | 90s | даём juice на DHCP-renew / ARP, на spontaneous reconnect'ы |
| Конфиг-only без рестарта (добавить правило в sing-box через reload) | 30s | проверка reachability моментальна |
| Smoke-reload без изменения сетевого поведения (cron, watchdog script update) | 15s | просто убедиться что daemon жив |

### Хард-правила
- **Любой сетевой restart** (sing-box, zapret, firewall, dnsmasq) проходит через staged apply
- **Конфиг-only изменения** (добавить домен в rule без рестарта) — без timer, но со snapshot
- **SSH-over-WAN открывается ПОСЛЕДНИМ шагом** после базовой сети
- **Reboot никогда не делается автоматически** — только явный confirm юзера
- При 2 подряд неудачных staged apply — skill **останавливается** и шлёт детальный alert, не пытается дальше

### 6.1. Snapshot retention / cleanup policy

Snapshots теперь живут в persistent flash (`/etc/vpn-kit/snapshots/`). Без активной политики они съедят место — а на роутере с `flash ≥ 30 MB` свободного это быстро ударит по journal/state/secrets.

**Snapshots делятся на два типа, с РАЗНЫМИ политиками** (это устраняет противоречие delete-on-success ↔ keep-last-N):

### Тип A — success-snapshots (`/etc/vpn-kit/snapshots/<step_id>-<ts>/`)
Успешно commit'нутые шаги. Нужны только до момента commit — дальше они бесполезны (для истории есть journal).

| Правило | Действие |
|---|---|
| **delete-on-success** | Когда daemon видит `step_id` в `install-state.json.committed_steps` → snapshot удаляется **немедленно** на следующем тике |
| **watermark** (safety net) | Если что-то пошло не так и success-snapshots накопились (>10 MB total) — oldest удаляются до <8 MB |
| **emergency prune** | При `<5 MB` свободно в `/etc` — удалить ВСЕ success-snapshots, `emergency_prune` event, TG alert |

### Тип B — rolled-back snapshots (`/etc/vpn-kit/snapshots/rolled-back/<step_id>-<ts>/`)
Снапшоты, **которые реально использовались** для отката (сеть ломалась, timer сработал). Это единственные случаи, когда нужен post-mortem.

| Правило | Действие |
|---|---|
| **keep-last-N** | Хранятся последние **5** rolled-back snapshots для forensics |
| **age prune** | Старше **30 дней** удаляются (кроме keep-last-5) |
| **emergency prune** | При `<5 MB` свободно — удалить всё кроме самого последнего rolled-back, `emergency_prune` event |

### Порядок приоритетов (внутри одной операции GC)
1. **Never delete:** любой snapshot с active rollback timer (pending, ещё не committed и не rolled-back)
2. **Never delete:** последние 5 rolled-back (forensics)
3. **Delete eagerly:** success-snapshots после commit
4. **Delete lazily:** rolled-back по age/watermark

### События в journal
- `snapshot_cleaned` — `{type: "success", reason: "commit_confirmed|watermark|emergency", step_id, bytes_freed}`
- `snapshot_rolled_back` — `{type: "rolled_back", step_id, preserved_at: "rolled-back/..."}`
- `emergency_prune` — отдельный TG alert (без pii)

### Rollback safety
- Snapshot **не удаляется** пока timer не зафиксировал результат (committed или rolled-back)
- Успешный commit → snapshot удаляется сразу (smaller flash footprint)
- Rollback → snapshot переезжает в `rolled-back/` и живёт по правилам Типа B

**Tunable через answers.yaml:**
```yaml
snapshot_policy:
  keep_last_n: 5
  max_age_days: 7
  total_size_high_watermark_mb: 10
  total_size_low_watermark_mb: 8
  emergency_free_threshold_mb: 5
```
Дефолты подобраны под minimal профиль (256 MB RAM, ~30 MB flash). На advanced можно расслабить.

### Reachability check — что проверяем (локально, не через интернет-сайты)
| Сигнал | Источник | Критерий успеха |
|---|---|---|
| SSH доступ | новая сессия с клиентской машины | exit code 0 |
| DNS локальный | `nslookup google.com 127.0.0.1` | IP получен |
| DNS через sing-box | `nslookup chatgpt.com 127.0.0.42` | FakeIP из 198.18/15 |
| nft таблицы | `nft list tables` | все 3 (fw4, sing_box_tproxy, [zapret_custom]) |
| Сервисы | `/etc/init.d/<x> status` + `pgrep` | running |
| VPN outbound | TCP-probe :443 на известный VLESS-сервер | OK |
| **Controlled endpoint** | наш собственный `https://probe.openwrt-vpn-kit.dev/ok` *(если разместим)* или IP-адрес 1.1.1.1:443 TCP-probe | 200 / TCP OK |

**НЕТ в verification:** chatgpt.com, youtube.com, ifconfig.me — они дают false positives из-за антибота, региональных блокировок, CDN.

## 7. Secrets contract

Явные правила для LLM (зашиты в `SKILL.md` и `docs/security.md`):

### ЧТО считается секретом
- VLESS URL (содержит UUID + private)
- Полный VLESS JSON (uuid, public_key, short_id)
- Telegram bot token
- Telegram chat_id (квази-секрет, но трактуем строго)
- Любые пароли (Wi-Fi, SSH)

### ГДЕ секреты ЖИТЬ МОГУТ
- На роутере: `/etc/vpn-kit/secrets.conf` (chmod 600, owner root)
- На роутере: `/etc/sing-box/config.json` (chmod 600) — UUID/keys неизбежны
- В приватной сессии Claude Code (память модели в рамках разговора)
- В `answers.yaml` на клиентской машине ТОЛЬКО если юзер явно подтвердил (chmod 600, путь вне git)

### ГДЕ секреты ЖИТЬ НЕ МОГУТ
- В `openwrt-vpn-kit/` (репо) — никогда
- В `examples/sample-answers.yaml` — там `<REDACTED_*>` placeholder'ы
- В логах watchdog'ов (`/var/log/*.log`) — TG-токен маскируется
- В install-state.json — только хэши, не значения
- В `/etc/vpn-kit/snapshots/` после commit — чистим по retention policy (см. §6.1)
- В бэкапах, копируемых на клиентскую машину

### Правила LLM
- Перед записью файла в репо — проверить, нет ли там секретов по паттернам (regex на `vless://`, `bot[0-9]+:`, и т.п.)
- При diff/commit в git skill'а: если находим секрет — блокировать, требовать подтверждения
- В logs файлов LLM редактирует — маскировать автоматически (`TG_TOKEN=***`)
- Не echo'ить токен в tool output без нужды

## 8. Version matrix — hard gate в preflight

Противоречие в v1 (23.x+ в доке vs 25.x в risks) устранено:

### Официальная поддержка v1
- **OpenWrt 24.10+** (apk как менеджер, кастомный init.d совместим)
- Архитектуры: aarch64, armv7, x86_64, mips (zapret бинари для всех)
- Менеджер пакетов: apk (opkg для ≤23.x **не** поддерживается в v1)

### Hard gate в preflight
```
if openwrt_major_version < 24 then
    → LLM сообщает: "Поддерживается OpenWrt 24.10+. У тебя <X>. Рекомендую обновить ОС."
    → setup не продолжается
```

### Планируется позже
- v1.1 — поддержка 23.x (opkg branch шаблонов)
- v1.2 — поддержка экзотических arch (ramips, ath79 малой памяти)

### Файлы синхронизированы
- `docs/prerequisites.md` — пишет **"OpenWrt 24.10+"**
- `runbooks/01-preflight.md` — hard gate на major≥24
- `README.md` — матрица совместимости в начале

## 9. Machine-readable state

### `answers.yaml` (машинно-валидируемый ввод мастера)
```yaml
# пример в examples/sample-answers.yaml, БЕЗ реальных секретов
version: 1
profile: minimal          # minimal | standard | advanced
router:
  name: home-router
  host: 192.168.1.1
  ssh_user: root
system:
  openwrt_min_major: 24
vpn:
  nodes:
    - name: polsha
      vless_url: "<REDACTED_VLESS_URL>"
      pin_routes: []
  routing:
    domains: [chatgpt.com, openai.com, youtube.com]
    subnets: []
    lan_full_vpn_clients: []    # только advanced
telegram:
  bot_token: "<REDACTED_BOT_TOKEN>"
  chat_id: "<REDACTED_CHAT_ID>"
  channel_fallback: true          # direct + VPN fallback через VLESS
zapret:
  enabled: true
  hosts: [youtube.com, googlevideo.com, rutracker.org]
  zapret_version: "v72.12"        # pinned
wifi:
  enable: true
  country: UA
  ssid_24: "OpenWrt-2G"
  ssid_5: "OpenWrt-5G"
  password: "<REDACTED_WIFI_PASSWORD>"
  mode: "802.11ax"                # Wi-Fi 6
  channel_24: auto
  channel_5: auto
ssh_over_wan:
  enable: false
  port: 22
```

Схема: `schemas/answers.schema.yaml` — JSON-Schema draft-07, LLM обязан валидировать перед применением.

### `install-state.json` — authoritative copy на РОУТЕРЕ

**Единственный источник правды:** `/etc/vpn-kit/install-state.json` на роутере (chmod 644, root).

Локальная копия в `~/router-setup/.state/<router-name>.json` — только **cache**, чтобы LLM между сессиями помнил контекст. Перед любой операцией LLM **обязан** сверить cache с router-копией:
- Если router-копия новее → cache обновляется
- Если router-копия отсутствует, а cache есть → skill был реинсталлирован вручную/откатан, cache недействителен, требуется `reconcile` runbook
- Если обе отсутствуют, но компоненты скилла на роутере детектятся → режим `adopt`: LLM сканирует систему, реконструирует state, пишет на роутер

**Почему authority на роутере:**
- Workspace потерян/клонирован заново → uninstall всё равно работает с любой машины
- Юзер хочет починить/снести skill с другого ноута → забирает state по SSH
- LLM и юзер видят одно и то же состояние

### Полный пример (покрывает ВСЕ фичи + CAS-поля)
```json
{
  "_revision": 42,
  "_last_writer": "claude-code@session-abc123",
  "_last_writer_host": "macbook-alex",
  "_last_updated_at": "2026-04-21T18:30:00Z",

  "version": 1,
  "installed_at": "2026-04-21T14:00:00Z",
  "last_modified_at": "2026-04-21T18:30:00Z",
  "skill_version": "0.1.0",
  "profile": "standard",
  "router_identity": {"name": "home-router", "openwrt_version": "24.10.0", "arch": "aarch64"},

  "committed_steps": [
    {"step_id": "install-rollback-daemon", "committed_at": "2026-04-21T14:00:30Z", "revision_at_commit": 1},
    {"step_id": "install-sing-box-minimal", "committed_at": "2026-04-21T14:05:10Z", "revision_at_commit": 5},
    {"step_id": "install-zapret", "committed_at": "2026-04-21T14:07:45Z", "revision_at_commit": 9}
  ],

  "components": {
    "rollback_daemon": {"init": "/etc/init.d/vpn-kit-rollback", "binary": "/usr/sbin/vpn-kit-rollback", "sha256": "..."},
    "sing-box":        {"version": "1.x.y", "config_sha256": "...", "init": "/etc/init.d/sing-box-tproxy"},
    "zapret":          {"version": "v72.12", "tarball_sha256": "...", "binary_sha256": "...", "init": "/etc/init.d/zapret-custom", "source": "primary|mirror"},
    "https-dns-proxy": {"version": "2.x.y", "instances": 2},
    "watchdogs":       {"dns": true, "vpn": true, "nft_tables": false}
  },

  "files_owned_by_skill": [
    "/etc/vpn-kit/install-state.json",
    "/etc/vpn-kit/secrets.conf",
    "/etc/vpn-kit/persistent-sets.nft",
    "/etc/vpn-kit/snapshots/",
    "/etc/sing-box/config.json",
    "/etc/init.d/sing-box-tproxy",
    "/etc/init.d/zapret-custom",
    "/etc/init.d/vpn-kit-rollback",
    "/usr/bin/dns-watchdog.sh",
    "/usr/bin/vpn-nodes-watchdog.sh",
    "/usr/sbin/vpn-kit-rollback"
  ],

  "uci_changes": [
    {"config": "dhcp", "section": "@dnsmasq[0]", "option": "noresolv", "prev": null, "new": "1"},
    {"config": "network", "section": "wan", "option": "peerdns", "prev": "1", "new": "0"},
    {"config": "wireless", "section": "radio0", "option": "disabled", "prev": "1", "new": "0"},
    {"config": "wireless", "section": "radio0", "option": "country", "prev": null, "new": "UA"},
    {"config": "wireless", "section": "radio0", "option": "htmode", "prev": "HT40", "new": "HE80"},
    {"config": "firewall", "section": "@rule[N]", "created": true, "name": "Allow-LAN-proxy-4000-4004"}
  ],

  "wireless_additions": [
    {"section_name": "vpn_kit_ap_5g", "type": "wifi-iface", "ssid": "OpenWrt-5G", "created_by_skill": true}
  ],

  "proxy_ports": [
    {"port": 4000, "listen": "<computed_from_uci>", "outbound": "polsha", "type": "mixed"},
    {"port": 4001, "listen": "<computed_from_uci>", "outbound": "usa-4",  "type": "mixed"}
  ],

  "firewall_rules_added": [
    {"name": "Allow-LAN-proxy-4000-4004", "src_zone": "lan", "src_subnets": ["<computed>"], "dest_ports": "4000-4004"},
    {"name": "Allow-WAN-SSH", "enabled": false, "dest_port": 22, "optional": true}
  ],

  "cron_entries": [
    {"schedule": "* * * * *", "cmd": "/usr/bin/dns-watchdog.sh"},
    {"schedule": "* * * * *", "cmd": "sleep 30; /usr/bin/vpn-nodes-watchdog.sh"}
  ],

  "dynamic_additions": [
    {"id": "uuid-1", "type": "domain", "value": "instagram.com", "added_at": "2026-04-22T10:00:00Z", "origin": "claude-code", "config_ref": "sing-box.route.rules[7]", "persisted_in": "/etc/sing-box/config.json"},
    {"id": "uuid-2", "type": "subnet", "value": "203.0.113.0/24", "added_at": "2026-04-22T11:00:00Z", "origin": "tg-bot", "persisted_in": "/etc/vpn-kit/persistent-sets.nft", "nft_set": "proxy_subnets"},
    {"id": "uuid-3", "type": "lan_client", "value": "192.168.1.158", "added_at": "2026-04-22T12:00:00Z", "origin": "claude-code", "config_ref": "sing-box.route.rules[8]"}
  ],

  "zapret_hosts": {
    "source_file": "/opt/zapret/ipset/zapret-hosts.txt",
    "managed_entries": ["youtube.com", "googlevideo.com", "rutracker.org"],
    "user_added": []
  },

  "secrets_paths_only": {
    "telegram_config": "/etc/vpn-kit/secrets.conf",
    "sing_box_config": "/etc/sing-box/config.json"
  }
}
```

- **Rerun:** LLM читает router-копию → diff с `answers.yaml` → применяет изменения
- **Uninstall:** LLM читает `files_owned_by_skill`, `uci_changes`, `wireless_additions`, `firewall_rules_added`, `cron_entries`, `dynamic_additions` → откатывает ровно то, что ставил. Без state → skill переходит в `adopt`-режим или требует manual rollback
- **Profile change:** minimal→standard = diff компонентов
- **Schema** `schemas/install-state.schema.json` обязана покрывать **все** ключи выше. CI-проверка: lint всех возможных примеров

### 9.1. Операционная память скилла (события, заметки, выученные причуды)

`install-state.json` отвечает на вопрос **"что сейчас стоит"**. Нужны ещё три слоя:

| Слой | Формат | Отвечает на вопрос | Живёт где |
|---|---|---|---|
| **Журнал событий** | `events.jsonl` (append-only) | "что происходило, когда, с каким результатом" | `/etc/vpn-kit/journal/events.jsonl` (router authoritative) |
| **Narrative-заметки** | `router-notes.md` (markdown) | "что LLM понял про ЭТОТ конкретный роутер" | `/etc/vpn-kit/journal/router-notes.md` |
| **Выученные причуды** | `learned-quirks.yaml` (structured) | "специфика ISP/hardware/нод — чтобы при следующем шаге не наступать снова" | `/etc/vpn-kit/journal/learned-quirks.yaml` |

**Authority:** всё на роутере, cache в `~/router-setup/.state/<router>/`. Ровно как install-state.json.

### Журнал событий — `events.jsonl`

**Append-only JSONL**, одна строка — одно событие. Простой формат для grep/awk и для LLM.

Типы событий (по `schemas/event.schema.json`):
- `setup_started` / `setup_completed` / `setup_failed`
- `staged_apply_started` / `staged_apply_committed` / `staged_apply_rolled_back`
- `dynamic_add` / `dynamic_remove`
- `verify_run` (результат + fail'ы)
- `user_decision` (юзер выбрал X из опций Y, reason)
- `failure_observed` (watchdog поймал, TG alert отправлен)
- `manual_intervention_detected` (skill заметил что юзер вручную менял файл-owned-by-skill)
- `wifi_change` / `node_added` / `node_removed`
- `profile_upgrade` (minimal → standard)

Пример записи:
```json
{"ts":"2026-04-21T14:05:32Z","type":"staged_apply_rolled_back","step":"install-sing-box","reason":"reachability_check_failed","snapshot":"/etc/vpn-kit/snapshots/install-sing-box-20260421140500/","triggered_by":"timer","rollback_timer_elapsed_s":91}
{"ts":"2026-04-21T14:10:00Z","type":"user_decision","question":"wifi.merge_strategy","choice":"append_iface","reason":"radio0 уже активен, у юзера работает его SSID","asked_by":"llm"}
{"ts":"2026-04-22T09:15:00Z","type":"dynamic_add","kind":"domain","value":"instagram.com","origin":"claude-code","session":"<claude-session-id>"}
```

**Ротация:** файл режется при >2 MB (`journal-append.sh`) → `events.jsonl.1`, `.2`, ... (держим 5 файлов).

**Зачем нужен:** когда пользователь приходит через 2 месяца "у меня что-то сломалось" — LLM читает journal и видит что менялось. Без этого LLM слеп.

### Narrative-заметки — `router-notes.md`

Markdown, который **LLM пишет для LLM** (и для юзера, если захочет прочесть). Свободная форма, но с секциями.

Шаблон:
```markdown
# Router: home-router (установлен 2026-04-21)

## Identity
- OpenWrt 24.10.0 aarch64, MediaTek Filogic
- Profile: standard
- Skill version at install: 0.1.0

## ISP / Провайдер
- Detected: похоже на Kyivstar Home (по AS лукапу)
- DPI: режет youtube по SNI, strategy `fakedsplit+badsum` работает
- QUIC заблокирован провайдером (форсим TCP)
- Telegram API: TSPU-подобной блокировки нет

## VPN nodes — наблюдения
- polsha: stable, но режет idle TCP 50+с — не использовать для long-poll
- usa-6: рекомендован для TG API (pin-route выставлен 2026-04-21)
- dev-p2p: иногда флапает ночью в 03-05 UTC (провайдер VPS-хостера)

## Hardware quirks
- radio0 (5GHz) — MT7915, Wi-Fi 6 работает
- radio1 (2.4GHz) — тот же чип, но htmode `HT40` вместо `HE40` стабильнее

## История решений
- 2026-04-21: выбрали profile=standard (RAM 1GB, хватит)
- 2026-04-21: `wifi.merge_strategy=append_iface` — у юзера уже был свой SSID "HomeLife", не трогаем
- 2026-04-22: добавили instagram.com в VPN-routing (юзер написал "в инстаграм не заходит")

## TODO / parked
- Рассмотреть `advanced` профиль с routerctl после стабилизации текущего
- Юзер упоминал IoT-зону — возможно позже добавим listen_zones: [lan, iot]
```

**Обновляется:** после каждого значимого события LLM делает одно из:
- `notes-write.sh append "## <date>" "..."`  — добавить секцию
- `notes-write.sh update "ISP"` — обновить конкретную секцию (через anchor'ы)
- Читается в начале каждой новой сессии через `notes-read.sh` (LLM получает весь текст)

**Размер:** держим под 2000 слов. При превышении LLM делает компрессию (сохраняет суть, выкидывает мелочи).

### Выученные причуды — `learned-quirks.yaml`

Структурированные наблюдения, которые **влияют на поведение skill'а при следующих операциях**. В отличие от `router-notes.md` (свободная форма) это **machine-consumable**.

```yaml
_revision: 17
_last_writer: "claude-code@session-abc123"
_last_updated_at: "2026-04-21T18:30:00Z"

version: 1
isp:
  detected_name: "Kyivstar Home"
  detected_at: "2026-04-21T14:00:00Z"
  dpi_behavior:
    blocks_sni: [youtube.com, rutracker.org]
    ip_blocks: []
    tspu_like: false
  working_zapret_strategy: "fakedsplit+badsum"
  working_zapret_fooling: ["badsum"]
  telegram_api_reachable_direct: true

hardware:
  cpu_model: "MT7986"
  wifi_driver: "mt76"
  known_quirks:
    - id: "mt7915-2g-ax-unstable"
      affects: "radio1"
      workaround: "use htmode=HT40 instead of HE40"
      learned_at: "2026-04-21T15:30:00Z"

nodes:
  - name: polsha
    observed_issues: ["idle_tcp_kill_50s"]
    avoid_for: ["long_poll_apps"]
    last_check: "2026-04-21T14:00:00Z"
  - name: usa-6
    stability: "good"
    recommended_for: ["telegram_long_poll"]
    pin_routes: ["api.telegram.org"]

user_preferences:
  merge_strategy_wifi: "append_iface"
  confirm_every_step: true
  notification_verbosity: "state_changes_only"
```

**Зачем нужно:** при следующем запуске LLM **не спрашивает** юзера снова "какая у тебя стратегия zapret" — читает из quirks. Подбирает pin-routes автоматически на основе observed_issues. Предлагает рабочий набор параметров сразу.

### Синхронизация (router ↔ client cache)

Одинаковый механизм для всех 4 файлов (install-state + 3 memory-слоя), **только через revision/CAS, НЕ через timestamp**:

- **Sync pull** в начале сессии: SSH → rsync из `/etc/vpn-kit/journal/` + `/etc/vpn-kit/install-state.json` в `~/router-setup/.state/<router>/`. Cache хранит `_sync_base_revision` — revision'ы файлов на момент pull, чтобы потом использовать их как expected_revision для CAS
- **Sync push** — через merge-процедуру §9.3 (pull → 3-way merge → CAS write с `expected_revision = _sync_base_revision`). `events.jsonl` append-only, synchro другим протоколом (см. ниже)
- **Конфликт решается revision'ами, не timestamp'ами:**
  - `install-state.json`: если router revision > `_sync_base_revision` (cache устарел) → merge, новый CAS
  - `router-notes.md`: merge по секциям (markdown heading'ам) — новые с обеих сторон сливаются, CAS по revision frontmatter'а
  - `learned-quirks.yaml`: deep-merge по ключам, при конфликте того же ключа берётся **ветка с бОльшим `_revision`** (а не по timestamp — timestamp'ы могут быть сдвинуты между клиентами из-за clock drift)
  - `events.jsonl`: append-only, reconcile по hash'ам уже записанных строк — новые с обеих сторон дописываются, дубликаты детектятся и отбрасываются
- **Почему НЕ timestamp:** clock skew между роутером и клиентами может быть секунды-минуты (особенно если роутер только загрузился до NTP-sync'а), что приводит к мнимым "newer" записям. Revision — монотонный счётчик под CAS-защитой, конфликт determenirovan

### Claude Code session memory integration

На клиентской машине у юзера Claude Code держит свою память (`memory/` в workspace). Предлагаемая интеграция:

1. Skill создаёт в Claude Code workspace memory файл **`project_openwrt_vpn_kit_<router-name>.md`** с указателем:
   ```
   Router <name> managed by openwrt-vpn-kit.
   Pull latest state before any operation:
     sync_pull: ~/router-setup/.state/<router>/
   Authoritative journal: ssh root@<ip> cat /etc/vpn-kit/journal/events.jsonl | tail -100
   Notes: ssh root@<ip> cat /etc/vpn-kit/journal/router-notes.md
   Quirks: ssh root@<ip> cat /etc/vpn-kit/journal/learned-quirks.yaml
   ```
2. Claude Code memory **не содержит секретов и значений** — только указатели и протокол синка
3. При старте новой сессии LLM автоматически подтягивает указатель и делает sync pull

### Git-поведение

- `.state/` в workspace — **в `.gitignore`** (это cache, плюс риск утечки имён/IP)
- `events.jsonl` / `router-notes.md` / `learned-quirks.yaml` на роутере — **никогда не коммитим** в репо skill'а (содержат приватные данные)
- В репо skill'а только **схемы** и **примеры** (`examples/sample-router-notes.md` с placeholder'ами)

### Privacy / secrets в journal

- **НЕТ** TG-токена, VLESS-URL, пароля Wi-Fi, UUID'ов в journal/notes/quirks (ни в router-копии, ни тем более в client cache)
- Если operation касается секрета — в events.jsonl пишем `{"secret_ref": "tg_token", "masked_value": "***"}`, не сам токен
- `lib/journal-append.sh` имеет встроенный фильтр на regex (`vless://`, `bot[0-9]+:`, и т.п.) и отказывается писать если находит

### 9.2. Контракт "обновлять память при каждом изменении" — принудительный, не best-effort

**Проблема:** LLM может забыть записать событие / обновить notes / обновить quirks. Через месяц память неполная — journal врёт, решения повторяются, выученные причуды забываются.

**Решение: память обновляется как часть самой операции, а не отдельным опциональным шагом.**

### Правила (зашиты в SKILL.md и enforce'ятся runbook'ами)

**R1. Staged apply НЕ коммитится без journal-записи.**
- В `lib/staged-apply.sh` шаг 5 (COMMIT) включает: `journal-append.sh staged_apply_committed ...` **ДО** создания `.commit` marker'а
- Если journal-append вернул non-zero — commit marker не пишется → timer откатит изменение. Т.е. "не записал — не применил"
- Того же требует rollback: `staged_apply_rolled_back` пишется в journal как часть rollback-скрипта

**R2. Каждый dynamic-add обязан тронуть install-state.json + events.jsonl атомарно.**
- `scripts/add-resource.sh` — один скрипт, который делает все три persistence-шага (runtime/persistent/state) + journal-append. Если хоть один fail — весь add откатывается
- Нет пути "добавил nft element, но забыл journal" — скрипт один

**R3. Юзерские решения пишутся в journal немедленно.**
- Как только LLM получил ответ юзера на неоднозначный вопрос (`merge_strategy`, выбор профиля, confirm на overwrite) — сразу `journal-append.sh user_decision ...`, до начала действия
- В runbook'ах `02-collect-answers.md` и `03-plan-preview.md` этот шаг явно прописан

**R4. Выученные причуды обновляются при каждом значимом наблюдении.**
- Если LLM заметил: "strategy X fails, strategy Y works" — сразу `quirks-update.sh isp.working_zapret_strategy Y` в той же операции
- Если watchdog/verify поймал повторяющийся паттерн (нода-флап, тот же sing-box-config reload глюк) — LLM обязан обновить `learned-quirks.yaml`, а не только отчитаться юзеру

**R5. Session close checklist (обязательный, не опциональный).**
- В конце каждой сессии Claude Code LLM запускает `runbooks/98-session-close.md`:
  1. Есть ли non-empty diff в install-state.json (по сравнению с началом сессии)?
  2. Для каждого изменения — есть соответствующая запись в events.jsonl?
  3. Были ли новые observed quirks, которые не попали в `learned-quirks.yaml`?
  4. Нужно ли обновить `router-notes.md` (новые решения, новая история)?
  5. Sync push на роутер + sync обратно (проверить consistency)
- Если checklist fail'ится — LLM сообщает юзеру **до** завершения сессии и предлагает закрыть пробелы

**R6. Start-of-session mandatory read.**
- `runbooks/00-overview.md` первым делом: `notes-read.sh` + `events.jsonl | tail -50` + `learned-quirks.yaml`
- Без этого LLM НЕ ПРИСТУПАЕТ к диалогу с юзером. Это hard gate в runbook
- Причина: без знания истории рискуем повторить ошибку или задать вопрос, на который уже есть ответ в quirks

**R7. `lib/staged-apply.sh` имеет dry-run flag `--check-memory`.**
- Запускается без изменений, только проверяет: "если бы я сейчас апплайнул этот шаг, смог бы я записать событие?"
- Используется в Этапе 0 как integration test каркаса

**R8. Manual intervention detection.**
- `runbooks/01-preflight.md` после чтения install-state.json делает diff с реальным состоянием (`sha256sum` файлов-owned-by-skill)
- При расхождении пишет `manual_intervention_detected` event + обновляет `router-notes.md` ("⚠️ юзер менял `/etc/sing-box/config.json` вручную между сессиями") + спрашивает юзера "adopt или overwrite?"
- Это закрывает главный риск: без R8 память молча рассинхронизируется и обесценивается

### Failure modes и fallback

- **journal-append fail из-за full filesystem** → staged apply упадёт на commit → rollback. Юзер получит понятную ошибку "no space for journal, освободи место в /etc"
- **journal-append fail из-за битого JSON** → LLM обязан перепроверить свой синтаксис, не обходить ошибку. В логе skill warn-level
- **LLM забыл про R5 (session close)** → следующий session start обнаружит diff и сделает `manual_intervention_detected` retroactively. Не идеально (теряется мотивация решения), но не катастрофа
- **Cache (client) рассинхронизирован с router** → `sync pull` при start session перезаписывает cache. Authority всегда на роутере

### Memory retention / cleanup

- `events.jsonl` — ротация 5 файлов × 2 MB каждый (итого ~10 MB истории, обычно 6+ месяцев)
- `router-notes.md` — LLM делает компрессию при >2000 слов (конденсирует старые секции, хранит суть)
- `learned-quirks.yaml` — не растёт линейно, т.к. структурированный; периодически LLM удаляет устаревшие observations (например, если нода уже год как удалена)
- Компрессия заметок — **тоже событие в journal**: `{"type":"notes_compressed","before_words":2500,"after_words":1200,"summarized_sections":["История решений 2026-04"]}`

### 9.3. Контракт конкурентных записей (CAS + file locks)

**Проблема.** Сейчас writers state/notes/quirks могут быть несколько:
1. Claude Code сессия на ноуте 1
2. Claude Code сессия на ноуте 2 (параллельно)
3. Будущий Telegram-бот на home-server (`advanced` профиль) — сам меняет state/notes, когда юзер говорит `/vpn add ...`
4. Session sync push в конце сессии (может принести устаревшую локальную копию)

Без защиты: бот добавил ресурс в 14:00, обновил router-копию. Claude-сессия, начавшаяся в 13:50, читала state до бота, пишет свой state в 14:05 — **перетирает** изменение бота.

**Решение.** Двухслойная защита: **compare-and-swap по revision** на уровне файла + **flock** на уровне compound-операции.

### Формат revision в файлах

**`install-state.json`** — top-level поля:
```json
{
  "_revision": 42,
  "_last_writer": "claude-code@session-abc123",
  "_last_writer_host": "macbook-alex",
  "_last_updated_at": "2026-04-22T14:05:32Z",
  ...остальные поля...
}
```

**`router-notes.md`** — frontmatter:
```markdown
---
revision: 42
last_writer: "tg-bot@home-server"
last_updated_at: "2026-04-22T14:00:15Z"
---

# Router: home-router
...
```

**`learned-quirks.yaml`** — top-level:
```yaml
_revision: 42
_last_writer: "claude-code@session-abc123"
_last_updated_at: "2026-04-22T14:05:32Z"
version: 1
isp:
  ...
```

**`events.jsonl`** — append-only, CAS не нужен, **но** нужен `flock` на append (см. ниже). Каждая запись содержит `state_revision` на момент события — это позволяет корректно восстановить, какая версия state соответствовала какому событию.

### Write-API (single entry point, reject-on-stale)

Все writer'ы обязаны ходить через эти три скрипта (и только через них):

**`lib/state-write.sh`**
```
USAGE: state-write.sh --expected-revision N --writer "<id>" < new.json
EXIT:
  0  — записано успешно, новая revision N+1
  11 — STALE: current on-disk revision != N; caller должен re-read + merge + retry
  12 — LOCK: другой writer держит lock, повторить через backoff
  13 — VALIDATION: новый JSON не соответствует install-state.schema.json
```

**`lib/notes-write.sh`** — та же семантика, для markdown. Frontmatter обновляется автоматически. Поддерживает режимы `append-section`, `update-section`, `full-overwrite` — CAS на revision всегда обязателен.

**`lib/quirks-update.sh`** — тот же CAS + JSON-patch-like семантика (`set isp.working_zapret_strategy "fakedsplit+badsum"`).

### Внутри write-скрипта (атомарность)

```sh
# pseudo-code для state-write.sh
1. flock -x -w 5 /var/lock/vpn-kit-state.lock
      (если не захватили за 5с → exit 12 LOCK)
2. current_revision = jq '._revision' /etc/vpn-kit/install-state.json
3. if current_revision != expected_revision:
      exit 11  (STALE)
4. validate new JSON against schema
      if fail: exit 13
5. new_json = merge in: _revision = expected+1, _last_writer=$WRITER, _last_updated_at=$(date)
6. write atomically: echo new_json > /etc/vpn-kit/install-state.json.tmp && sync && mv .tmp → final
7. journal-append "state_updated" revision=N+1 writer=$WRITER
8. flock release
```

### Retry-протокол для callers

```
for attempt in 1..3:
  current_state = state-read.sh
  new_state = apply_my_changes(current_state)
  result = state-write.sh --expected-revision current_state._revision < new_state
  if result == 0: break (success)
  if result == 11 (STALE):
      log "concurrent write detected, re-reading and merging"
      sleep $((RANDOM % 1000))ms  # jitter
      continue
  if result == 12 (LOCK):
      sleep exponential backoff (100ms, 500ms, 2s)
      continue
  if result == 13 (VALIDATION):
      fail hard, не retry — данные кривые
if attempt > 3:
  fail hard → journal-append "concurrent_write_conflict_unresolved", alert user
```

### events.jsonl — exclusive append

```sh
# lib/journal-append.sh
flock -x /var/lock/vpn-kit-journal.lock \
  sh -c 'printf "%s\n" "$EVENT_JSON" >> /etc/vpn-kit/journal/events.jsonl; sync'
```

Без lock'а несколько одновременных append могут **переплестись** (если строка > 4KB буфера) и получить мусорные JSONL-записи. С `flock -x` — атомарно.

### flock на compound операции

Некоторые операции трогают **несколько** файлов (dynamic-add пишет `persistent-sets.nft` + `config.json` + `install-state.json` + `events.jsonl`). Для них дополнительный **мастер-лок**:

```
/var/lock/vpn-kit-compound.lock   — держат compound-writers (staged apply, dynamic-add, session-close push)
/var/lock/vpn-kit-state.lock      — file-level lock для state-write.sh
/var/lock/vpn-kit-notes.lock      — file-level для notes-write.sh
/var/lock/vpn-kit-quirks.lock     — file-level для quirks-update.sh
/var/lock/vpn-kit-journal.lock    — для journal-append.sh
```

Иерархия: compound **берёт первым** vpn-kit-compound, потом индивидуальные. Всегда в этом порядке — чтобы не было dead-lock.

Compound lock timeout — **30 секунд** (успеть дождаться чужой операции). Если не взяли за 30с — `exit 12`, caller retry через backoff.

### Session sync push — особый случай

`sync push` в конце сессии **не должен** перетирать свежие изменения на роутере (например, от бота). Протокол:

```
1. Перед push: sync pull последней версии
2. Merge: local cache vs router copy — **только по revision, не по timestamp** (см. §9.1 Синхронизация)
   - install-state.json: автомерж через revision — если router `_revision` > cache `_sync_base_revision`, 3-way merge
   - router-notes.md: merge по секциям (markdown heading'ам), CAS по frontmatter `revision`
   - learned-quirks.yaml: deep-merge по ключам; при конфликте одного ключа — **ветка с бОльшим `_revision`** (не timestamp, clock skew)
   - events.jsonl: append-only reconcile по hash'ам строк (новые с обеих сторон дописываются, дубликаты отбрасываются)
3. Валидация: собранный результат проходит schema-check
4. Push: через стандартный CAS write-API (`expected_revision = _sync_base_revision` после merge)
5. Если CAS fail (STALE) → повторяем с шага 1 (за это время ещё что-то изменилось)
```

Без такой merge-процедуры session close **сломает данные бота** — перетрёт его изменения старой локальной копией.

### Writer-ID convention

`_last_writer` формат: `<role>@<instance-id>`
- `claude-code@session-abc123` — сессия Claude Code, session-id из Claude Code SDK
- `tg-bot@home-server` — бот в docker на home-server
- `routerctl@home-router` — если юзер вручную через `routerctl` на роутере
- `manual@ssh-session` — если детектим что правили руками (см. R8 manual_intervention)

По `_last_writer` в journal можно восстановить "кто что делал", даже если writer'ов несколько.

### Что будет реализовано в Этапе 0

- Только **single-writer сценарий (Claude Code)** — но с полной CAS-машинерией с первого дня
- `flock` на append events.jsonl — обязательно
- Compound lock — реализуется как no-op wrapper (hold single writer, no contention), но API уже финальный
- Multi-writer тесты (параллельный Claude + имитация бота) — проверочный сценарий в Этапе 0 integration tests

Когда в Этапе 3 появится реальный бот — CAS-контракт уже работает, бот просто подключается как ещё один writer.

## 10. Zapret — pinned install

> ⚠ **HERITAGE / устарело.** Навык перешёл на **zapret2** (remittor, бинарь `nfqws2`,
> Lua-стратегии): init `/etc/init.d/zapret2`, конфиг `/opt/zapret2/config` (строка
> `NFQWS2_OPT`), исключение VPN-IP через `/opt/zapret2/ipset/zapret-ip-user-exclude.txt`,
> подбор стратегий через `blockcheck2.sh`. Канонический источник правды —
> `runbooks/11-zapret2.md` + `templates/zapret/zapret.versions.yaml` +
> `templates/zapret/zapret2-strategy.md`. Описание ниже (pinned tarball bol-van v72.12)
> сохранено как исторический контекст и НЕ отражает текущую реализацию.

**Проблема.** `git clone bol-van/zapret` во время install — supply chain риск.

**Решение:**
```yaml
# templates/zapret/zapret.versions.yaml
zapret:
  version: "v72.12"
  source:
    primary:
      url: "https://github.com/bol-van/zapret/archive/refs/tags/v72.12.tar.gz"
      sha256: "<SHA-256 от upstream release tarball>"
    mirror:
      url: "https://<наш-зеркало>/zapret-v72.12.tar.gz"
      sha256: "<тот же SHA-256>"
  precompiled_binaries:
    aarch64: {url: "...", sha256: "..."}
    armv7:   {url: "...", sha256: "..."}
    x86_64:  {url: "...", sha256: "..."}
    mips:    {url: "...", sha256: "..."}
```

**install-zapret.sh flow:**
```
1. Прочитать zapret.versions.yaml → targets для текущей arch
2. Скачать primary, проверить SHA-256
3. Если primary fail (404, sha mismatch, timeout) → mirror, снова проверить SHA
4. Если обе fail → прекратить установку с понятной ошибкой
5. Распаковать, записать версию+SHA в install-state.json
```

**Обновление до новой версии zapret** — отдельный runbook `20-update-zapret.md`, прописывается через staged apply (установка → probe youtube/rutracker → rollback если хуже).

## 11. Zapret — опционально, по умолчанию "да"

Мастер объясняет выбор. Если `n` — LLM предлагает добавить `youtube.com`, `googlevideo.com`, `ytimg.com` в sing-box VPN-routing вместо этого.

## 12. LAN HTTP/SOCKS5 прокси

**Зачем:** приложения (Happ на Mac/ПК, Telegram desktop) могут ходить через конкретную VPN-ноду минуя tproxy, удобно для выборочного проксирования или обхода багов нод.

**Как реализуем:** sing-box `mixed` inbound (HTTP + SOCKS5 на одном порту).

### Профили
- **minimal:** один порт `:4000` → единственный outbound
- **standard:** `:4000-:400N` по одному порту на ноду
- **advanced:** то же + динамическое добавление через бота

### Listen-адрес и allowed-CIDR вычисляются из UCI, НЕ хардкодятся

**Проблема.** `192.168.1.1/24` работает только на дефолте. У юзеров встречаются:
- Изменённый LAN IP (`10.0.0.1`, `192.168.50.1`)
- Другая маска (`/16`, `/25`)
- VLAN'ы / guest zone (отдельный bridge, отдельная firewall zone)
- Несколько bridge-сетей (LAN + IoT + guest)

**Как skill вычисляет (в preflight и перед каждым рендером):**

```sh
# scripts/detect-lan.sh — печатает JSON
uci -q show network | grep "=interface\|=device\|=bridge-vlan"
# → для каждой L3-iface в firewall zone 'lan' (или другой выбранной):
#    {name, ipaddr, netmask, device, firewall_zone}
# → возвращаем массив, НЕ первый элемент
```

`answers.yaml` запрашивает у юзера:
```yaml
lan_proxy:
  enabled: true
  # на каких firewall zone и iface слушать — из detect-lan.sh предлагается выбор
  listen_zones: [lan]                 # массив: [lan] | [lan, guest] | [iot]
  listen_mode: all_ifaces_in_zone     # all_ifaces_in_zone | specific_ifaces
  listen_ifaces: []                   # если specific_ifaces: список iface names
  port_base: 4000                     # :4000, :4001, ... +N
```

### Шаблон (параметризованный)
```json
{
  "type": "mixed",
  "tag": "lan-proxy-polsha-${IFACE}",
  "listen": "${LAN_IP}",             // вычисляется: uci get network.<iface>.ipaddr
  "listen_port": ${PORT},
  "users": []
}
```

Если юзер выбрал `listen_zones: [lan, guest]` — skill генерит **N×M** mixed-inbound'ов (N iface × M VPN-нод), или предлагает упростить ("только LAN, guest не стоит").

### Firewall
Allowed subnets — **массив**, вычисляется из зон/iface, не хардкод:
```
src_zone: lan
src_ipaddr: [<cidr_of_lan_br>, <cidr_of_guest_br_if_selected>]
dest_port: ${PORT_BASE}-${PORT_BASE+N-1}
target: ACCEPT
```

Template `templates/firewall/lan-proxy.uci.tmpl` получает массив CIDR'ов как переменную.

### Edge cases (LLM обязан обработать)
- **Нет IP на LAN iface** (bridge не up) → ошибка preflight, сначала fix network
- **LAN IP совпадает с VPN-exit subnet** (редко, но бывает) → warn юзеру
- **IPv6 LAN** → в v1 listen только на IPv4, IPv6 документируем как out-of-scope
- **Несколько iface в одной zone с разными IP** → проксим на каждом, LLM проговаривает список портов юзеру

### Известный баг (применимо к любому LAN IP)
**polsha режет idle TCP 50-60+ с** — в `docs/lan-proxy.md` предупреждаем про long-poll consumers, рекомендуем non-polsha порт.

## 13. Динамическое добавление — домен / IP / CIDR / LAN-клиент

После установки юзер может добавлять ресурсы в VPN-routing без полной переустановки.

### Интерфейс v1 — через Claude Code
```
>>> Добавь instagram.com в VPN через openwrt-vpn-kit
```
LLM читает `install-state.json`, запускает `scripts/add-resource.sh` на роутере.

### Persistence contract (обязательный для каждого dynamic-add)

**Правило:** любое dynamic-добавление атомарно пишется в **ТРИ** места:
1. **Runtime-примитив** (немедленный эффект)
2. **Persistent storage** (выживает reboot / firewall reload)
3. **install-state.json** (виден skill'у для rerun/uninstall)

Если любой из трёх шагов fail — откатываем предыдущие, сообщаем юзеру.

### Типы ресурсов и persistence

| Тип | Runtime-примитив | Persistent storage | Restart? |
|---|---|---|---|
| **Домен** | `/etc/init.d/sing-box-tproxy reload` | Запись в `/etc/sing-box/config.json` (сериализуется целиком) | reload (не restart) |
| **IP/CIDR** | `nft add element inet sing_box_tproxy proxy_subnets { 1.2.3.4 }` (мгновенно) | Добавление в `/etc/vpn-kit/persistent-sets.nft`, который **загружается init-скриптом `sing-box-tproxy` на старте** через `nft -f` | нет |
| **LAN-клиент** | `/etc/init.d/sing-box-tproxy reload` | Запись в `/etc/sing-box/config.json` | reload |
| **Zapret host** | `kill -HUP $(cat /var/run/nfqws.pid)` (reload hostlist) | Append в `/opt/zapret/ipset/zapret-hosts.txt` | нет, HUP |

### IP/CIDR persistence — как не потерять после reboot

Отдельный файл `/etc/vpn-kit/persistent-sets.nft`:
```
# Managed by openwrt-vpn-kit. Do not edit manually.
add element inet sing_box_tproxy proxy_subnets { 203.0.113.0/24 }
add element inet sing_box_tproxy proxy_subnets { 198.51.100.50 }
```

`/etc/init.d/sing-box-tproxy` при `start` делает:
```sh
/etc/init.d/sing-box-tproxy start
  → start-service (sing-box daemon + базовый nft table)
  → if [ -f /etc/vpn-kit/persistent-sets.nft ]; then
      nft -f /etc/vpn-kit/persistent-sets.nft || log_warn "persistent sets load failed"
    fi
```

**Test case:** после reboot — `nft list set inet sing_box_tproxy proxy_subnets` содержит все элементы из файла.

### Staged apply для динамики
Те же snapshot + rollback timer, но **scope минимальный** (30s timer). snapshot = 3 файла: `persistent-sets.nft` / `config.json` / `install-state.json`.

### install-state.json fields (см. §9)
Каждый dynamic-add пишет запись в `dynamic_additions[]` с `id` (uuid), `type`, `value`, `added_at`, `origin`, `persisted_in`. Uninstall / rollback конкретной записи — по `id`.

### Edge cases
- **Юзер вручную редактировал persistent-sets.nft** → skill при diff замечает расхождение, спрашивает "принять как есть (adopt) или перезаписать (overwrite)?"
- **sing-box reload fail** на добавлении домена → LLM откатывает config.json из snapshot, запись в dynamic_additions не создаётся
- **nft add element fail** (typo в CIDR) → не пишем в persistent, не пишем в state

### Интерфейс v2 — через Telegram-бот (только advanced профиль)
`/vpn add instagram.com`, `/vpn add 192.168.1.158 full`, `/vpn list`, `/vpn del instagram.com`.

### Runbook
`runbooks/10-dynamic-add.md` — пошаговая инструкция для LLM.

## 14. Wi-Fi 6 — активация при первой установке

**Контекст.** OpenWrt по умолчанию ставит все Wi-Fi радио в `disabled=1`. Юзер должен включить и настроить вручную (LuCI или UCI). Skill берёт это на себя.

### Merge strategy (v1) — НЕ full regenerate

**Проблема с full-regenerate `/etc/config/wireless`:** снесёт гостевую сеть, нестандартные binding'и, ручные SSID'ы юзера. И reachability-check (SSH) не заметит, потому что SSH по Ethernet живёт.

**Правило v1:** skill **не переписывает** `wireless` конфиг. Три операции:
1. **Patch radios:** `uci set wireless.radio0.disabled='0'`, `.country='XX'`, `.htmode='HE80'` — точечные UCI set'ы
2. **Append new wifi-iface:** добавить наши секции с явным префиксом `vpn_kit_ap_*` — не трогая существующие
3. **Read-only валидация:** до патча прочитать текущее состояние, записать в snapshot

### Pre-check перед любым изменением wireless

```
1. uci show wireless → parse в структуру
2. Для каждого wifi-iface section:
   - Если .disabled='0' И .ssid не пустой → флаг "has_active_iface"
   - Если .ssid совпадает с answers.yaml ssid → флаг "ssid_collision"
3. Для каждого radio section:
   - Если .disabled='0' → флаг "radio_already_active"
   - Если .country != answers.country И .country не пустой → флаг "country_conflict"
```

### Решение по результатам pre-check

| Состояние | answers.yaml `wifi.merge_strategy` | Действие |
|---|---|---|
| radio disabled, нет активных iface | (любое, дефолт `patch_and_append`) | Штатная настройка: patch radio + append iface |
| radio уже активен, есть iface юзера | не указано / `skip` | **Skill не трогает wireless**, сообщает юзеру план вручную |
| radio уже активен | `patch_radios_only` | Только `.country` / `.htmode` патчим, iface не трогаем |
| radio активен, есть iface юзера | `append_iface` | Не трогаем radio, добавляем НАШ iface рядом |
| хочу перезаписать всё | `overwrite` (explicit) | Предварительно backup через staged apply, полный regenerate. **Требует двойной confirm от юзера**, LLM обязан перечислить что снесёт |
| country_conflict | не указано | Ошибка: "radio0.country=UA, ты указал DE — какое правильно?" |

### answers.yaml
```yaml
wifi:
  enable: true
  merge_strategy: patch_and_append    # skip | patch_radios_only | append_iface | patch_and_append | overwrite
  country: UA
  aps:
    - band: 2g
      ssid: "MyHome-2G"
      password: "<REDACTED>"
      encryption: "psk2"
    - band: 5g
      ssid: "MyHome-5G"
      password: "<REDACTED>"
      encryption: "sae-mixed"         # WPA3 с fallback WPA2, если драйвер умеет
      htmode: "HE80"                   # Wi-Fi 6
  network: lan                         # какую bridge-сеть bind'им (из UCI)
```

### Что делает skill (итоговый flow)
1. `scripts/detect-system.sh` определяет `wifi_radios` (phy, поддерживаемые режимы `n/ac/ax/be`, драйвер)
2. Читает текущий wireless-конфиг, запускает pre-check
3. Если `merge_strategy` не задана и есть конфликты — **задаёт вопрос юзеру**, не угадывает
4. Применяет через staged apply: snapshot `/etc/config/wireless` → UCI set/add → `uci commit wireless && wifi reload` → reachability-check (SSH через ethernet + `iw dev wlan0 info` для проверки что AP поднялся)
5. Пишет `wireless_additions[]` в install-state.json — какие секции созданы, какие options изменены (с prev/new)

### Reachability check для wireless специфичный
SSH по ethernet не подтверждает что Wi-Fi работает. Дополнительно на роутере:
- `iw dev | grep Interface` — есть наш AP
- `iw wlan0 info | grep ssid` — правильный SSID
- `logread -l 20 | grep -i hostapd` — нет критических ошибок в последних 20 записях
- (опционально) через бот-уведомление: "проверь что Wi-Fi поднялся, подключись и ответь /ok"

### Ограничения
- Wi-Fi 6 требует MT7915/MT7916/MT7986 драйверов (MediaTek) или ath11k (Qualcomm) — skill детектит и сообщает "радио X не поддерживает ax, падаю на ac"
- Страна юзер обязательно указывает — иначе снижается мощность до минимальной
- Канал по-умолчанию `auto`, в прод'е можно захардкодить

### Документация
`docs/wifi-setup.md` — как выбрать страну, почему Wi-Fi 6 vs 5, что делать если железо не умеет ax.

### Опциональность
Если юзер уже сам настроил Wi-Fi и не хочет трогать — ответ `wifi.enable: false` в answers → skill не трогает wireless config.

## 15. Как юзер запускает

```bash
# 1. Клонировать
git clone https://github.com/user/openwrt-vpn-kit ~/router-setup

# 2. Залить SSH-ключ на роутер (инструкция в docs/prerequisites.md)

# 3. Открыть ~/router-setup в Claude Code, написать:
>>> Настрой мой роутер по этому skill.
>>>   SSH: root@192.168.1.1
>>>   Если что-то неясно — спрашивай, прежде чем что-то менять.
```

**Необходимые доступы для LLM:**
- Read/Write на `~/router-setup/` (шаблоны, state, snapshot'ы)
- Bash (SSH, scp, envsubst, sha256sum)
- Edit (генерация конфигов)

**Что LLM НЕ делает без явного confirm:**
- Reboot роутера
- Открытие SSH через WAN
- Любой staged apply (каждый с отдельным confirm на первой установке; на rerun — с батч-confirm по плану)

## 16. Документация юзера (на русском)

### `docs/prerequisites.md`
- Требования: **OpenWrt 24.10+**, доступ в интернет, свободно ≥30 MB flash, ≥256 MB RAM
- Как залить SSH-ключ (`ssh-copy-id` или через LuCI)

### `docs/telegram-setup.md`
Пошагово с ссылками (БЕЗ скриншотов ботовских секретов):
1. `@BotFather` → `/newbot` → имя → username → TOKEN
2. Написать боту любое сообщение
3. `https://api.telegram.org/botTOKEN/getUpdates` → найти `chat.id`
4. Безопасность: токен не коммитить, хранить в `/etc/vpn-kit/secrets.conf` (chmod 600)

### `docs/vpn-sources.md`
- Вариант A: свой VDS (Remnawave / X-UI / 3x-ui)
- Вариант B: публичные сервисы
- Формат VLESS URL

### `docs/profiles.md`
- Таблица minimal/standard/advanced
- Как понять сколько RAM: `free -m`
- Как сменить профиль после установки

### `docs/wifi-setup.md`
- Страна, SSID, пароль, режим (ax/ac/n)
- Как skill определяет возможности радио
- Почему важна правильная страна

### `docs/lan-proxy.md`
- Как использовать `http://<router-lan-ip>:4000` и `socks5://<router-lan-ip>:4000` (адрес вычисляется skill'ом, не хардкод)
- Настройка в Happ, Firefox, Telegram Desktop
- Какой порт для long-poll (не polsha-style ноды)

### `docs/dynamic-add.md`
- Как добавить домен/IP/клиент после установки
- Интерфейс через Claude Code (v1) и через бота (v2)

### `docs/security.md`
- Контракт по секретам (см. раздел 7)
- Где что хранится
- Как ротировать TG-токен или VLESS UUID
- Что делать при компрометации

### `docs/troubleshooting.md`
- DNS не резолвит
- Алерты не приходят в TG
- sing-box падает
- Zapret ломает сайт
- Rollback не сработал
- `nft flush ruleset` — как восстановить

## 17. Verification чеклист (что LLM проверяет)

**Локальные сигналы (обязательно, все должны быть OK):**
- [ ] SSH доступ после каждого staged apply (отдельная сессия)
- [ ] `nslookup google.com 127.0.0.1` → резолвится через dnsmasq
- [ ] `nslookup chatgpt.com 127.0.0.42` → FakeIP в диапазоне 198.18.0.0/15
- [ ] `nft list tables` → `inet fw4`, `inet sing_box_tproxy`, (опц) `inet zapret_custom`
- [ ] `/etc/init.d/sing-box-tproxy status` → running
- [ ] `/etc/init.d/zapret-custom status` → running (если ставили)
- [ ] `pgrep https-dns-proxy` → процесс есть
- [ ] Cron-записи (`crontab -l`) содержат обе watchdog записи
- [ ] Файл `/etc/vpn-kit/secrets.conf` существует, mode 0600, owner root

**Сетевые probe'ы (controlled endpoints, не chatgpt/youtube):**
- [ ] TCP-probe `:443` на первый VLESS-сервер (из answers.yaml) → connect OK
- [ ] TCP-probe `1.1.1.1:443` через VPN tproxy → OK
- [ ] Telegram API reachability: resolve `api.telegram.org` through the active test environment and verify an expected unauthenticated response (for example HTTP 401), without pinning a production IP

**End-to-end:**
- [ ] Скрипт `tg-send.sh` шлёт тестовое сообщение → `getUpdates` видит его (или юзер подтверждает получение)
- [ ] install-state.json записан и валиден по схеме

**Эмпирические (информационные, НЕ acceptance):**
- ℹ️ YouTube открывается (если zapret установлен) — отображаем в отчёте, но НЕ блокируем setup если fail (может быть проблема не у нас)
- ℹ️ chatgpt.com резолвится и отвечает — то же, информационно

## 18. План реализации

### Этап 0 — каркас safety (до любых инсталляторов!)
1. **`vpn-kit-rollback` procd daemon** — `/etc/init.d/vpn-kit-rollback` + `/usr/sbin/vpn-kit-rollback` + preflight hard gate (procd + start-stop-daemon)
2. `lib/staged-apply.sh` + `lib/reachability-check.sh` + тесты на VM (сценарий: apply ломает SSH → timer откатывает)
3. `schemas/answers.schema.yaml` + `schemas/install-state.schema.json` — **обязаны покрывать все поля** (wifi, proxy_ports, firewall_rules_added, dynamic_additions)
4. `scripts/detect-lan.sh` + `scripts/detect-system.sh` — UCI-derived listen/zones, wifi_radios
5. `lib/state-read.sh` / `lib/state-write.sh` — атомарная запись на роутер, sync cache на клиенте, режим `adopt` если state missing
6. `docs/security.md` + secret-контракт в `SKILL.md`
7. **Memory infra:** `lib/journal-append.sh` + `lib/notes-read/write.sh` + `lib/quirks-update.sh` + `schemas/event.schema.json` + `schemas/learned-quirks.schema.yaml`
8. **CAS + locks:** `_revision` / `_last_writer` поля в схемах; exit-code контракт 0/11/12/13 в write-скриптах; `/var/lock/vpn-kit-*.lock` через `flock`; merge-процедура в `session-sync.sh`
9. **Snapshot retention:** `lib/snapshot-gc.sh` + интеграция в rollback daemon (delete-on-success); cron на age/watermark
10. **Integration tests R1-R8 + CAS + GC:** staged-apply fail'ится если journal не записался; session-close обнаруживает пробелы; manual_intervention_detected работает; два параллельных writer'а корректно сериализуются через CAS-retry; snapshots не накапливаются в 24-часовом стресс-тесте

### Этап 1 — MVP профиля `minimal`
4. Структура папки + `README.md` / `SKILL.md`
5. `docs/prerequisites.md`, `docs/telegram-setup.md`, `docs/vpn-sources.md`, `docs/wifi-setup.md`
6. Шаблоны sing-box minimal + mixed inbound + init.d
7. `templates/zapret/zapret.versions.yaml` + `install-zapret.sh` с SHA-check
8. Шаблоны watchdog'ов (порт из наших, параметризованы)
9. `scripts/detect-system.sh`, `scripts/check-conflicts.sh`, `scripts/add-resource.sh`
10. Runbook'и `00-overview`, `01-preflight`, `02-collect-answers`, `03-plan-preview`, `04-install-minimal`, `07-verify`, `08-post-install`, `10-dynamic-add`, `11-wifi-setup`, `99-uninstall`
11. Тест на virtual OpenWrt VM (qemu) + второй реальный роутер

### Этап 2 — профиль `standard`
12. `config-standard.json.tmpl` с rule_sets и auto-failover
13. Второй DoH в шаблоне
14. Расширение mixed-inbound до :4000-:400N
15. Runbook `05-install-standard.md`

### Этап 3 — профиль `advanced`
16. Встраивание `routerctl` (из параллельного proposal)
17. Минимальный Telegram-бот на роутере
18. Runbook `06-install-advanced.md`
19. Dynamic add через бота

### Этап 4 — перенос в отдельный git-репо
20. Выделить в отдельный репозиторий
21. CI / release workflow (lint schemas, test staged-apply на qemu)
22. README для раздачи

## 19. Риски и открытые вопросы

### Риски (закрытия отмечены ~~strikethrough~~)
- ~~Разнообразие OpenWrt версий~~ — hard gate на 24.10+ в v1
- **Разнообразие архитектур:** zapret бинари для 4+ arch
- **ISP-специфика zapret-стратегий:** `docs/zapret-strategies.md`
- **TSPU-блокировки Telegram API:** двухканальная отправка (direct + VPN)
- **Гонки с podkop/mwan3:** `check-conflicts.sh` требует manual removal
- ~~Supply-chain риск zapret~~ — pinned release + SHA-256 + mirror
- ~~Потеря доступа при удалённой перенастройке~~ — staged apply + **procd-rollback-daemon** (не at/cron)
- ~~Утечка секретов в репо~~ — secrets contract + LLM self-check на diff
- ~~Эфемерность dynamic-add IP/CIDR~~ — persistence contract (runtime + `persistent-sets.nft` + state)
- ~~Хардкод 192.168.1.1/24 LAN proxy~~ — UCI-derived listen/zones
- ~~install-state.json authority неясна~~ — authoritative на роутере, `/etc/vpn-kit/install-state.json`, cache локально
- ~~Wi-Fi full regenerate снесёт пользовательскую конфигурацию~~ — merge strategy (skip/patch/append/overwrite), дефолт не трогает активные iface
- ~~Конкурентные writers перетирают state/notes/quirks~~ — CAS по `_revision` + flock на compound-операции + merge-процедура в sync push
- ~~Snapshots съедают persistent flash~~ — retention policy (delete-on-success + keep-5 + age 7d + watermark 10 MB + emergency prune)
- **Wi-Fi страна:** валидация в answers.schema (enum ISO 3166)
- **LAN HTTP proxy открыт всей zone:** документируем в `docs/lan-proxy.md`, опц ограничиваем по MAC/IP

### Открытые вопросы
1. **Где хостить skill-репо:** GitHub / GitLab / самохост? (Рек. GitHub)
2. **Лицензия:** MIT / GPL / CC-BY-SA? (Рек. MIT)
3. **Controlled probe endpoint:** поднимаем свой `https://probe.openwrt-vpn-kit.dev/ok` или обходимся локальными TCP-probe'ами (1.1.1.1:443)? Свой endpoint = operational cost, TCP-probe = проще, но менее показательно
4. **Zapret mirror:** куда кладём зеркала тарболлов на случай недоступности GitHub? (Свой VDS? Cloudflare R2?)
5. **Dual-TG send (direct + VPN):** только в advanced или сразу во всех профилях?
6. **i18n:** задел на английский сразу или по запросу?
7. **Telemetry:** собирать ли анонимную статистику? (Рек. нет — privacy-first)
8. **Wi-Fi 6E / 7:** включать как опцию, если железо умеет? (Вряд ли массово; v1 — только ax/ac/n)

---

## Статус

**Draft revision 6** (2026-04-21). Закрыт четвёртый круг критики:
- **COMMIT = state-write (atomic):** отдельного `.commit` marker'а больше нет. Daemon смотрит на `install-state.json.committed_steps` напрямую. Snapshot включает `state-before.json`, rollback восстанавливает и файлы, и state через CAS. Между сетевым изменением и state-update не остаётся окна рассинхрона
- **Snapshot split на два типа:** success-snapshots (`/etc/vpn-kit/snapshots/`) — delete-on-success immediate + watermark/emergency safety net; rolled-back (`/etc/vpn-kit/snapshots/rolled-back/`) — keep-last-5 + age 30d для forensics. Противоречие delete-on-success ↔ keep-last-N устранено — правила действуют на **разные множества**
- **Sync полностью revision-based, не timestamp:** при конфликте одного ключа в learned-quirks — бОльший `_revision`, не newer timestamp (clock skew). install-state.json пример теперь показывает `_revision` / `_last_writer` / `_last_updated_at` + `committed_steps[]`

**Revision 5** (CAS + retention + hygiene), **Revision 4** (операционная память R1-R8), **Revision 3** (safety: procd-daemon, persistence, UCI-derived, Wi-Fi merge).

Ждёт старта реализации Этапа 0 (safety + memory + CAS + GC — всё вместе, до любых инсталляторов).
