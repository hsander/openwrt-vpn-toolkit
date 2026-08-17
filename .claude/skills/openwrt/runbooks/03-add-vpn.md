# Runbook 03 — Добавить новую VPN-ноду

## Когда использовать

Триггеры от пользователя: «добавь vpn», «добавь ещё одну ноду», «дай резервный VPN», «провайдер прислал новый vless://», «добавь Германию» (если уже есть Россия).

Pre-conditions (что должно быть в `memory/<alias>/state.md`):
- Пункт 11 «`config.json` валиден» = ✅
- Пункт 13 «tproxy запущен» = ✅
- Пункт 14 «≥1 VPN outbound + auto-failover» = ✅ (минимум одна нода уже есть, auto-failover уже сконфигурирован)

Если что-то из этого `❌` (особенно пункт 14) → НЕ запускай `add-vpn.sh`. Это **первая** установка → отправь на `runbooks/01-first-time.md` (там `install-vpn.sh`, который поднимает sing-box с нуля).

Различие:
- `install-vpn.sh` — сетап с нуля (apk install, DNS chain, init.d).
- `add-vpn.sh` — добавление outbound'а в уже работающий sing-box.

## Шаг 1. Что спросить у пользователя

1. **`vless://...` URL.** Те же предупреждения про секреты, что и в `01-first-time.md` §VPN:
   > Vless-URL содержит UUID и приватные параметры Reality. Вставь его сюда (я не запишу его в memory/journal/git — только парсну локально), либо положи в файл и пришли путь.
2. **`tag` (опционально).** Если пользователь сам предложил — валидация: `a-z0-9_-`, длина 1–32. Если нет — скрипт возьмёт из `#fragment` URL'а или сгенерит `vpn-N`. Можно подсказать пользователю: «По умолчанию tag возьмётся из `#fragment` твоего URL. Если хочешь другое имя — скажи.»
3. **`--add-proxy-port` (опционально).** Спроси: «Поднять для этой ноды отдельный LAN-proxy (mixed-inbound на отдельном порту 4001-4099), чтобы можно было curl'ом дёргать конкретно эту ноду?». Если да — спроси порт или предложи следующий свободный (посмотри в `memory/<alias>/proxies.md`).
4. **В auto-failover?** Default: **да**. Спрашивай только если пользователь явно сказал «не в failover, только как явный outbound». Тогда добавь `--no-add-to-failover`.

### Спец-случай: пользователь принёс не URL, а конфиг-файл
Триггеры: «вот config.json от провайдера», «есть JSON sing-box outbound», «vmess/trojan/shadowsocks/wireguard».

Скажи **дословно**:
> В V1 я поддерживаю только `vless://` URL'ы Reality. Для готового config-файла или других протоколов (vmess/trojan/wireguard) скрипта нет. Варианты: (1) попроси провайдера vless-URL, или (2) можно через escape hatch (`runbooks/99-escape-hatch.md`) — это прямой SSH, требует твоего явного «да».

НЕ конвертируй config.json вручную и НЕ пиши outbound прямо в `config.json` через `raw-ssh.sh` без явного запроса пользователя.

### Спец-случай: подозрительный URL
Если URL **не начинается** с `vless://` (например, `vmess://`, `trojan://`, `ss://`) — `add-vpn.sh` вернёт exit 13 сам, но лучше отказать раньше:
> Это не vless-URL. Скрипт принимает только `vless://...` Reality. См. выше.

## Шаг 2. Выполнение

```bash
bin/add-vpn.sh --router <alias> --url '<url>' [--tag <name>] [--add-proxy-port <port>]
```

Что делает:
1. парсит URL локально (секреты не логируются);
2. snapshot;
3. добавляет outbound в `/etc/sing-box/config.json`;
4. (по умолчанию) добавляет tag в `auto-failover.outbounds` — автоматический failover теперь включает новую ноду;
5. (если zapret2 установлен) добавляет server-IP в ip-exclude (`/opt/zapret2/ipset/zapret-ip-user-exclude.txt`) и рестартит zapret2 — чтобы DPI-десинк не ломал хендшейк туннеля к новому серверу;
6. (если `--add-proxy-port`) добавляет mixed-inbound + route rule;
7. `sing-box check` → staged-apply restart (reachability check каждые 5s, auto-rollback при потере SSH);
8. обновляет `memory/<alias>/vpns.md` (tag, host, port, в-failover, mixed-port) + `proxies.md` (если был port) + `journal.md`.

Exit codes:
- `0` — нода добавлена. Идти к шагу 3.
- `2` — SSH упал, или `config.json` отсутствует (нет sing-box на роутере → отправь на `01-first-time.md`), или server-host уже взят другим outbound'ом с другим tag.
- `13` — URL битый, tag не из `a-z0-9_-`, или порт не из 4000-4099, или порт занят. Покажи stderr.
- `20` — **rollback сработал**: после рестарта sing-box роутер стал недостижим. Snapshot восстановлен, состояние = до операции. Причины: URL рабочий, но провайдер сети режет TCP к серверу; новый Reality-config конфликтует со старым; SNI/pbk перепутан. **НЕ ретраить молча.** Скажи пользователю, попроси проверить URL, предложи `bin/logs.sh --router <alias> --source sing-box --lines 80`.
- `64` — bad CLI args.

## Шаг 3. Подтверждение

Прочитай `memory/<alias>/vpns.md` — должна появиться новая строка в таблице. **Убедись, что в строке НЕТ UUID/pbk/sid/server_name** (этих полей в шаблоне нет, но проверь). Если есть — это баг, не показывай пользователю содержимое; вызови `bin/doctor.sh --router <alias>` (он восстановит файл из реального probe).

Если был `--add-proxy-port` — прочитай `memory/<alias>/proxies.md`, там новая строка `<port> | <tag> | … | <listen>`.

## Что обновляется в memory/

- `memory/<alias>/vpns.md` — новая строка (tag, host, port, в-failover, mixed-port).
- `memory/<alias>/proxies.md` — новая строка, если `--add-proxy-port`.
- `memory/<alias>/state.md` — пункт 14 «`VPN outbound + auto-failover`» подсветится с обновлённым счётчиком нод.
- `memory/<alias>/journal.md` — событие `add_vpn` с tag, host:port, в-failover, snapshot_before.

Секреты (uuid, private_key, public_key, short_id, server_name) **не пишутся** в memory — только в `/etc/sing-box/config.json` на роутере.

## Что сказать пользователю

```
Добавил VPN-ноду:
- tag: <tag>
- сервер: <host>:<port>
- В auto-failover: yes (или no, если --no-add-to-failover)
- LAN proxy: http://<router-host>:<port>  (если был --add-proxy-port)
- Snapshot до: <snap-id>

Что произошло:
- Outbound добавлен в /etc/sing-box/config.json
- (если zapret2 стоит) Server-IP в ip-exclude zapret2 — десинк не трогает туннель
- sing-box перезапущен (staged-apply, reachability OK)

Откатить: «откати к <snap-id>».
```

## Edge cases / частые ошибки

- **Tag совпадает с существующим** → скрипт откажет (exit 13), кроме случая `--force` (но `--force` не используй сам, спроси пользователя).
- **Server host совпадает с существующим outbound'ом** (один и тот же VPS, два разных порта/UUID) → скрипт пропустит (это валидно), но zapret2 ip-exclude уже знает этот IP — повторная строка не добавляется (идемпотентно).
- **Auto-failover пустой / отсутствует** → state.md пункт 14 должен быть `❌`, отправь на `01-first-time.md`.
- **`--add-proxy-port` использует фиксированный listen `192.168.99.1`.** Это
  соответствует текущему home-LAN навыка. Для другого роутера или адреса сначала
  используй отдельный `add-proxy.sh --listen <lan-ip>`; не обещай, что встроенный
  proxy-флаг `add-vpn.sh` автоматически определяет LAN.
- **Exit 20 на staged-apply** → не делай retry. Snapshot восстановлен, выясняй причину через `logs.sh` или escape hatch.

## НЕ ДЕЛАТЬ

- НЕ записывать `vless://`-URL в чат-сводку, в `vpns.md`, в `journal.md`. Шаблоны в этих файлах не содержат места для секретов — если ты собираешься записать туда URL, ты делаешь что-то не так.
- НЕ обходить «vless-only» ограничение через escape hatch без явного запроса пользователя.
- НЕ запускать `--force` без явного согласия пользователя.
- НЕ делать ретрай после exit 20.
- НЕ предполагать, что zapret2 установлен — `add-vpn.sh` сам проверит (`/etc/init.d/zapret2`) и добавит IP в ip-exclude только если zapret2 есть.
