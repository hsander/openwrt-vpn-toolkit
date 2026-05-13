#!/usr/bin/env bash
# bin/doctor.sh — probe router state and render memory/<alias>/state.md.
#
# Usage:
#   bin/doctor.sh --router <alias>             # default: probe + render state.md
#   bin/doctor.sh --router <alias> --json      # also dump raw probe JSON to stdout
#   bin/doctor.sh --router <alias> --no-render # probe only, do not write state.md
#
# Exit codes:
#   0  ok
#   2  router not found in registry, OR SSH unreachable
#  64  bad CLI args

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/template-render.sh
. "$SKILL_HOME/lib/template-render.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/doctor.sh --router <alias> [--json] [--quiet] [--no-render]

Зондирует роутер по SSH и обновляет memory/<alias>/state.md.

Options:
  --router <alias>   alias из memory/routers.yaml (обязателен)
  --json             печатать сырой JSON probe'а на stdout
  --quiet            не выводить путь к сгенерированному state.md
  --no-render        только probe, без записи state.md
EOF
  exit 64
}

router=""
emit_json=0
quiet=0
no_render=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="$2"; shift 2 ;;
    --json) emit_json=1; shift ;;
    --quiet) quiet=1; shift ;;
    --no-render) no_render=1; shift ;;
    -h|--help) usage ;;
    *) echo "doctor: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && usage

resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
doctor: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Проверь:
  - роутер включён и в сети
  - ssh ключ установлен: bin/setup-ssh.sh --router $ROUTER_ALIAS
  - пинг проходит: ping -c1 $ROUTER_HOST
EOF
  exit 2
fi

# Probe
probe_json="$(ssh_run_remote < "$SCRIPT_DIR/_doctor_remote.sh")"

if [ "$emit_json" = "1" ]; then
  printf '%s\n' "$probe_json" | jq .
fi

if [ "$no_render" = "1" ]; then
  exit 0
fi

# Ensure non-state memory files exist
render_first_time_memory "$ROUTER_ALIAS" "$ROUTER_HOST"

# Now build state.md by deriving check statuses from the probe JSON.
mkdir -p "$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"

OK="✓"
FAIL="✗"
SKIP="—"
WARN="⚠"

# Extract fields
get() { printf '%s' "$probe_json" | jq -r "$1"; }

# Probe reliability — если jq нет на роутере (или config битый), весь блок
# полей, который требует парсинга JSON (outbounds/rule_set), НЕДОСТОВЕРЕН.
# ВНИМАНИЕ к ловушке jq: `// true` ВЕРНЁТ true для false (alternative-оператор
# срабатывает на null OR false). Используем явный if/has для backward-compat
# со старыми probe-JSON, где поля могло не быть.
probe_reliable="$(printf '%s' "$probe_json" | jq -r 'if has("probe_reliable") then (.probe_reliable | tostring) else "true" end' 2>/dev/null)"
degraded_reasons="$(printf '%s' "$probe_json" | jq -r '(.degraded_reasons // []) | join(", ")' 2>/dev/null)"

openwrt_version="$(get '.openwrt_version')"
openwrt_target="$(get '.openwrt_target')"
arch="$(get '.arch')"
ram_mb="$(get '.ram_mb')"
pkg_mgr="$(get '.package_manager')"

pkg_singbox=$(get '.packages."sing-box"')
pkg_httpsdns=$(get '.packages."https-dns-proxy"')
pkg_nft_tproxy=$(get '.packages."kmod-nft-tproxy"')
pkg_nft_queue=$(get '.packages."kmod-nft-queue"')
pkg_jq=$(get '.packages.jq')

singbox_version="$(get '.singbox_version')"
config_present=$(get '.config.present')
config_valid=$(get '.config.valid')
outbound_count=$(get '.config.outbound_count')
outbound_tags="$(get '.config.outbound_tags')"
has_failover=$(get '.config.has_auto_failover')
rules_present=$(get '.rules.present')
# Новые поля (могут отсутствовать в старом probe — тогда дефолтятся).
rules_count="$(printf '%s' "$probe_json" | jq -r '.rules.count // 0' 2>/dev/null)"
rules_files="$(printf '%s' "$probe_json" | jq -r '(.rules.files // []) | join(", ")' 2>/dev/null)"
tproxy_installed=$(get '.tproxy.installed')
tproxy_running=$(get '.tproxy.running')

peerdns="$(get '.dns.peerdns')"
dnsmasq_server="$(get '.dns.dnsmasq_server')"
httpsdns_port="$(get '.dns.httpsdns_port')"
dns_redirect_present=$(get '.dns.redirect_nft_present')

zapret_installed=$(get '.zapret.installed')
zapret_running=$(get '.zapret.running')
watchdog_conf_present=$(get '.watchdog.conf_present')
watchdog_conf_mode="$(get '.watchdog.conf_mode')"
watchdog_cron_count=$(get '.watchdog.cron_count')
fakeip_cache_present=$(get '.fakeip_cache_present')
skill_state_present=$(get '.skill_state_present')
snapshot_count=$(get '.snapshot_count')
probed_at="$(get '.probed_at')"

bool_to_icon() {
  case "$1" in
    true|True|TRUE) echo "$OK" ;;
    false|False|FALSE) echo "$FAIL" ;;
    *) echo "$SKIP" ;;
  esac
}

# Compose status icons
ssh_key_ok="$OK"; ssh_key_details="доступ есть, $ROUTER_USER@$ROUTER_HOST"
ssh_alias_present=0
if [ -n "$ROUTER_SSH_ALIAS" ] && [ -f "$HOME/.ssh/config" ] && grep -qE "^Host[[:space:]]+$ROUTER_SSH_ALIAS\b" "$HOME/.ssh/config"; then
  ssh_alias_ok="$OK"; ssh_alias_details="Host \`$ROUTER_SSH_ALIAS\` в ~/.ssh/config"
else
  ssh_alias_ok="$FAIL"; ssh_alias_details="нет Host-блока для \`$ROUTER_SSH_ALIAS\` (запусти setup-ssh.sh)"
fi

# OpenWRT version: 24.x+ ok, else fail. SNAPSHOT / dev builds — отдельная ветка.
case "$openwrt_version" in
  24.*|25.*|26.*) openwrt_ok="$OK"; openwrt_details="$openwrt_version ($openwrt_target)" ;;
  SNAPSHOT|snapshot|r[0-9]*)
    openwrt_ok="$OK"; openwrt_details="$openwrt_version ($openwrt_target) — dev/SNAPSHOT, поведение на твой страх и риск" ;;
  *) openwrt_ok="$FAIL"; openwrt_details="$openwrt_version — нужно 24.10+ (apk-based) или SNAPSHOT" ;;
esac

# Arch+RAM
case "$arch" in
  aarch64|x86_64|x86) arch_ok_arch=1 ;;
  *) arch_ok_arch=0 ;;
esac
if [ "$arch_ok_arch" = "1" ] && [ "${ram_mb:-0}" -ge 256 ]; then
  arch_ok="$OK"
else
  arch_ok="$FAIL"
fi
arch_details="$arch, ${ram_mb}MB RAM"

# Packages aggregate
missing_pkgs=""
[ "$pkg_singbox" = "true" ] || missing_pkgs="$missing_pkgs sing-box"
[ "$pkg_httpsdns" = "true" ] || missing_pkgs="$missing_pkgs https-dns-proxy"
[ "$pkg_nft_tproxy" = "true" ] || missing_pkgs="$missing_pkgs kmod-nft-tproxy"
[ "$pkg_nft_queue" = "true" ] || missing_pkgs="$missing_pkgs kmod-nft-queue"
[ "$pkg_jq" = "true" ] || missing_pkgs="$missing_pkgs jq"

if [ -z "$missing_pkgs" ]; then
  packages_ok="$OK"; packages_details="все ($pkg_mgr)"
else
  packages_ok="$FAIL"; packages_details="не хватает:$missing_pkgs"
fi

# sing-box version (>= 1.10)
case "$singbox_version" in
  "") singbox_version_ok="$FAIL"; singbox_version_details="не установлен" ;;
  v1.1[0-9]*|v1.[2-9][0-9]*|v2.*|1.1[0-9]*|1.[2-9][0-9]*|2.*) singbox_version_ok="$OK"; singbox_version_details="$singbox_version" ;;
  *) singbox_version_ok="$FAIL"; singbox_version_details="$singbox_version (нужно ≥1.10 для rule_set v3)" ;;
esac

# https-dns-proxy
if [ "$httpsdns_port" = "5053" ] || [ "$httpsdns_port" = "5054" ]; then
  https_dns_ok="$OK"
else
  https_dns_ok="$FAIL"
fi
https_dns_details="listen_port=$httpsdns_port"

# dnsmasq → 127.0.0.42
if [ "$dnsmasq_server" = "127.0.0.42" ] || echo "$dnsmasq_server" | grep -q "127.0.0.42"; then
  dnsmasq_ok="$OK"
else
  dnsmasq_ok="$FAIL"
fi
dnsmasq_details="server=$dnsmasq_server"

if [ "$peerdns" = "0" ]; then
  peerdns_ok="$OK"
else
  peerdns_ok="$FAIL"
fi
peerdns_details="network.wan.peerdns=$peerdns"

nft_dns_ok="$(bool_to_icon "$dns_redirect_present")"
nft_dns_details="/etc/nftables.d/10-dns-redirect.nft"

singbox_config_ok="$(bool_to_icon "$config_valid")"
if [ "$config_present" = "false" ]; then
  singbox_config_details="config.json отсутствует"
elif [ "$config_valid" = "false" ]; then
  singbox_config_details="config.json есть, но \`sing-box check\` фейлится"
elif [ "$probe_reliable" = "false" ]; then
  singbox_config_ok="$WARN"
  singbox_config_details="config валиден; outbound_count не достоверен — probe degraded ($degraded_reasons)"
else
  singbox_config_details="валиден, outbounds=$outbound_count"
fi

# Row 12: rule-set файлы в /etc/sing-box/rules/. Имена варьируются между установками
# (vpn-domains.json / user-vpn-domains.json / tg-pin-domains.json / pin-*.json),
# поэтому считаем КОЛИЧЕСТВО и показываем список, а не проверяем фиксированное имя.
if [ "${rules_count:-0}" -ge 1 ]; then
  rules_ok="$OK"
  rules_details="$rules_count файл(а): $rules_files"
else
  rules_ok="$FAIL"
  rules_details="нет *.json в /etc/sing-box/rules/"
fi

if [ "$tproxy_running" = "true" ]; then
  tproxy_ok="$OK"; tproxy_details="запущен"
elif [ "$tproxy_installed" = "true" ]; then
  tproxy_ok="$FAIL"; tproxy_details="init.d установлен, но не запущен"
else
  tproxy_ok="$FAIL"; tproxy_details="нет /etc/init.d/sing-box-tproxy"
fi

if [ "$probe_reliable" = "false" ]; then
  # Без надёжного парсинга нельзя утверждать ни "нет outbound'ов", ни их число.
  vpn_outbound_ok="$WARN"
  vpn_outbound_details="probe degraded ($degraded_reasons) — не могу сосчитать outbounds"
elif [ "$has_failover" = "true" ] && [ "${outbound_count:-0}" -ge 2 ]; then
  vpn_outbound_ok="$OK"; vpn_outbound_details="$outbound_count outbounds, есть auto-failover"
elif [ "${outbound_count:-0}" -ge 1 ]; then
  vpn_outbound_ok="$FAIL"; vpn_outbound_details="$outbound_count outbounds, но auto-failover нет"
else
  vpn_outbound_ok="$FAIL"; vpn_outbound_details="нет outbound'ов"
fi

zapret_ok="$(bool_to_icon "$zapret_running")"
if [ "$zapret_installed" = "false" ]; then
  zapret_details="не установлен (опционально)"
elif [ "$zapret_running" = "false" ]; then
  zapret_details="установлен, но не запущен"
else
  zapret_details="работает"
fi

if [ "$watchdog_conf_present" = "true" ] && [ "$watchdog_conf_mode" = "600" ]; then
  watchdog_conf_ok="$OK"; watchdog_conf_details="есть, chmod 600"
elif [ "$watchdog_conf_present" = "true" ]; then
  watchdog_conf_ok="$FAIL"; watchdog_conf_details="есть, но chmod $watchdog_conf_mode (должно быть 600)"
else
  watchdog_conf_ok="$FAIL"; watchdog_conf_details="нет /etc/router-watchdog.conf"
fi

if [ "${watchdog_cron_count:-0}" -ge 1 ]; then
  watchdog_cron_ok="$OK"; watchdog_cron_details="$watchdog_cron_count cron-задач"
else
  watchdog_cron_ok="$FAIL"; watchdog_cron_details="нет cron-задач watchdog"
fi

fakeip_cache_ok="$(bool_to_icon "$fakeip_cache_present")"
fakeip_cache_details="/usr/share/sing-box/cache.db"

skill_state_ok="$(bool_to_icon "$skill_state_present")"
skill_state_details="/etc/vpn-kit/install-state.json"

if [ "${snapshot_count:-0}" -ge 1 ]; then
  first_snapshot_ok="$OK"; first_snapshot_details="$snapshot_count snapshots"
else
  first_snapshot_ok="$FAIL"; first_snapshot_details="ни одного snapshot'а"
fi

# Aggregate "ready"
not_ready=""
[ "$ssh_key_ok" = "$FAIL" ] && not_ready="$not_ready ssh"
[ "$packages_ok" = "$FAIL" ] && not_ready="$not_ready packages"
[ "$singbox_config_ok" = "$FAIL" ] && not_ready="$not_ready sing-box-config"
[ "$tproxy_ok" = "$FAIL" ] && not_ready="$not_ready tproxy"
[ "$vpn_outbound_ok" = "$FAIL" ] && not_ready="$not_ready vpn-outbound"

if [ -z "$not_ready" ]; then
  ready_for_ops="да, базовая работа возможна"
else
  ready_for_ops="нет, не хватает:$not_ready"
fi

# Degraded-probe баннер: если jq нет на роутере / config не парсится, поля
# outbounds/rule_set в probe недостоверны. Это надо показать ВЫШЕ обычного
# резюме, чтобы агент/пользователь не делал выводов из неполной картины.
if [ "$probe_reliable" = "false" ]; then
  degraded_banner="⚠ **Probe degraded:** $degraded_reasons. Поля \`outbound_count\`, \`outbounds_detail\`, \`rule_set_domains\` могут быть **не достоверны**. Не запускай \`adopt.sh\` и не делай выводов «у меня нет VPN» — сначала установи недостающее (для jq: \`ssh $ROUTER_ALIAS 'apk add jq || opkg update && opkg install jq'\`) и перезапусти doctor."
else
  degraded_banner=""
fi

missing_safety=""
[ "$skill_state_ok" = "$FAIL" ] && missing_safety="$missing_safety skill-state"
[ "$first_snapshot_ok" = "$FAIL" ] && missing_safety="$missing_safety snapshots"
[ "$watchdog_conf_ok" = "$FAIL" ] && missing_safety="$missing_safety watchdog-conf"
[ -z "$missing_safety" ] && missing_safety="ничего, всё ок"

# Next steps suggestion
next_steps=""
if [ "$probe_reliable" = "false" ]; then
  # Сначала чиним probe — иначе любые суждения о состоянии будут ложными.
  next_steps="${next_steps}- ⚠ \`ssh $ROUTER_ALIAS 'apk add jq || (opkg update && opkg install jq)'\` — поставить \`jq\` на роутер; затем \`bin/doctor.sh --router $ROUTER_ALIAS\` ещё раз. Без этого probe degraded, и состояние outbounds/rule_set не достоверно.\n"
fi
if [ "$ssh_alias_ok" = "$FAIL" ]; then
  next_steps="${next_steps}- \`bin/setup-ssh.sh --router $ROUTER_ALIAS\` — поставить ssh ключ и alias\n"
fi
if [ "$watchdog_conf_ok" = "$FAIL" ]; then
  next_steps="${next_steps}- \`bin/setup-watchdog.sh --router $ROUTER_ALIAS\` — настроить Telegram-watchdog\n"
fi
# install-vpn.sh имеет смысл предлагать ТОЛЬКО когда мы реально знаем, что
# VPN-outbound отсутствует (probe надёжен). При degraded probe не лезем.
if [ "$probe_reliable" = "true" ] && { [ "$singbox_config_ok" = "$FAIL" ] || [ "$vpn_outbound_ok" = "$FAIL" ]; }; then
  next_steps="${next_steps}- \`bin/install-vpn.sh --router $ROUTER_ALIAS --url 'vless://...'\` — поднять sing-box + VPN с нуля\n"
fi
if [ "$zapret_ok" = "$FAIL" ] && [ "$zapret_installed" = "false" ]; then
  next_steps="${next_steps}- (опц.) zapret для DPI-обхода — пока в скрипте не реализовано, см. \`PROPOSAL.md §13\`\n"
fi
if [ -z "$next_steps" ]; then
  next_steps="Всё базовое настроено. Можно начинать работу: \`bin/add-domain.sh\`, \`bin/add-vpn.sh\` и т.д."
fi

# Count active subnets / pins from local memory MD files. Source of truth для
# обоих файлов — install-state.dynamic_additions[] на роутере, но проще
# посчитать строки таблицы локально, т.к. add-ip.sh / pin-device.sh уже
# рендерят их после CAS-write. Если файла нет (новый роутер до adopt) —
# показываем "—". Считаем только data-rows: исключаем header, separator
# (`|----` / `|:----`) и плейсхолдер `_(пока пусто …)_`.
count_md_table_rows() {
  local md="$1"
  [ -f "$md" ] || { echo "—"; return 0; }
  awk '
    BEGIN { n = 0 }
    /^\|[[:space:]]*-+/ { next }       # separator |---|---|
    /^\|[[:space:]]*:?-+/ { next }     # separator |:---|
    /^\| *IP \/ CIDR / { next }        # subnets header
    /^\| *Source +\| *Scope / { next } # pins header
    /^\| *#? *Header/ { next }
    /^\|.*\(пока пусто/ { next }       # placeholder row
    /^\|/ { n++ }
    END { print n }
  ' "$md"
}

subnets_count="$(count_md_table_rows "$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/subnets.md")"
pins_count="$(count_md_table_rows "$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/pins.md")"

# Build table rows (markdown). Each row: | # | Component | Icon | Details |
state_out="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/state.md"

cat > "$state_out" <<EOF
---
router: $ROUTER_ALIAS
host: $ROUTER_HOST
last_doctor_run: $probed_at
openwrt_version: $openwrt_version
arch: $arch
ram_mb: $ram_mb
revision: 0
---

# State: $ROUTER_ALIAS

Этот файл регенерируется \`bin/doctor.sh --router $ROUTER_ALIAS\`. Ручные правки будут перезаписаны.

## Чек-лист настройки

| # | Компонент | Готово | Детали |
|---|-----------|:------:|--------|
| 1 | SSH-доступ по ключу | $ssh_key_ok | $ssh_key_details |
| 2 | \`~/.ssh/config\` Host-блок | $ssh_alias_ok | $ssh_alias_details |
| 3 | OpenWRT 24.10+ | $openwrt_ok | $openwrt_details |
| 4 | Arch + RAM | $arch_ok | $arch_details |
| 5 | Пакеты установлены | $packages_ok | $packages_details |
| 6 | sing-box ≥1.10 | $singbox_version_ok | $singbox_version_details |
| 7 | \`https-dns-proxy\` на 5053/5054 | $https_dns_ok | $https_dns_details |
| 8 | \`dnsmasq\` → 127.0.0.42 | $dnsmasq_ok | $dnsmasq_details |
| 9 | \`network.wan.peerdns=0\` | $peerdns_ok | $peerdns_details |
| 10 | \`/etc/nftables.d/10-dns-redirect.nft\` | $nft_dns_ok | $nft_dns_details |
| 11 | \`/etc/sing-box/config.json\` валиден | $singbox_config_ok | $singbox_config_details |
| 12 | \`rules/vpn-domains.json\` есть | $rules_ok | $rules_details |
| 13 | \`/etc/init.d/sing-box-tproxy\` запущен | $tproxy_ok | $tproxy_details |
| 14 | ≥1 VPN outbound + auto-failover | $vpn_outbound_ok | $vpn_outbound_details |
| 15 | zapret (опц.) | $zapret_ok | $zapret_details |
| 16 | \`/etc/router-watchdog.conf\` | $watchdog_conf_ok | $watchdog_conf_details |
| 17 | Watchdog в crontab | $watchdog_cron_ok | $watchdog_cron_details |
| 18 | FakeIP cache \`cache.db\` | $fakeip_cache_ok | $fakeip_cache_details |
| 19 | \`/etc/vpn-kit/install-state.json\` | $skill_state_ok | $skill_state_details |
| 20 | Snapshots существуют | $first_snapshot_ok | $first_snapshot_details |

$( [ -n "$degraded_banner" ] && printf '> %s\n' "$degraded_banner" )

## Subnets via VPN

Маршрутизируемые IP/CIDR (nft-сет \`proxy_subnets\` + \`dynamic_additions[].type=="subnet"\`).

- **Активных записей:** $subnets_count
- Источник: [\`subnets.md\`](./subnets.md)
- Управление: \`bin/add-ip.sh\` (V1: \`--via auto\`, IPv4; \`remove-ip.sh\` TBD)

## Pinned LAN clients

Прибитые к конкретному outbound LAN-устройства (\`route.rules[].source_ip_cidr\` + nft tproxy с маркером \`vpn-kit-pin-*\`).

- **Активных pin'ов:** $pins_count
- Источник: [\`pins.md\`](./pins.md)
- Управление: \`bin/pin-device.sh\` (\`unpin-device.sh\` TBD — откат через \`raw-ssh.sh\` или \`restore.sh\`)

## Резюме

- **Готово к работе:** $ready_for_ops
- **Не хватает для safety:** $missing_safety

## Что предложить пользователю

$(printf '%b' "$next_steps")

## Ссылки

- VPN ноды: [\`vpns.md\`](./vpns.md)
- Маршрутизируемые домены: [\`domains.md\`](./domains.md)
- Проксирующие порты: [\`proxies.md\`](./proxies.md)
- Подсети через VPN: [\`subnets.md\`](./subnets.md)
- Pin'ы LAN-клиентов: [\`pins.md\`](./pins.md)
- История изменений: [\`journal.md\`](./journal.md)
- Выученные нюансы: [\`quirks.md\`](./quirks.md)

## Raw probe (для отладки)

\`\`\`json
$(printf '%s' "$probe_json")
\`\`\`
EOF

if [ "$quiet" != "1" ]; then
  echo "doctor: $state_out"
fi
