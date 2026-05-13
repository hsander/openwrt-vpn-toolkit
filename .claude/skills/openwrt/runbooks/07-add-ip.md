# Runbook 07 — Завернуть IP / подсеть в VPN

## Когда использовать

Триггеры от пользователя: «заверни IP 1.2.3.4 через VPN», «весь Netflix через VPN» (с конкретными IP/CIDR), «добавь подсеть 192.168.5.0/24 в туннель», «маршрутизируй IP X через VPN», «pусть 8.8.8.8 ходит через VPN».

Pre-conditions (что должно быть в `memory/<alias>/state.md`):
- Пункт 11 «`config.json` валиден» = ✅
- Пункт 13 «tproxy запущен» = ✅
- Пункт 14 «≥1 VPN outbound + auto-failover» = ✅

Дополнительно: на роутере должен присутствовать `/etc/vpn-kit/install-state.json` — `add-ip.sh` читает его через CAS и упадёт с exit 13 «install-state.json отсутствует» если его нет. Если так — отправь пользователя на `runbooks/01-first-time.md` (`install-vpn.sh`) или `runbooks/06-adopt-existing.md` (`adopt.sh`).

## Шаг 1. Что спросить у пользователя

1. **IP или CIDR (обязательно).** Если пользователь дал домен (`youtube.com`, `chatgpt.com`) — отправь его на `runbooks/02-add-domain.md`:
   > Это домен, а `add-ip.sh` принимает только IP/CIDR. Для доменов используем `add-domain.sh` (см. runbook 02).
2. **IPv4 или IPv6.** В V1.1 поддерживается **только IPv4**. IPv6 пока за флагом `--allow-ipv6` (внутри скрипта B.2 отказывает с exit 13 — wiring для `proxy_subnets_v6` появится в B.3). Если пользователь явно даёт IPv6 — скажи: «IPv6 пока не поддержан (V1.1). В B.3/V1.2 появится `--allow-ipv6` с настоящим `proxy_subnets_v6` set'ом».
3. **Уверен ли пользователь?** Особенно если это:
   - **`0.0.0.0/0`** (default route) — это **весь интернет** через VPN. Почти всегда ошибка (для этого есть default outbound в sing-box config).
   - **RFC1918** (`10/8`, `172.16/12`, `192.168/16`) — это сам LAN роутера. VPN-роутинг внутрь LAN — это loop / no-op.

   Без `--force` скрипт сам откажет (exit 13). С `--force` — пропустит, но это редкий валидный кейс (например, выделенная LAN-подсеть гостей `192.168.50.0/24`, которая должна выходить через VPN).

### Валидация локально (до запуска скрипта)
- IPv4 формат `N.N.N.N` или `N.N.N.N/M`, октеты 0-255, prefix 0-32.
- Если пользователь дал просто `1.2.3.4` без `/N` — скрипт нормализует в `/32` молча.
- Loopback (`127.x`), link-local (`169.254.x`), multicast (`224.x-239.x`) — **всегда отказ**, даже с `--force`. Если пользователь упёрся — это баг в его понимании; объясни.

### Спец-случай: пользователь хочет «всё через VPN» / «default outbound»
Триггеры: «всё через VPN», «default через DE», «`0.0.0.0/0`».

`add-ip.sh --ip 0.0.0.0/0 --force` это **техническая возможность**, но семантически неправильная: для default route правильнее править `route.final` или сделать `direct` outbound default-deny'нутым. Скажи пользователю:

> Для «всё через VPN» правильнее настроить `route.final` в sing-box config (`bin/raw-ssh.sh` + `bin/doctor.sh`), а не пихать `0.0.0.0/0` в `proxy_subnets`. Если очень хочется через `add-ip` — `--ip 0.0.0.0/0 --force`, но осторожно.

## Шаг 2. Выполнение

```bash
bin/add-ip.sh --router <alias> --ip <ip-or-cidr>
```

Дополнительно:
- `--force` — обходит safeguard'ы (RFC1918, `0.0.0.0/0`). НЕ используй сам, спроси пользователя.
- `--allow-ipv6` — V1.1 всё равно откажет на стадии B.2 (см. выше). Не предлагай.
- `--no-backup` — **только для тестов**. Без snapshot rollback не сработает.

Что делает:
1. snapshot (`backup-now.sh`) → запоминается `snapshot_id`;
2. читает `/etc/vpn-kit/install-state.json` через CAS (revision + payload);
3. ownership-expand (defensive): добавляет `persistent-sets.nft` + `sing-box-tproxy` в `files_owned_by_skill`;
4. drift-check на `/etc/init.d/sing-box-tproxy` через `adopted_config_sha256` (отказ если drift без `--force`);
5. tri-state idempotency: case A (всё уже есть) → no-op; case B (boot-window <5min) → silent runtime sync; case C (drift ≥5min) → loud warn + runtime sync; case D → полный pipeline;
6. перестраивает `/etc/vpn-kit/persistent-sets.nft` (append + dedup);
7. патчит `/etc/init.d/sing-box-tproxy` (idempotent — добавляет `nft -f persistent-sets.nft` в `start_service`);
8. atomic mv обоих файлов в одном SSH round-trip;
9. `nft add element inet sing_box_tproxy proxy_subnets { <ip> }` runtime;
10. CAS-write итогового state с retry на STALE (×3);
11. verify через `nft list set`;
12. рендерит `memory/<alias>/subnets.md`;
13. журнал.

Exit codes:
- `0` — добавлено (или no-op idempotent, или boot-window/drift sync).
- `2` — usage error / SSH/backup упал.
- `11` — CAS STALE после ретраев.
- `12` — CAS LOCK.
- `13` — валидация (битый IP, refused-prefix без `--force`, IPv6 без B.3, install-state отсутствует, drift без `--force`).
- `20` — SSH preflight упал.
- `30` — apply упал / rollback сработал.
- `64` — `--via <tag>` (per-tag pinning не реализовано в V1.1 — для этого `pin-device.sh`).

## Шаг 3. Подтверждение

- Output скрипта показывает: `snapshot`, `ip`, `nft set`, `persistent`, `revision`.
- Прочитай `memory/<alias>/subnets.md` — должна появиться новая строка с IP, family, via, nft_set, временем и origin.
- Опционально (если хочешь убедиться) — `bin/doctor.sh --router <alias>` или прямой `ssh ... 'nft list set inet sing_box_tproxy proxy_subnets'`.

Если был **case B (boot-window sync)** или **case C (runtime drift)** — это нормально, скрипт recovered. Скажи пользователю что был silent sync / drift recovered (особенно case C — это значит что-то странное случилось с runtime nft state).

## Что обновляется в memory/

- `memory/<alias>/subnets.md` — новая строка таблицы.
- `memory/<alias>/journal.jsonl` — событие `add_ip` с `ip`, `family`, `via`, `nft_set`, `snapshot_before`, `revision`.
- `state.md` и `vpns.md` **не меняются** (новых outbound'ов нет).

## Что сказать пользователю

```
✅ IP/CIDR <value> теперь маршрутизируется через VPN.
- nft set: inet sing_box_tproxy proxy_subnets
- Persistent: /etc/vpn-kit/persistent-sets.nft (загружается на старте tproxy)
- Snapshot до: <snap-id>
- install-state revision: <rev>

Откат: bin/restore.sh --router <alias> --snapshot <snap-id>
```

Если был no-op idempotent skip: «`<value>` уже добавлен (persistent+state+runtime) — никаких изменений.»

Если был drift recovery (case C): «`<value>` есть в persistent+state, но **был пропал из runtime nft** (drift). Восстановил через `nft add element`. Возможно, кто-то делал `nft flush` или sing-box упал и не дочитал persistent-sets.nft — проверь `bin/logs.sh`.»

## Edge cases / частые ошибки

- **Пользователь дал домен**: отправь на `02-add-domain.md`. Не пытайся resolve'ить домен в IP сам — это меняет семантику (IP может протухнуть, а домен живёт).
- **`0.0.0.0/0` без `--force`** → exit 13 «default route — заворачивать ВСЁ почти всегда ошибка». Скажи пользователю про `route.final` (см. спец-случай выше).
- **RFC1918 без `--force`** → exit 13 «`<ip>` в RFC1918 (твой LAN). VPN-роутинг внутрь LAN — обычно ошибка». Если пользователь настаивает (например, изолирует подсеть гостей) — повтори с `--force` и обязательно объясни последствия (default gateway этой подсети должен быть роутер, иначе пакеты не попадут в tproxy chain).
- **IP уже добавлен (case A)** → exit 0, info «уже добавлен» — не паникуй, скажи пользователю.
- **Runtime drift detected (case C)** → exit 0 + WARN на stderr. Скажи пользователю что был silent recovery; предложи `bin/logs.sh` чтобы понять причину drift'а (обычно — `nft flush` руками или crash sing-box без перезагрузки tproxy).
- **`install-state.json` отсутствует** → exit 13 «запусти `bin/adopt.sh` или `bin/install-vpn.sh` сначала». Отправь на `01-first-time.md` или `06-adopt-existing.md`.
- **IPv6 без `--allow-ipv6`** → exit 13 «нужен `--allow-ipv6`». С `--allow-ipv6` в V1.1 всё равно exit 13 «IPv6 add-ip пока не реализован (B.3 territory)». Скажи пользователю честно — ждать V1.2.
- **`--via <tag>` (per-tag IP pinning)** → exit 64 not-implemented. Скрипт сам подскажет: для «это устройство через tag X» — `pin-device.sh` (см. `08-pin-device.md`). Для «этот IP через tag X» — V1.2.
- **Drift на `sing-box-tproxy` без `--force`** → exit 13. Это значит кто-то правил init.d руками. Варианты: `bin/raw-ssh.sh` (review), `bin/adopt.sh` (re-adopt), `--force` (патч поверх, журналируется).
- **CAS STALE после 3 ретраев** → exit 11. Runtime + persistent уже применены, install-state desync. Перезапусти `add-ip` (no-op idempotent подхватит state).
- **Apply упал после step 8 (persistent mv'нуты)** → автоматический rollback через `restore.sh --snapshot <id>` + best-effort `nft delete element`. Если rollback тоже упал — РУЧНОЕ ВМЕШАТЕЛЬСТВО, скажи пользователю.

## НЕ ДЕЛАТЬ

- НЕ запускать `0.0.0.0/0` без явного запроса пользователя и `--force`.
- НЕ запускать RFC1918 без объяснения пользователю (это весь LAN — обычно не имеет смысла).
- НЕ резолвить домены в IP самостоятельно — отправляй на `add-domain.sh`.
- НЕ pin'ить конкретное устройство на конкретный outbound через `add-ip` — для этого `pin-device.sh` (см. `08-pin-device.md`).
- НЕ редактировать `subnets.md` руками — только через `add-ip.sh` (delete-ip в V1.2).
- НЕ запускать `add-ip.sh` если state.md показывает, что VPN не установлен или install-state.json отсутствует.
- НЕ делать ретрай после exit 30 без выяснения причины — rollback уже сработал, но симптом остался.
