# Runbook 04 — Добавить LAN HTTP/SOCKS5 proxy

## Когда использовать

Триггеры от пользователя: «пробрось proxy», «хочу curl'ом через VPN», «дай SOCKS5», «открой mixed-inbound на 4002», «хочу отдельный port под node-de».

Pre-conditions:
- `memory/<alias>/state.md` пункты 11, 13, 14 = ✅ (config валиден, tproxy запущен, ≥1 outbound).
- В `memory/<alias>/vpns.md` есть outbound, к которому будем привязывать (включая `auto-failover` как валидный target).

Если нет — отправь на `01-first-time.md`.

## Шаг 1. Что спросить у пользователя

1. **Порт.** Диапазон 4000-4099 (конвенция навыка). Если пользователь не назвал — посмотри `memory/<alias>/proxies.md`, предложи следующий свободный. Если в `proxies.md` пусто — `4000` обычно занят под `auto-failover` (так делает `install-vpn.sh --add-proxy-port 4000`), предложи `4001`.
   - Валидация: целое число 4000..4099.
2. **Outbound (tag).** Покажи пользователю список из `memory/<alias>/vpns.md` + специальный `auto-failover`. Спроси, к какому привязать.
   - Валидация: tag должен присутствовать в `vpns.md` ИЛИ быть строкой `auto-failover`.
3. **Listen IP (опционально).** Default: `192.168.99.1`. Для любого router
   alias сначала сравни default с его актуальным LAN IP; если они отличаются,
   обязательно передай `--listen <lan-ip>`. Никогда не предлагай `0.0.0.0` сам —
   это безопасно только при доказанном WAN firewall.

## Шаг 2. Выполнение

```bash
bin/add-proxy.sh --router <alias> --port <port> --outbound <tag> [--listen <ip>]
```

Что делает:
1. snapshot;
2. добавляет `"mixed"` inbound `tag: in-proxy-<port>`, listen + port;
3. добавляет route rule `inbound: in-proxy-<port> → outbound: <tag>`, размещая ПЕРЕД любым catch-all auto-failover (чтобы explicit-outbound выигрывал);
4. `sing-box check` → staged-apply restart с reachability;
5. обновляет `memory/<alias>/proxies.md` + `journal.md`.

Exit codes:
- `0` — proxy поднят.
- `2` — SSH упал / `config.json` отсутствует. Если отсутствует → `01-first-time.md`.
- `13` — порт вне 4000-4099, или порт уже занят другим inbound'ом, или outbound `<tag>` отсутствует в config. Покажи stderr.
- `20` — rollback (после рестарта sing-box роутер не отвечает). Snapshot восстановлен. Редко, но если случилось — обсуди с пользователем; обычно значит, что конфликт с другим listen'ом.
- `64` — bad CLI args.

## Шаг 3. Подтверждение

Прочитай `memory/<alias>/proxies.md`. Новая строка: `| <port> | <outbound> | claude-code add-proxy | <listen> |`.

## Что обновляется в memory/

- `memory/<alias>/proxies.md` — новая строка.
- `memory/<alias>/journal.md` — событие `add_proxy` (port, outbound, listen, snapshot_before).

## Что сказать пользователю

```
Поднял LAN-proxy:
- Адрес HTTP: http://<router-host>:<port>
- Адрес SOCKS5: socks5h://<router-host>:<port>   (mixed inbound поддерживает оба)
- Outbound: <tag>
- Snapshot до: <snap-id>

Проверка с клиента в LAN:
  curl --proxy http://<router-host>:<port> https://api.ipify.org
  curl --proxy socks5h://<router-host>:<port> https://api.ipify.org

(Должен вернуться IP VPN-сервера, не твой обычный.)
```

Подставь `<router-host>` из `memory/routers.yaml` для этого alias.

## Edge cases / частые ошибки

- **Порт 4000 уже занят `install-vpn --add-proxy-port 4000`** → `add-proxy.sh` вернёт exit 13. Скажи пользователю и предложи следующий свободный.
- **Outbound — это `auto-failover`** → валидно, в config'е это полноценный outbound (`type: urltest`).
- **Пользователь хочет `--listen 0.0.0.0`** → согласись только после явного «да, я понимаю что мой WAN закрыт, и это только для LAN». В противном случае откажи и оставь default.
- **Пользователь хочет port вне 4000-4099** → откажи, объясни конвенцию. Если есть веская причина — escape hatch.

## НЕ ДЕЛАТЬ

- НЕ предлагать `--listen 0.0.0.0` сам.
- НЕ обходить диапазон 4000-4099 без явного запроса.
- НЕ запускать `add-proxy.sh` без предварительной валидации outbound (иначе exit 13, лишний шум).
