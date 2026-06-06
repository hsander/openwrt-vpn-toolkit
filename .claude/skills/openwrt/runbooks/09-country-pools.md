# Runbook 09 — Country-pool routing

## Концепция

Страна = единица маршрутизации. Ноды одной страны объединяются в urltest-пул
(`usa-pool`, `pl-pool`, `sg-pool`). `auto-failover` = urltest над пулами.
Failover происходит **внутри страны** — между нодами одной страны, не между странами.

```
auto-failover
  ├── usa-pool  (usa-4, usa-6-dev, usa-4-crip)
  ├── pl-pool   (polsha)
  └── sg-pool   (redshield-sg)
```

## Реестр countries.yaml

Файл: `memory/<alias>/countries.yaml`

```yaml
version: 1
countries:
  usa:
    pool: usa-pool
    nodes: [usa-4, usa-6-dev, usa-4-crip]
  pl:
    pool: pl-pool
    nodes: [polsha]
  sg:
    pool: sg-pool
    nodes: [redshield-sg]
aliases:
  us: usa
  poland: pl
  polsha: pl
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
bin/pin-device.sh --router home --source-ip 192.168.1.x --outbound usa
# → route.rules: source_ip_cidr → usa-pool
```

### Локальный прокси на страну

```bash
bin/add-proxy.sh --router home --port 4010 --outbound usa
# → mixed inbound :4010 → usa-pool
```

### Добавить VPN-ноду в страну

```bash
bin/add-vpn.sh --router home --url "vless://..." --tag usa-new --country usa
# → нода в config + usa-pool.outbounds += [usa-new]
# → auto-failover не меняется (usa-pool уже там)
```

### Привязка к конкретной ноде (backward-compat)

```bash
bin/add-domain.sh --router home --domain example.com --outbound usa-4
# → user-usa-4-domains.json, route → usa-4 (конкретная нода, без pool failover)
```

## Добавить новую страну

1. Добавить VPN-ноду: `bin/add-vpn.sh --router home --url "vless://..." --country de`
   - Скрипт создаст `de-pool` urltest и добавит его в `auto-failover`
2. Обновить `memory/home/countries.yaml` вручную — добавить секцию `de`
3. Проверить: `ssh home-router 'jq ".outbounds[] | select(.tag == \"de-pool\")" /etc/sing-box/config.json'`

## Удалить ноду из пула

```bash
bin/remove-vpn.sh --router home --tag usa-6-dev
# Если usa-6-dev — последняя нода в usa-pool → exit 13
# Для принудительного удаления:
bin/remove-vpn.sh --router home --tag usa-6-dev --force-orphan
# → usa-pool удалится из config; auto-failover потеряет usa-pool
```

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
resolve_country_to_pool home usa-4  # → usa-4 (без изменений)
```

## Заметки

- `--outbound usa` и `--outbound usa-4` создают разные rule-set файлы: `user-usa-pool-domains.json` и `user-usa-4-domains.json`. Домены в них не пересекаются.
- `polsha-proxy` (http outbound) не входит ни в один пул — только VLESS-ноды.
- `resolve_country_to_pool` — pure bash/awk, без SSH, без jq. Неизвестный input проходит без изменений (exit 0).
