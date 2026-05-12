# openwrt-skill

Claude-навык для безопасной настройки и обслуживания OpenWRT-роутеров со связкой **sing-box (VLESS Reality) + zapret + LAN-прокси + Telegram-watchdog**.

Архитектура одной фразой: **агент НЕ выполняет сырой SSH — только вызывает скрипты из `bin/`**, которые сами делают snapshot, валидацию, staged-apply, и обновляют память.

## Что умеет (V1, OpenWRT-роутер)

| Сценарий | Скрипт | Что делает |
|----------|--------|------------|
| Probe состояния | `bin/doctor.sh` | 20-пунктовый чек-лист → `memory/<alias>/state.md` |
| Первичная SSH-настройка | `bin/setup-ssh.sh` | ed25519, install в authorized_keys, ~/.ssh/config alias |
| Watchdog с TG-алертами | `bin/setup-watchdog.sh` | `/etc/router-watchdog.conf` + cron-задачи |
| Полный VPN-bootstrap | `bin/install-vpn.sh` | парсит `vless://`, ставит пакеты, sing-box + tproxy + DNS chain |
| Добавить домен в VPN | `bin/add-domain.sh` | rule_set merge, hot reload |
| Удалить домен | `bin/remove-domain.sh` | reverse |
| Добавить VPN-ноду | `bin/add-vpn.sh` | outbound + auto-failover + zapret set |
| Удалить VPN-ноду | `bin/remove-vpn.sh` | reverse |
| Добавить LAN-прокси | `bin/add-proxy.sh` | mixed-inbound :400X |
| IP-маршрут | `bin/add-ip.sh` | **STUB (V1.1)** — выдаёт инструкцию через escape hatch |
| Пин устройства | `bin/pin-device.sh` | **STUB (V1.1)** — выдаёт инструкцию через escape hatch |
| Snapshot | `bin/backup-now.sh` | архив `/etc/sing-box`, init.d, etc |
| Откат | `bin/restore.sh` | staged-apply с двойным snapshot'ом |
| Здоровье | `bin/health.sh` | sing-box status, nft, DNS, SOCKS exit IP |
| Логи | `bin/logs.sh` | tail sing-box / watchdog / zapret |
| Сырой SSH | `bin/raw-ssh.sh` | escape hatch — требует подтверждения у юзера |

## Установка навыка

Это **project-scoped skill** — он живёт внутри репозитория в
`.claude/skills/openwrt/` и автоматически активируется только при работе
Claude в этой папке. Глобальная регистрация не нужна.

```bash
# 1. Открой проект в Claude Code из этой папки
cd /path/to/openwrt-skill   # папка содержит .claude/skills/openwrt/

# 2. Создай реестр роутеров
cp .claude/skills/openwrt/memory/routers.yaml.example \
   .claude/skills/openwrt/memory/routers.yaml
# отредактируй: добавь свои роутеры (alias, host)

# 3. В Claude Code, попроси
>>> настрой роутер home
```

Дальше Claude прочитает `SKILL.md`, запустит `bin/doctor.sh --router home`, покажет `state.md` и предложит, что настроить.

## Требования на машине агента

```bash
brew install jq yq flock openssh
# опционально (только для тестов): bats-core
```

На роутере (OpenWRT) скрипты ставят `sing-box`, `https-dns-proxy`, `kmod-nft-tproxy`, `kmod-nft-queue`, `coreutils-sort`, `gzip`, `jq`, `curl`, `ca-bundle`, `ca-certificates`. Минимум OpenWRT 24.10 (для `apk`-based dependency).

## Принципы

- **Safe API only.** Список разрешённых операций — это файлы в `bin/`. Всё остальное требует явного подтверждения через `raw-ssh.sh`.
- **Snapshot before mutate.** Каждая mutating-операция начинается с pre-backup. Откат — `bin/restore.sh`.
- **No secrets in memory.** UUID, токены, private keys никогда не пишутся в MD-файлы и журнал.
- **Staged apply.** Restarts происходят через `lib/staged-apply.sh` с reachability-watcher: если SSH/health отвалился — auto-rollback.
- **Memory updated only on success.** `state.md` / `domains.md` / `vpns.md` обновляются скриптом только при exit 0.

См. [`SKILL.md`](./.claude/skills/openwrt/SKILL.md) — инструкции для агента (что когда вызывать).
См. [`memory/README.md`](./.claude/skills/openwrt/memory/README.md) — как устроена память.
См. [`runbooks/`](./.claude/skills/openwrt/runbooks/) — пошаговые гайды под каждый сценарий.

## Безопасность и mitigations

Навык создаёт **passphraseless ed25519 ключ** в `~/.ssh/openwrt_<alias>_ed25519` (для agent-автоматизации) и использует `StrictHostKeyChecking=accept-new` (TOFU при первом подключении). Это сознательный trade-off — но он требует от тебя:

1. **Full-disk encryption на ноутбуке.** Кража машины = root на всех твоих роутерах из `routers.yaml`. macOS: FileVault обязателен. Linux: LUKS.
2. **Локальный физический контроль над машиной во время `setup-ssh`.** Первое подключение к новому роутеру не проверено криптографически. Лучше делать setup из доверенной сети (LAN рядом с роутером, не публичный WiFi).
3. **Хранение `memory/routers.yaml` вне публичных репо.** Файл сам по себе не секрет (только alias/host/ssh_alias), но в сочетании с украденным ключом — карта для атаки. `.gitignore` навыка уже исключает `memory/*/` и `memory/routers.yaml` — не убирай.
4. **TG_TOKEN живёт ТОЛЬКО на роутере** в `/etc/router-watchdog.conf` (chmod 600). На агент-сайде временный файл (см. `setup-watchdog.sh` Phase 1 инструкции) shred'ится после успешной заливки. Не редактируй `--keep-local` без причины.
5. **VPN-секреты (UUID/Reality keys) живут ТОЛЬКО в `/etc/sing-box/config.json` на роутере.** Никогда не пишутся в `memory/`, journal, чат. `lib/memory-journal.sh` enforced'ит это.
6. **Snapshots на роутере содержат TG_TOKEN** (в `/etc/router-watchdog.conf` под тарболом). Папка `/etc/vpn-kit/snapshots/` chmod 700, доступна только root. Если копируешь snapshot с роутера к себе — учти.

### Если ноутбук украли

1. Сменить TG_TOKEN у @BotFather (старый become useless → watchdog'и онемеют).
2. Сменить UUID/Reality keys у VPN-провайдера (старые VPN-ключи перестанут работать).
3. На каждом роутере: руками удалить старый SSH ключ из `authorized_keys`. Если есть сеть к роутеру с другой машины — ssh туда и затереть строку. Если нет — заводская сброс/перенастройка.
4. Восстановить навык: `bin/setup-ssh.sh --router <alias> --host ...` создаст новый ключ, остальное вернётся.

### Высокочувствительный сценарий

Если роутер критичен (бизнес, инфраструктура) — добавь passphrase на ключ руками после первого setup:
```bash
ssh-keygen -p -f ~/.ssh/openwrt_<alias>_ed25519
```
и держи открытым `ssh-agent`. Скрипты использут `IdentitiesOnly yes` + agent через `~/.ssh/config`, так что passphrase будет запрашиваться при каждой сессии (или один раз через `ssh-add`).

## Лицензия

TBD.
