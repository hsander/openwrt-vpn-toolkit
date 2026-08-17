# Resilient travel failover: direct AWG, relay AWG, VLESS reserve

## English operational summary

Use this workflow when a travel router must keep direct AWG to home as
the primary private-LAN path and use a separately managed VPS for two reserves:

- an AWG relay on UDP/443 for home/travel private-LAN access;
- an optional VLESS Reality path on TCP/443 for backup Internet only.

Choose an unused overlay CIDR and unique tunnel addresses for your deployment;
the examples below are placeholders. Do not modify the primary direct tunnel
or its listener. The VPS relay must use UDP/443 only and must not modify any
existing Xray/VLESS TCP/443 listener.

Required order:

1. Verify the ordinary travel profile and direct AWG path. Run the read-only
   VPS audit, home doctor, and travel inventory, substituting your own aliases.
2. Install the peer-less VPS hub and retain its public key, snapshot ID, and
   printed rollback command.
3. Configure the separate home backup client, then add its public key and
   routed LAN as one VPS peer.
4. Configure the first travel router, add its peer and only the required
   paired-LAN UFW forwarding rules. Do not add another router until this pilot passes.
5. Prove fresh handshakes and 16/512/1200-byte ping payloads in both directions
   before installing any watchdog.
6. Install route watchdogs at both ends. Failover of only one end can create an
   asymmetric private route. Defaults are a 10-second interval, three failures
   before failover, and three successes before failback.
7. Verify the active private route, unchanged default route, ordinary
   Internet/DNS, LuCI/SSH, `MemAvailable >= 20480 KiB`, reboot recovery,
   direct-path outage, direct-path recovery, VPS outage, and captive portal.
8. Repeat for another travel router only after the complete first-router
   acceptance matrix passes. Home reuses its backup interface and adds a
   separate watchdog target.

Every mutation must retain its snapshot or exact rollback command. Remove
components in reverse order. VPS peer/hub rollback intentionally avoids live
peer or interface teardown on the affected DKMS path; if it reports
`reboot_required=true`, schedule a VPS reboot instead of forcing live removal.
Never give the backup AWG client `0.0.0.0/0`, never change the default route,
and never store private keys, VLESS URLs/UUIDs, Reality keys, or passwords in
the repository, logs, journal, or memory.

VLESS reserve is a later, independent phase. It can restore Internet access but
cannot prove home-LAN reachability when UDP is fully blocked. Contract tests do
not replace live VPS, router reboot, traffic, or physical-device evidence.

The detailed commands, rollback sequence, and acceptance checklist follow in
Russian below.

## Когда использовать

Для travel-роутеров, когда прямой AWG2 до home должен оставаться основным,
а отдельный VPS должен давать два независимых резерва:

- доступ к домашней LAN через отдельный AWG на UDP/443;
- только резервный Internet через VLESS Reality на TCP/443.

VLESS не заменяет доступ к домашней LAN при полной блокировке UDP. Эти два
резерва устанавливаются и тестируются отдельными фазами.

## Фиксированная топология

| Узел | Интерфейс | Overlay | Site LAN |
|---|---|---:|---:|
| VPS relay | `awg-hub` | `<overlay-cidr>` | — |
| home | `awg3` | `<home-overlay-ip>` | `<home-lan-cidr>` |
| travel router A | `awg2` | `<travel-a-overlay-ip>` | `<travel-a-lan-cidr>` |
| travel router B | `awg2` | `<travel-b-overlay-ip>` | `<travel-b-lan-cidr>` |

Основной туннель и его endpoint не меняются. На VPS TCP/443 Xray не
меняется; AWG слушает только UDP/443. Ни один backup-интерфейс не получает
`0.0.0.0/0` и не меняет default route.

## Политика запуска travel router A

Для travel router A сохраняем двухступенчатый порядок:

1. При старте первым используется прямой AWG2/`awg1` до домашнего роутера.
2. Если прямой канал или его маршрут недоступен, watchdog пытается использовать
   резервный AWG2/`awg2` через выбранный VPS по UDP/443.
3. Обычный Internet не переводится на резервный AWG и не зависит от доступности
   VPS. VLESS Reality остаётся отдельным будущим резервом Internet через TCP/443.
4. После восстановления прямого AWG маршрут возвращается на него после серии
   успешных проверок.

В конкретном развёртывании имена интерфейсов, адреса и состояние watchdog
берутся из свежего read-only inventory. Не переносите live-адреса и aliases в
публичную документацию.

### Что потребуется для более быстрого старта после отказа

- уменьшить интервал первичного keepalive/проверки только после отдельного
  измерения потерь и нагрузки;
- не ждать полного таймаута первого UDP-handshake перед запуском watchdog;
- проверять готовность `awg2` сразу после `ifup` и повторять короткими пробами;
- сохранить текущую защиту от flapping: несколько отказов для переключения и
  несколько успехов для возврата;
- отдельно проверить, что при старте netifd не оставляет старый маршрут через
  `awg1` поверх резервного маршрута.

Эти ускорения ещё не включены в production-политику; сначала нужен отдельный
reboot/failover-тест на выбранном travel router.

## Порядок пилота travel router A

1. Read-only аудит:

   ```bash
   bin/audit-vps-awg-hub.sh --ssh-alias <vps-ssh-alias>
   bin/doctor.sh --router <home-router-alias>
   bin/inspect-travel-router.sh --router <travel-router-alias> --ssh-alias <travel-ssh-alias>
   ```

2. Установить peer-less VPS hub. Сохранить `server_public_key`, `snapshot` и
   напечатанную rollback-команду:

   ```bash
   bin/install-vps-awg-hub.sh --ssh-alias <vps-ssh-alias>
   ```

3. Настроить home `awg3`, затем добавить его public key на VPS:

   ```bash
   bin/configure-backup-awg-client.sh --router <home-router-alias> \
     --interface awg3 --peer-section vps_relay_awg3 \
     --tunnel-ip <home-overlay-ip> --endpoint <vps-public-ip-or-host> \
     --server-public-key PUBLIC_KEY_FROM_STEP_2 \
     --allowed-cidr <overlay-cidr> \
     --allowed-cidr <travel-a-lan-cidr> \
     --allowed-cidr <travel-b-lan-cidr>

   bin/add-vps-awg-peer.sh --ssh-alias <vps-ssh-alias> --peer-name home \
     --peer-public-key PUBLIC_KEY_FROM_HOME --peer-ip <home-overlay-ip> \
     --peer-lan <home-lan-cidr>
   ```

4. Настроить travel router A `awg2`, затем добавить peer и только необходимые межсетевые
   UFW route rules:

   ```bash
   bin/configure-backup-awg-client.sh --router <travel-router-alias> \
     --ssh-alias <travel-ssh-alias> \
     --interface awg2 --peer-section vps_relay_awg2 \
     --tunnel-ip <travel-a-overlay-ip> --endpoint <vps-public-ip-or-host> \
     --server-public-key PUBLIC_KEY_FROM_STEP_2 \
     --allowed-cidr <overlay-cidr> --allowed-cidr <home-lan-cidr>

   bin/add-vps-awg-peer.sh --ssh-alias <vps-ssh-alias> --peer-name travel-a \
     --peer-public-key PUBLIC_KEY_FROM_TRAVEL_A --peer-ip <travel-a-overlay-ip> \
     --peer-lan <travel-a-lan-cidr> --paired-lan <home-lan-cidr>
   ```

5. До watchdog доказать свежие handshakes и MTU 16/512/1200 в обе стороны.

6. Установить watchdog сначала на home, затем на первый travel router. Оба конца нужны, иначе
   при отказе возможна асимметрия маршрутов:

   ```bash
   bin/install-awg-route-failover.sh --router <home-router-alias> \
     --target-cidr <travel-a-lan-cidr> --primary-interface <direct-if> \
     --primary-probe-ip <direct-travel-probe-ip> --backup-interface awg3 \
     --backup-probe-ip <travel-a-overlay-ip>

   bin/install-awg-route-failover.sh --router <travel-router-alias> \
     --ssh-alias <travel-ssh-alias> \
     --target-cidr <home-lan-cidr> --primary-interface <direct-if> \
     --primary-probe-ip <direct-home-probe-ip> --backup-interface awg2 \
     --backup-probe-ip <home-overlay-ip> --target-probe-ip <home-lan-probe-ip>
   ```

   Параметры по умолчанию: проба раз в 10 секунд, 3 ошибки до failover и 3
   успеха до failback. Ожидаемое переключение — примерно 30 секунд и не более
   60 секунд с учётом сетевых таймаутов.

7. Выполнить аварийные тесты travel router A. Перед каждым тестом записывать default route,
   Internet/DNS, активный приватный маршрут, handshake и MemAvailable. Нельзя
   переходить к следующему travel router, пока не пройдены: reboot, блокировка прямого UDP/51821,
   восстановление, недоступность VPS, captive portal, LuCI/SSH и отсутствие
   потери обычного Internet.

8. Только после полного пилота повторить travel/VPS peer шаги для второго
   роутера по адресам из вашей таблицы топологии. Home `awg3` повторно не
   создавать: добавить второй независимый watchdog target с primary и backup probe
   из вашей схемы. Общий procd-сервис запускает по
   отдельному процессу на каждый файл в `/etc/resilient-awg-failover.d/`.

## VLESS Reality reserve Internet

Это отдельная фаза после AWG-пилота. Перед её началом проверь, какой процесс
владеет TCP/443 на выбранном VPS, и не меняй его. Создай отдельные identities
для travel-роутеров, не переиспользуй home identity. Клиент не должен быть постоянно
default route: активация только после доказанной блокировки UDP, с автоматическим
возвратом к обычному WAN. До и после запуска проверить `MemAvailable`; нижний
предел — 20480 KiB. Точный Xray/VLESS профиль нельзя сохранять в repo, журнал
или memory.

## Откат

Команды используют snapshot ID, напечатанные при установке. Откатывать в
обратном порядке: travel watchdog/client, VPS travel peer, home watchdog/client,
VPS home peer, VPS hub.

```bash
bin/remove-resilient-awg.sh --router <travel-router-alias> \
  --ssh-alias <travel-ssh-alias> \
  --interface awg2 --peer-section vps_relay_awg2 \
  --target-cidr <home-lan-cidr> --primary-interface <direct-if>

bin/rollback-vps-awg-peer.sh --ssh-alias <vps-ssh-alias> --snapshot <travel-peer-snapshot>

bin/remove-resilient-awg.sh --router home --interface awg3 \
  --peer-section vps_relay_awg3 --target-cidr <travel-a-lan-cidr> \
  --primary-interface <direct-if>

bin/rollback-vps-awg-peer.sh --ssh-alias <vps-ssh-alias> --snapshot <home-peer-snapshot>
bin/rollback-vps-awg-hub.sh --ssh-alias <vps-ssh-alias> --snapshot <hub-snapshot>
```

Если на home уже настроен второй travel target, удалить только один watchdog
маршрута, сохранив общий `awg3`, нужно той же командой с `--keep-client`.

VPS peer rollback намеренно не удаляет live peer из нового DKMS-модуля: он
сразу удаляет persistent config, route и forwarding, а очистку volatile peer
завершает reboot. Это защита от опубликованных сбоев teardown/removal.

## Критерии готовности

- direct AWG автоматически основной после восстановления;
- backup home access включается не позднее 60 секунд;
- отказ VPS не меняет default route и не ломает обычный Internet;
- после reboot hub, peers и watchdog стартуют автоматически;
- `MemAvailable >= 20480 KiB` на home и всех настроенных travel routers;
- LuCI, SSH, домашняя LAN и MTU 1200 проверены на backup;
- у каждого изменения сохранены snapshot и точная команда отката;
- private keys, VLESS URL/UUID, Reality keys и пароли отсутствуют в repo/log/memory.

## НЕ ДЕЛАТЬ

- не запускать `install-vpn.sh` на travel-профиле;
- не добавлять `0.0.0.0/0` в backup AWG;
- не перезапускать/синхронизировать весь `awg-hub` при добавлении peer;
- не удалять live VPS peer/interface при наличии peer без отдельного reboot-плана;
- не считать VLESS доказательством доступа к домашней LAN при блокировке UDP.
