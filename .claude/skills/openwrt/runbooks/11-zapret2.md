# Runbook 11 — zapret2: установка, стратегия, подбор

## Когда использовать

Триггеры: «поставь zapret», «настрой обход DPI», «не работает YouTube даже с VPN»,
«подбери стратегию zapret», «заработал ли youtube через zapret», упоминание
`nfqws2` / `blockcheck2` / «стратегия запрета».

zapret2 нужен, когда провайдер режет сайты по DPI (SNI), а заворачивать их в VPN
не хочется (например, YouTube — много трафика, VPN-нода не тянет). Если пользователь
готов пустить домен через VPN — это `runbooks/02-add-domain.md`, zapret2 не нужен.

## ⚠ Главное, что нужно знать заранее

1. **Навык не ставит zapret v1 (bol-van).** Канонический пакет — **zapret2** (remittor,
   Lua-стратегии, бинарь `nfqws2`). Все пути — `/opt/zapret2/...`, init `/etc/init.d/zapret2`.
2. **zapret2 ставится вручную (escape hatch).** Контрактных `bin/*` скриптов под
   установку/смену стратегии нет. Все шаги ниже — через `bin/raw-ssh.sh` (с явным
   подтверждением пользователя, см. `runbooks/99-escape-hatch.md`).
3. **Стратегия читается из `/opt/zapret2/config`, строка `NFQWS2_OPT="..."` — НЕ из uci.**
   Правки `uci set zapret2.config.NFQWS2_OPT` ИГНОРИРУЮТСЯ init-скриптом. Это главная
   ловушка: десяток «применений» через uci не дают эффекта, nfqws2 крутит старую
   стратегию. Менять — только через файл `/opt/zapret2/config`.

## Шаг 0. Проверка состояния

```bash
bin/doctor.sh --router <alias> --json | jq '.zapret'
```
- `installed=false` → переходи к Шагу 1 (установка).
- `installed=true, running=true` → zapret2 уже стоит, переходи к Шагу 3 (стратегия) или 4 (подбор).

## Шаг 1. Установка zapret2 (remittor)

На свежем роутере **сначала проверь дату** — сбитый RTC ломает SSL у apk/curl:
```bash
date
# если дата неверная:
ntpd -q -p pool.ntp.org
```

Установка пакета:
```bash
curl -fsSL https://raw.githubusercontent.com/remittor/zapret-openwrt/zap1/zapret/update-pkg.sh -o /tmp/zap.sh
sh /tmp/zap.sh -u 2
```
(`-u 2` = установить zapret**2**, а не v1)

Проверка:
```bash
ls /opt/zapret2/nfq2/nfqws2 /etc/init.d/zapret2
/etc/init.d/zapret2 enable
```

## Шаг 2. Базовая настройка

1. **Режим фильтрации** — по hostlist:
   ```bash
   # в /opt/zapret2/config:  MODE_FILTER=hostlist
   ```
2. **Домены** в user-hostlist `/opt/zapret2/ipset/zapret-hosts-user.txt` (по строке):
   ```
   youtube.com
   www.youtube.com
   googlevideo.com
   ytimg.com
   youtu.be
   ```
3. **Исключения VPN-серверов** — IP нод в `/opt/zapret2/ipset/zapret-ip-user-exclude.txt`
   (чтобы десинк не ломал туннель). Это делается автоматически в `bin/add-vpn.sh` /
   `bin/remove-vpn.sh` — руками трогать не нужно.

## Шаг 3. Применить дефолтную стратегию (рабочую)

Дефолт — `tcpseg` (проверен на стенде test1, DPI = SNI silent-drop). Полная строка
и кандидаты — `templates/zapret/zapret2-strategy.md`.

**Как менять стратегию правильно** (awk-замена строки `NFQWS2_OPT` + restart):
```sh
NEW=' --comment=Strategy__yt_tcpseg --filter-tcp=80 --filter-l7=http <HOSTLIST> --payload=http_req --lua-desync=multisplit:pos=method+2 --new --filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=tcpseg:pos=0,1:ip_id=rnd:repeats=1 --new --filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6'
awk -v new="NFQWS2_OPT=\"$NEW\"" '/^NFQWS2_OPT=/{print new; next} {print}' \
  /opt/zapret2/config > /tmp/cfg.new && mv /tmp/cfg.new /opt/zapret2/config
/etc/init.d/zapret2 restart
```

**Обязательно проверь, ЧТО реально запущено** (не доверяй факту правки файла):
```sh
cat /proc/$(pgrep -f nfq2/nfqws2 | head -1)/cmdline | tr '\0' ' ' | grep -oE 'Strategy__[^ ]*|tcpseg[^ ]*'
```
Должно показать `Strategy__yt_tcpseg` и `tcpseg:...`. Если показывает `Strategy__default`
— restart не подхватил файл, повтори (иногда нужен полный stop→start).

### Проверка, что заработало (с форвард-клиента!)

Тестировать надо с **клиента ЗА роутером**, а не с самого роутера (см. Шаг 4, нюанс
OUTPUT-vs-FORWARD). На test1 это home-server через WiFi-интерфейс:
```bash
curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" --max-time 12 \
  --interface <client-iface> https://www.youtube.com/
```
`200/204/30x` = работает. `000`/таймаут = блок, пробуй другую стратегию (Шаг 4).

## Шаг 4. Подбор стратегии под другого провайдера (blockcheck2)

Если дефолт не сработал — `blockcheck2.sh` гоняет десятки стратегий против живого DPI.

```sh
/etc/init.d/zapret2 stop    # чтобы не мешал тесту
BATCH=1 DOMAINS="www.youtube.com" IPVS=4 \
  ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=0 ENABLE_HTTPS_TLS13=1 ENABLE_HTTP3=0 \
  SCANLEVEL=standard REPEATS=2 CURL_MAX_TIME=4 \
  sh /opt/zapret2/blockcheck2.sh 2>&1 | tee /tmp/bc.log
# рабочие стратегии:
grep -B3 '!!!!! AVAILABLE' /tmp/bc.log | grep -oE 'nfqws2 --.*' | sort -u
```

### ⚠ Критичные нюансы blockcheck2

1. **blockcheck2 тестирует ТОЛЬКО router-local (OUTPUT) путь.** Он ставит
   `predefrag`-цепочку на hook `output` с `notrack` — а это работает лишь для
   OUTPUT, не для FORWARD. Поэтому его «AVAILABLE» НЕ гарантирует работу на
   форвард-клиенте. **Всегда** проверяй найденную стратегию реальным curl'ом с
   клиента за роутером (Шаг 3).
2. **blockcheck2 оставляет хвосты.** После него остаются живые `nfqws2` с чужим
   qnum и nft-таблицы `blockcheckNNNNN`, которые шэдоят production-трафик и ломают
   всё. Обязательно вычистить:
   ```sh
   for t in $(nft list tables 2>/dev/null | awk '/blockcheck/{print $NF}'); do nft delete table inet "$t"; done
   for p in $(pgrep -f 'nfq2/nfqws2'); do kill "$p"; done   # затем /etc/init.d/zapret2 start
   ```
3. Применять найденную стратегию — через Шаг 3 (awk-замена в `/opt/zapret2/config`).

## Шаг 5. Зафиксировать результат в memory

Рабочую стратегию записать в `memory/<alias>/quirks.md`:
- секция ISP: тип DPI + строка `Working zapret strategy`.
- секция zapret2: полная строка `NFQWS2_OPT`.

(Образец — `memory/test1/quirks.md`, там уже разобран реальный кейс.)

## Что обновляется в memory/

- `memory/<alias>/quirks.md` — стратегия + тип DPI (агент пишет руками, append-секцией).
- `memory/<alias>/journal.md` — события `raw_ssh_session` (т.к. всё шло через escape hatch).
- `memory/<alias>/state.md` — перерендерить `bin/doctor.sh` после установки (пункт 15 zapret2).

## Что сказать пользователю (шаблон)

```
zapret2 на <alias>: [установлен / стратегия применена].
- Стратегия: <label> (TLS: tcpseg:pos=0,1)
- Проверка с клиента за роутером: youtube.com → <code> за <time>s
- Записал в memory/<alias>/quirks.md (стратегия + тип DPI)
[если подбирал]: blockcheck2 нашёл рабочую стратегию, проверил на форвард-клиенте, хвосты вычистил.
```

## Edge cases / частые ошибки

- **«Поменял стратегию, а ничего не изменилось»** → почти всегда правка ушла в uci,
  а не в `/opt/zapret2/config`. Проверь `/proc/.../cmdline` (Шаг 3).
- **«Сломался весь трафик после blockcheck2»** → хвостовые nft-таблицы/nfqws2,
  см. Шаг 4 нюанс 2.
- **«Работает с роутера, но не у клиента»** → OUTPUT-vs-FORWARD, см. Шаг 4 нюанс 1.
- **VPN-туннель к новой ноде отвалился после установки zapret2** → IP ноды не в
  `zapret-ip-user-exclude.txt`. `bin/add-vpn.sh` добавляет автоматически; если нода
  ставилась до zapret2 — перезапусти `bin/add-vpn.sh` или добавь IP руками.
- **QUIC-блок** → если UDP/443 режется, дефолт уже форсит fake QUIC; можно вовсе
  отключить QUIC у клиента, чтобы форсить TCP-путь.

## НЕ ДЕЛАТЬ

- **НЕ менять стратегию через `uci set`** — это не работает. Только `/opt/zapret2/config`.
- **НЕ оставлять хвосты blockcheck2** — вычищай nft-таблицы и stray nfqws2 после подбора.
- **НЕ доверять «AVAILABLE» от blockcheck2 без проверки на форвард-клиенте.**
- **НЕ трогать LAN/WAN-топологию ради теста** — для проверки нужен клиент за роутером,
  а не смена адресов (на test1 смена LAN однажды привела к потере доступа).
- **НЕ ставить zapret v1** (`sh zap.sh -u` без `2`, или git clone bol-van) — навык на zapret2.
