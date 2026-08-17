# Runbook 09 — Country-pool routing

## Концепция

Страна = единица маршрутизации. Ноды одной страны объединяются в urltest-пул
(`usa-pool`, `pl-pool`, `sg-pool`). `auto-failover` = urltest над пулами.
Failover происходит **внутри страны** — между нодами одной страны, не между странами.

```
auto-failover
  ├── usa-pool  (node-us-a, node-us-b)
  ├── pl-pool   (node-pl-a)
  └── sg-pool   (node-sg-a)
```

## Реестр countries.yaml

Файл: `memory/<alias>/countries.yaml`

```yaml
version: 1
countries:
  usa:
    pool: usa-pool
    nodes: [node-us-a, node-us-b]
  pl:
    pool: pl-pool
    nodes: [node-pl-a]
  sg:
    pool: sg-pool
    nodes: [node-sg-a]
aliases:
  us: usa
  poland: pl
  singapore: sg
```

Обновляется вручную или через `add-vpn.sh --country`.

## Частые сценарии

### Добавить домен через страну

```bash
bin/add-domain.sh --router home --domain example.com --outbound usa
# → user-usa-pool-domains.json, route → usa-pool
```

### Привязать устройство к стране

```bash
bin/pin-device.sh --router <router-alias> --source-ip <lan-client-ip> --outbound usa
# → route.rules: source_ip_cidr → usa-pool
```

### Локальный прокси на страну

```bash
bin/add-proxy.sh --router <router-alias> --port 4010 --outbound usa
# → mixed inbound :4010 → usa-pool
```

### Добавить VPN-ноду в страну

```bash
bin/add-vpn.sh --router <router-alias> --url "vless://..." --tag node-us-new --country usa
# → нода в config + usa-pool.outbounds += [usa-new]
# → auto-failover не меняется (usa-pool уже там)
```

### Привязка к конкретной ноде (backward-compat)

```bash
bin/add-domain.sh --router <router-alias> --domain example.com --outbound node-us-a
# → user-node-us-a-domains.json, route → node-us-a (конкретная нода, без pool failover)
```

## Добавить новую страну

1. Добавить VPN-ноду: `bin/add-vpn.sh --router <router-alias> --url "vless://..." --country de`
   - Скрипт создаст `de-pool` urltest и добавит его в `auto-failover`
2. Обновить `memory/home/countries.yaml` вручную — добавить секцию `de`
3. Проверить: `ssh home-router 'jq ".outbounds[] | select(.tag == \"de-pool\")" /etc/sing-box/config.json'`

## Удалить ноду из пула

```bash
bin/remove-pool-members.sh --router <router-alias> --pool usa-pool --member node-us-b
# Несколько нод удаляются атомарно повторением --member.
# Outbound-конфигурации и route rules сохраняются.
# Если после удаления pool станет пустым → exit 13.
```

Если требуется удалить сам VPN-outbound вместе с его proxy/rules, используй
`bin/remove-vpn.sh --router <router-alias> --tag node-us-b`.

## Диагностика

```bash
# Проверить пулы на роутере
ssh home-router 'jq "[.outbounds[] | select(.type == \"urltest\") | {tag, outbounds}]" /etc/sing-box/config.json'

# Проверить текущий countries.yaml
cat memory/home/countries.yaml

# Тест резолвера
. lib/country-resolve.sh
resolve_country_to_pool home usa  # → usa-pool
resolve_country_to_pool home us   # → usa-pool
resolve_country_to_pool <router-alias> node-us-a  # → node-us-a (без изменений)
```

## Заметки

- `--outbound usa` и `--outbound node-us-a` создают разные rule-set файлы: `user-usa-pool-domains.json` и `user-node-us-a-domains.json`. Домены в них не пересекаются.
- HTTP outbounds, если они есть, не входят в пул — в пул добавляются только совместимые VLESS-ноды.
- `resolve_country_to_pool` — pure bash/awk, без SSH, без jq. Неизвестный input проходит без изменений (exit 0).
