#!/usr/bin/env bash
# bin/adopt.sh — sync agent-side memory with the real state of an already-
# configured router. Read-only on the router side; only takes a baseline
# snapshot and reads /etc/sing-box/config.json without writing to it.
#
# Когда вызывать (см. runbooks/06-adopt-existing.md):
#   - sing-box уже настроен на роутере вручную или другим инструментом
#   - install-vpn.sh упал с preflight-fail 'existing-sing-box-config-not-owned'
#   - пользователь руками правил config.json и хочет ресинхронизировать memory
#
# Что делает:
#   1. resolve_router_config + ssh alive check
#   2. mandatory baseline snapshot (bin/backup-now.sh)
#   3. probe (bin/doctor.sh --json --no-render) + рендер state.md (bin/doctor.sh)
#   4. force-render memory/<alias>/{vpns,domains,proxies}.md из реального
#      состояния (outbounds_detail / inbounds_detail / rule_set_domains
#      в probe JSON — без секретов)
#   5. journal event adopted_existing_setup
#
# Чего НЕ делает:
#   - НЕ устанавливает пакеты, не запускает/перезапускает сервисы
#   - НЕ модифицирует sing-box config, firewall, init.d на роутере
#   - НЕ читает секреты (uuid/pbk/sid/password/private_key) из config — probe их
#     не эмитит, и adopt.sh их не запрашивает
#   - НЕ пишет /etc/vpn-kit/install-state.json на роутер. Это значит install-vpn.sh
#     по-прежнему откажется bootstrap'ить такой роутер (preflight видит config без
#     install-state). Но add-vpn/add-domain/add-proxy работают независимо — они
#     не проверяют install-state. Создание install-state с source=adopt — TODO v1.1.
#
# Usage:
#   bin/adopt.sh --router <alias> [--writer <id>] [--quiet]
#
# Exit codes:
#   0   ok
#   2   router not found / SSH unreachable / backup-now failed / doctor probe failed
#  13   validation error (writer id, journal append)
#  64   bad CLI args

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"
# shellcheck source=../lib/template-render.sh
. "$SKILL_HOME/lib/template-render.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/adopt.sh --router <alias> [--writer <id>] [--quiet]

Адоптирует уже настроенный роутер: baseline snapshot + probe + рендер memory
из реального состояния /etc/sing-box/config.json. Не модифицирует роутер.

Options:
  --router <alias>   alias из memory/routers.yaml (обязателен)
  --writer <id>      writer ID (по умолчанию claude-code@adopt-<unix-ts>)
  --quiet            не печатать summary в stderr
EOF
  exit 64
}

router=""
writer=""
quiet=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --writer) writer="${2:-}"; shift 2 ;;
    --quiet)  quiet=1; shift ;;
    -h|--help) usage ;;
    *) echo "adopt: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "adopt: --router обязателен" >&2; usage; }
[ -z "$writer" ] && writer="claude-code@adopt-$(date +%s)"

# --- 1. Resolve router + SSH alive --------------------------------------------
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
adopt: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Сначала: bin/setup-ssh.sh --router $ROUTER_ALIAS --host $ROUTER_HOST
EOF
  exit 2
fi

# Гарантируем существование memory/<alias>/ с базовыми шаблонами
# (render_first_time_memory скипает существующие — мы потом перерендерим
# vpns/domains/proxies из probe явно через render_template).
render_first_time_memory "$ROUTER_ALIAS" "$ROUTER_HOST"

mem_dir="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"
mkdir -p "$mem_dir"

# --- 2. Baseline snapshot (MANDATORY) ------------------------------------------
# Snapshot ДО любого чтения — даже если adopt.sh ничего не пишет на роутер,
# baseline нужен на случай если пользователь сразу запустит add-domain/add-vpn
# (или просто чтобы был safety net перед первым касанием).

if [ ! -x "$SCRIPT_DIR/backup-now.sh" ]; then
  echo "adopt: bin/backup-now.sh не найден или не executable — без baseline'а adopt отказывается продолжать." >&2
  exit 2
fi

[ "$quiet" = "1" ] || echo "adopt: snapshot роутера ДО adopt (baseline)..." >&2
snapshot_label=""
if snapshot_out="$("$SCRIPT_DIR/backup-now.sh" --router "$ROUTER_ALIAS" --label "before adopt" --quiet 2>&1)"; then
  snapshot_label="$(printf '%s' "$snapshot_out" | grep -oE '^snap-[0-9TZ]+' | tail -1 || true)"
  if [ -z "$snapshot_label" ]; then
    echo "adopt: backup-now.sh не вернул snap-ID — отказываюсь продолжать без baseline." >&2
    printf '%s\n' "$snapshot_out" | head -10 >&2
    exit 2
  fi
  [ "$quiet" = "1" ] || echo "adopt: baseline snapshot = $snapshot_label" >&2
else
  echo "adopt: backup-now.sh упал — продолжать без baseline нельзя." >&2
  printf '%s\n' "$snapshot_out" | head -10 >&2
  exit 2
fi

# --- 3. Probe + render state.md ------------------------------------------------

if [ ! -x "$SCRIPT_DIR/doctor.sh" ]; then
  echo "adopt: bin/doctor.sh не найден — не могу probe'ить роутер." >&2
  exit 2
fi

[ "$quiet" = "1" ] || echo "adopt: probe роутера (doctor.sh --json --no-render)..." >&2
probe_json=""
if ! probe_json="$("$SCRIPT_DIR/doctor.sh" --router "$ROUTER_ALIAS" --json --no-render --quiet 2>/dev/null)"; then
  echo "adopt: doctor.sh упал на probe'е роутера." >&2
  exit 2
fi

# Sanity-check: probe JSON должен парситься.
if ! printf '%s' "$probe_json" | jq -e . >/dev/null 2>&1; then
  echo "adopt: probe вернул невалидный JSON." >&2
  exit 2
fi

# Hard guard: при degraded probe (jq-missing-on-router / config-json-unparseable)
# поля outbounds_detail/inbounds_detail/rule_set_domains в probe = [] не потому
# что их РЕАЛЬНО нет, а потому что мы не смогли распарсить config.json. Записать
# memory из такого probe — значит подсунуть агенту ложную картину (это и
# случалось до этого фикса). Лучше отказаться явно, чем создать silent failure.
probe_reliable_raw="$(printf '%s' "$probe_json" | jq -r 'if has("probe_reliable") then (.probe_reliable | tostring) else "true" end' 2>/dev/null)"
if [ "$probe_reliable_raw" = "false" ]; then
  degraded_list="$(printf '%s' "$probe_json" | jq -r '(.degraded_reasons // []) | join(", ")' 2>/dev/null)"
  cat >&2 <<EOF
adopt: ОТКАЗ — probe degraded ($degraded_list).

При degraded probe скрипт не может надёжно прочитать /etc/sing-box/config.json,
и память (vpns.md/domains.md/proxies.md) будет ложной — это уже ломало нас
раньше. Чтобы пройти дальше:

  1. Установи jq на роутер:
       ssh $ROUTER_ALIAS 'apk add jq || (opkg update && opkg install jq)'
  2. Перезапусти adopt:
       bin/adopt.sh --router $ROUTER_ALIAS

state.md уже отрендерен через doctor.sh (помечен ⚠), но vpns/domains/proxies
оставлены нетронутыми до того, как probe станет надёжным.
EOF
  exit 2
fi

# Render state.md через doctor.sh (без --no-render). doctor.sh снова дёрнет
# probe — это лишний раунд по ssh, но даёт нам бесплатно rich state.md без
# дублирования кода. Альтернатива — экспортировать render-логику в lib/.
[ "$quiet" = "1" ] || echo "adopt: рендерю state.md..." >&2
"$SCRIPT_DIR/doctor.sh" --router "$ROUTER_ALIAS" --quiet >/dev/null 2>&1 || {
  echo "adopt: doctor.sh упал при рендере state.md (некритично, продолжаю)." >&2
}

# --- 4. Extract probe fields (без секретов — _doctor_remote.sh их не эмитит) ---

j() { printf '%s' "$probe_json" | jq -r "$1" 2>/dev/null || printf ''; }

outbounds_detail="$(j '.outbounds_detail // []')"
inbounds_detail="$(j '.inbounds_detail // []')"
rule_set_domains="$(j '.rule_set_domains // []')"

config_present="$(j '.config.present')"
[ "$config_present" = "true" ] && config_present_str="1" || config_present_str="0"

# rollback_runtime presence — probe не эмитит явно; считаем по install-state.
rollback_runtime_present_str="0"
if printf '%s' "$probe_json" | jq -e '.install_state.present == true' >/dev/null 2>&1; then
  rollback_runtime_present_str="1"
fi

outbounds_count="$(printf '%s' "$outbounds_detail" | jq 'length')"
inbounds_count="$(printf '%s' "$inbounds_detail" | jq 'length')"
domains_count="$(printf '%s' "$rule_set_domains" | jq 'length')"

# --- 5. Render memory/<alias>/{vpns,domains,proxies}.md из реального state -----

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Helper: filter out non-VPN outbound types (direct/block/dns/selector/urltest).
# selector/urltest — это auto-failover wrappers; их участников показываем отдельно.
vpn_outbounds="$(printf '%s' "$outbounds_detail" | jq -c '
  map(select(.type as $t | $t != "direct" and $t != "block" and $t != "dns" and $t != "selector" and $t != "urltest"))
')"

# vpns.md — таблица: | Tag | Тип | Host:port | Регион | В auto-failover | Mixed-port |
build_vpn_rows() {
  if [ "$(printf '%s' "$vpn_outbounds" | jq 'length')" = "0" ]; then
    printf '_(пусто — нет VPN outbound в /etc/sing-box/config.json)_\n'
    return
  fi
  printf '%s' "$vpn_outbounds" | jq -r '
    .[] |
    "| " + (.tag // "?") +
    " | " + (.type // "?") +
    " | " + ((.server // "?") + ":" + ((.server_port // 0) | tostring)) +
    " | _?_ | _?_ | _?_ |"
  '
}

# Failover info — выудим из selector/urltest outbound если есть.
failover_block="$(printf '%s' "$outbounds_detail" | jq -c '
  map(select(.type == "selector" or .type == "urltest")) | .[0] // null
')"

failover_tags="_?_"
failover_url="_?_"
failover_interval="_?_"
failover_tolerance="_?_"
if [ "$failover_block" != "null" ]; then
  # selector/urltest outbounds в probe сейчас несут только tag/type/server/port.
  # Полный список outbounds внутри (массив) probe не эмитит — это требует
  # отдельного расширения _doctor_remote.sh. Пока ставим placeholder.
  failover_tags="(см. /etc/sing-box/config.json на роутере; probe пока не эмитит outbounds для selector/urltest)"
fi

# domains.md — таблица: | Домен | Outbound | Когда добавлен | Кем |
build_domain_rows() {
  if [ "$domains_count" = "0" ]; then
    printf '_(пусто — нет доменов в route.rules / route.rule_set)_\n'
    return
  fi
  printf '%s' "$rule_set_domains" | jq -r '
    .[] | "| " + . + " | _?_ (probe не эмитит outbound mapping) | adopted | external |"
  '
}

# proxies.md — таблица: | Port | Outbound | Назначение | Listen IP |
build_proxy_rows() {
  if [ "$inbounds_count" = "0" ]; then
    printf '_(пусто — нет LAN proxy inbound mixed/socks/http)_\n'
    return
  fi
  printf '%s' "$inbounds_detail" | jq -r '
    .[] |
    "| " + ((.listen_port // 0) | tostring) +
    " | _?_ | adopted (" + (.type // "?") + ") | " + (.listen // "?") + " |"
  '
}

vpn_rows="$(build_vpn_rows)"
domain_rows="$(build_domain_rows)"
proxy_rows="$(build_proxy_rows)"

# Force-render: render_template создаёт файлы, перезаписывая существующие.
# Это сознательно — adopt = «реальное состояние теперь источник правды для memory».

# Перед перезаписью — если файлы уже были, делаем .bak для безопасности.
for f in vpns.md domains.md proxies.md; do
  [ -f "$mem_dir/$f" ] && cp "$mem_dir/$f" "$mem_dir/.$f.pre-adopt.bak" || true
done

render_template "$SKILL_HOME/memory/_templates/vpns.md" "$mem_dir/vpns.md" \
  "ROUTER_ALIAS=$ROUTER_ALIAS" \
  "LAST_UPDATED_ISO=$now_iso" \
  "VPN_TABLE_ROWS=$vpn_rows" \
  "FAILOVER_TAGS=$failover_tags" \
  "FAILOVER_INTERVAL=$failover_interval" \
  "FAILOVER_URL=$failover_url" \
  "FAILOVER_TOLERANCE=$failover_tolerance" \
  "NOTES=Adopted from existing setup on $now_iso. Probe видит outbounds/inbounds, но не маппинг outbound→inbound и не внутренние outbounds selector/urltest. Уточнения — через bin/raw-ssh.sh с явным подтверждением (см. SKILL.md §Жёсткие правила)."

render_template "$SKILL_HOME/memory/_templates/domains.md" "$mem_dir/domains.md" \
  "ROUTER_ALIAS=$ROUTER_ALIAS" \
  "LAST_UPDATED_ISO=$now_iso" \
  "DOMAIN_TABLE_ROWS=$domain_rows" \
  "NOTES=Adopted from existing route.rules / route.rule_set on $now_iso. Маппинг домен→outbound в probe пока не эмитится — поле помечено _?_."

render_template "$SKILL_HOME/memory/_templates/proxies.md" "$mem_dir/proxies.md" \
  "ROUTER_ALIAS=$ROUTER_ALIAS" \
  "LAST_UPDATED_ISO=$now_iso" \
  "ROUTER_HOST=$ROUTER_HOST" \
  "PROXY_TABLE_ROWS=$proxy_rows" \
  "NOTES=Adopted from existing inbounds on $now_iso. Outbound mapping каждого inbound пока не эмитится probe'ом."

# --- 6. Journal append ---------------------------------------------------------

if ! memory_journal_append "$ROUTER_ALIAS" "adopted_existing_setup" \
       "snapshot_before=$snapshot_label" \
       "source=external" \
       "outbounds_count=$outbounds_count" \
       "inbounds_count=$inbounds_count" \
       "domains_count=$domains_count" \
       "config_present=$config_present_str" \
       "rollback_runtime_present=$rollback_runtime_present_str"; then
  echo "adopt: не смог записать journal event (некритично, продолжаю)." >&2
fi

# --- 7. Summary ----------------------------------------------------------------

if [ "$quiet" != "1" ]; then
  cat >&2 <<EOF

adopt: готово.
  router:              $ROUTER_ALIAS ($ROUTER_HOST)
  baseline snapshot:   $snapshot_label
  config.json present: $config_present_str
  outbounds (VPN):     $(printf '%s' "$vpn_outbounds" | jq 'length')
  outbounds (total):   $outbounds_count
  inbounds (LAN proxy):$inbounds_count
  domains in rules:    $domains_count
  rollback runtime:    $rollback_runtime_present_str

Сделано:
  - memory/$ROUTER_ALIAS/state.md     ← через doctor.sh
  - memory/$ROUTER_ALIAS/vpns.md      ← перерендерен (бэкап: .vpns.md.pre-adopt.bak)
  - memory/$ROUTER_ALIAS/domains.md   ← перерендерен (бэкап: .domains.md.pre-adopt.bak)
  - memory/$ROUTER_ALIAS/proxies.md   ← перерендерен (бэкап: .proxies.md.pre-adopt.bak)
  - memory/$ROUTER_ALIAS/journal.md   ← событие adopted_existing_setup

Ограничения v1:
  - install-state.json на роутер НЕ записывается. install-vpn.sh продолжит
    отклонять этот роутер как existing-not-owned. Используй add-domain.sh /
    add-vpn.sh / add-proxy.sh — они работают независимо от install-state.
  - probe не эмитит outbound↔inbound маппинг и состав selector/urltest. Эти
    поля в memory помечены _?_ и могут быть уточнены вручную через
    bin/raw-ssh.sh (escape hatch) или дополнены при дальнейшем развитии probe.

Следующий шаг: прочитай memory/$ROUTER_ALIAS/state.md и обсуди с пользователем
что добавить (домен / VPN-ноду / LAN-прокси).
EOF
fi

exit 0
