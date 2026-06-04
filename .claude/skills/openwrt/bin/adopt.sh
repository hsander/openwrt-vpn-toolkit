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
#   - НЕ модифицирует sing-box config, firewall, init.d (только пишет skill-owned
#     /etc/vpn-kit/install-state.json — служебный маркер, не часть рабочего конфига)
#
# install-state.json (с source=adopt) пишется через CAS-shim
# lib/install-state-remote.sh → on-router /usr/lib/vpn-kit/state-write.sh.
# Это делает роутер «adopted» с точки зрения skill: install-vpn.sh больше не
# отклоняет его как existing-not-owned, а add-vpn/add-domain/add-proxy получают
# точку отсчёта (revision_at_commit) для будущих committed_steps.
#
# Usage:
#   bin/adopt.sh --router <alias> [--writer <id>] [--skip-install-state] [--quiet]
#
# Exit codes:
#   0   ok
#   2   router not found / SSH unreachable / backup-now failed / doctor probe failed
#  11   CAS STALE: revision raced (initial write should never see this)
#  12   CAS LOCK: could not acquire on-router state lock
#  13   validation error (writer id, journal append, install-state write)
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
# shellcheck source=../lib/install-state-remote.sh
. "$SKILL_HOME/lib/install-state-remote.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/adopt.sh --router <alias> [--writer <id>] [--skip-install-state] [--quiet]

Адоптирует уже настроенный роутер: baseline snapshot + probe + запись
install-state.json (source=adopt) на роутер + рендер memory из реального
состояния /etc/sing-box/config.json. Sing-box config / firewall / init.d
НЕ модифицируются.

Options:
  --router <alias>        alias из memory/routers.yaml (обязателен)
  --writer <id>           writer ID (по умолчанию claude-code@adopt-<unix-ts>)
  --skip-install-state    не писать install-state.json на роутер (для тестов)
  --quiet                 не печатать summary в stderr
EOF
  exit 64
}

router=""
writer=""
quiet=0
skip_install_state=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router)              router="${2:-}"; shift 2 ;;
    --writer)              writer="${2:-}"; shift 2 ;;
    --skip-install-state)  skip_install_state=1; shift ;;
    --quiet)               quiet=1; shift ;;
    -h|--help)             usage ;;
    *) echo "adopt: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "adopt: --router обязателен" >&2; usage; }
[ -z "$writer" ] && writer="claude-code@adopt-$(date +%s)"

# Mirror lib/vpn-kit-common.sh:vpn_kit_validate_writer_id (POSIX, busybox-safe).
# state-write.sh on the router enforces the same regex; we fail fast locally so
# CLI typos don't waste an SSH round-trip.
if ! printf '%s' "$writer" | grep -qE '^[a-z-]+@[a-zA-Z0-9._-]+$'; then
  echo "adopt: --writer должен соответствовать <role>@<instance-id> (e.g. claude-code@adopt-1234), получено: '$writer'" >&2
  exit 13
fi

# Normalize uname -m output into the schema enum (aarch64|armv7|x86_64|mips|mipsel).
# Anything else → "unknown"; install-state.schema.json will then reject the write,
# which is the correct safety behaviour — we'd rather fail loud than fingerprint
# the router as the wrong arch.
normalize_arch() {
  case "$1" in
    aarch64|arm64)        echo "aarch64" ;;
    armv7l|armv7|armv7hl) echo "armv7" ;;
    x86_64|amd64)         echo "x86_64" ;;
    mips)                 echo "mips" ;;
    mipsel)               echo "mipsel" ;;
    *)                    echo "unknown" ;;
  esac
}

# --- 1. Resolve router + SSH alive --------------------------------------------
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
adopt: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Сначала: bin/setup-ssh.sh --router $ROUTER_ALIAS --host $ROUTER_HOST
EOF
  exit 2
fi

# Деплоим lib/*.sh на роутер если их там ещё нет (необходимо для CAS через
# state-read.sh / state-write.sh; OpenWrt minimal builds не имеют sftp).
if ! ensure_router_lib_deployed; then
  echo "adopt: не смог задеплоить lib/*.sh на роутер — CAS недоступен." >&2
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

# probe v2 fields (additive). If schema < 2, these are [] and downstream jq lookups
# resolve to _?_ — matches legacy behavior. We don't gate render on the version
# because v1 probes simply lack data, not produce wrong data.
probe_schema_version="$(j '.probe_schema_version // 1')"
selector_groups="$(j '.selector_groups // []')"
inbound_outbound_map="$(j '.inbound_outbound_map // []')"
domain_outbound_map="$(j '.domain_outbound_map // []')"

# Sanitize: if any of the v2 fields are not arrays (corrupt probe), force to [].
for var_name in selector_groups inbound_outbound_map domain_outbound_map; do
  eval "_val=\$$var_name"
  if ! printf '%s' "$_val" | jq -e 'type == "array"' >/dev/null 2>&1; then
    eval "$var_name='[]'"
  fi
done
unset _val

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

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 4.5. Write install-state.json on router (CAS) -----------------------------
# Marks router as "adopted" so install-vpn.sh accepts it as managed by skill,
# without overwriting any sing-box config / firewall / init.d. Uses CAS shim
# so if rollback-runtime (adopt-safety-state.sh) already created the file, we
# merge instead of clobber.

install_state_status="written"
install_state_revision=""

if [ "$skip_install_state" = "1" ]; then
  [ "$quiet" = "1" ] || echo "adopt: --skip-install-state — пропускаю запись install-state.json" >&2
  install_state_status="skipped"
else
  # Compute sha256 of files we semantically "adopt" (read-only, not owned, but
  # tracked for drift detection in subsequent runs). probe_schema_version=2 does
  # NOT emit config_sha256, so we ask the router directly via sha256sum.
  # awk strips path; null is preserved if file is absent (sha=="").
  [ "$quiet" = "1" ] || echo "adopt: считаю sha256 sing-box config + tproxy init для drift-tracking..." >&2
  sha_config=""
  sha_tproxy=""
  if sha_raw="$(ssh_run 'sha256sum /etc/sing-box/config.json /etc/init.d/sing-box-tproxy 2>/dev/null' 2>/dev/null)"; then
    sha_config="$(printf '%s' "$sha_raw"  | awk '$2 == "/etc/sing-box/config.json"      {print $1; exit}')"
    sha_tproxy="$(printf '%s' "$sha_raw"  | awk '$2 == "/etc/init.d/sing-box-tproxy"   {print $1; exit}')"
  fi

  # Pull router identity from probe (schema-v2 fields all present).
  probe_hostname="$(j '.hostname')"
  probe_openwrt="$(j '.openwrt_version')"
  probe_arch_raw="$(j '.arch')"
  probe_singbox_ver="$(j '.singbox_version')"
  probe_arch_norm="$(normalize_arch "$probe_arch_raw")"

  # Proxy ports payload — pass inbounds_detail straight through. Note: schema
  # requires "outbound" per item; probe doesn't emit per-inbound outbound mapping
  # yet, so we synthesise "_unknown" — drift-detection will surface this later.
  proxy_ports_json="$(printf '%s' "$inbounds_detail" | jq -c '
    map({
      port: (.listen_port // 0),
      listen: (.listen // ""),
      outbound: "_unknown",
      type: (.type // "mixed")
    })
  ')"

  # adopted_config_sha256: track files we observe but do NOT own. Empty sha → null.
  adopted_sha_json="$(jq -n \
    --arg conf  "$sha_config" \
    --arg tprx  "$sha_tproxy" \
    '{
       "/etc/sing-box/config.json":    (if ($conf | length) > 0 then $conf else null end),
       "/etc/init.d/sing-box-tproxy":  (if ($tprx | length) > 0 then $tprx else null end)
    }')"

  # components.sing-box — config_sha256 is null when probe couldn't read it.
  singbox_component_json="$(jq -n \
    --arg ver  "$probe_singbox_ver" \
    --arg sha  "$sha_config" \
    '{
       version: (if ($ver | length) > 0 then $ver else null end),
       init:    "/etc/sing-box/config.json",
       config_sha256: (if ($sha | length) > 0 then $sha else null end)
    }')"

  # Read current revision; 0 means file is absent → initial write.
  existing_rev=""
  if ! existing_rev="$(remote_read_revision)"; then
    echo "adopt: не смог прочитать install-state revision с роутера (state-read.sh вернул ненулевой код). Проверь: lib/*.sh задеплоены на роутер?" >&2
    exit 13
  fi

  if [ "$existing_rev" = "0" ]; then
    # ---------- Initial write ----------
    [ "$quiet" = "1" ] || echo "adopt: install-state.json отсутствует на роутере — пишу initial revision (source=adopt)..." >&2
    payload="$(jq -n \
      --arg now       "$now_iso" \
      --arg hostname  "$probe_hostname" \
      --arg openwrt   "$probe_openwrt" \
      --arg arch      "$probe_arch_norm" \
      --argjson singbox  "$singbox_component_json" \
      --argjson ports    "$proxy_ports_json" \
      --argjson adopted_sha "$adopted_sha_json" \
      '{
        version: 1,
        skill_version: "0.1.0",
        installed_at: $now,
        adopted_at:   $now,
        source: "adopt",
        profile: "standard",
        router_identity: {
          name: (if ($hostname | length) > 0 then $hostname else "adopted-router" end),
          openwrt_version: (if ($openwrt | length) > 0 then $openwrt else "unknown" end),
          arch: $arch
        },
        committed_steps: [
          {step_id: "adopt-baseline", committed_at: $now, revision_at_commit: 1}
        ],
        components: {
          "sing-box": $singbox
        },
        proxy_ports: $ports,
        files_owned_by_skill: [
          "/etc/vpn-kit/install-state.json",
          "/etc/vpn-kit/persistent-sets.nft"
        ],
        adopted_config_sha256: $adopted_sha,
        dynamic_additions: []
      }')"

    if ! install_state_revision="$(remote_cas_write "$writer" 0 "$payload" 2>&1)"; then
      cas_rc=$?
      case "$cas_rc" in
        11) echo "adopt: install-state CAS STALE на initial write — это не должно происходить (race?). Stdout: $install_state_revision" >&2 ;;
        12) echo "adopt: install-state LOCK — не смог захватить /var/lock/vpn-kit-state.lock после ретраев. Stdout: $install_state_revision" >&2 ;;
        13) echo "adopt: install-state VALIDATION — payload отклонён state-write.sh. Stdout: $install_state_revision" >&2 ;;
        *)  echo "adopt: install-state write упал (rc=$cas_rc). Stdout: $install_state_revision" >&2 ;;
      esac
      exit "$cas_rc"
    fi
    install_state_status="written"
  else
    # ---------- Merge into existing state ----------
    # rollback-runtime / safety-install уже создал install-state. Мы должны
    # дописать adopt-специфичные поля БЕЗ затирания того, что там есть
    # (например, committed_steps безопасной установки). CAS-цикл: read → merge
    # → write; при STALE — re-read.
    [ "$quiet" = "1" ] || echo "adopt: install-state уже существует (revision=$existing_rev) — мержу adopt-поля..." >&2

    merge_attempt=1
    merge_max=3
    while [ "$merge_attempt" -le "$merge_max" ]; do
      existing_json=""
      if ! existing_json="$(remote_read_state_json)"; then
        echo "adopt: не смог прочитать install-state.json с роутера." >&2
        exit 13
      fi

      payload="$(printf '%s' "$existing_json" | jq \
        --arg now         "$now_iso" \
        --argjson singbox    "$singbox_component_json" \
        --argjson ports      "$proxy_ports_json" \
        --argjson adopted_sha "$adopted_sha_json" \
        '
          # Strip CAS-managed fields — state-write.sh re-sets them.
          del(._revision, ._last_writer, ._last_writer_host, ._last_updated_at)
          # Always (re)mark source/adopted_at — adopt is the action that just ran.
          | .source = "adopt"
          | .adopted_at = $now
          # proxy_ports + adopted_config_sha256 + components.sing-box reflect
          # current reality from probe — refresh unconditionally. Other fields
          # (committed_steps, files_owned_by_skill, dynamic_additions, etc.)
          # belong to the previous writer; preserve them.
          | .components = ((.components // {}) | .["sing-box"] = $singbox)
          | .proxy_ports = $ports
          | .adopted_config_sha256 = $adopted_sha
          | .files_owned_by_skill =
              ((.files_owned_by_skill // []) +
               ["/etc/vpn-kit/install-state.json", "/etc/vpn-kit/persistent-sets.nft"]
               | unique)
          | .dynamic_additions = (.dynamic_additions // [])
        ')"

      if install_state_revision="$(remote_cas_write "$writer" "$existing_rev" "$payload" 2>&1)"; then
        install_state_status="merged"
        break
      fi
      cas_rc=$?

      if [ "$cas_rc" = "11" ] && [ "$merge_attempt" -lt "$merge_max" ]; then
        [ "$quiet" = "1" ] || echo "adopt: install-state CAS STALE (attempt $merge_attempt) — re-read и retry..." >&2
        existing_rev="$(remote_read_revision)" || { echo "adopt: re-read revision упал." >&2; exit 13; }
        merge_attempt=$((merge_attempt + 1))
        continue
      fi

      case "$cas_rc" in
        11) echo "adopt: install-state CAS STALE после $merge_max попыток — другой писатель удерживает гонку. Stdout: $install_state_revision" >&2 ;;
        12) echo "adopt: install-state LOCK — не смог захватить лок. Stdout: $install_state_revision" >&2 ;;
        13) echo "adopt: install-state VALIDATION — merge payload отклонён. Stdout: $install_state_revision" >&2 ;;
        *)  echo "adopt: install-state merge упал (rc=$cas_rc). Stdout: $install_state_revision" >&2 ;;
      esac
      exit "$cas_rc"
    done
  fi

  [ "$quiet" = "1" ] || echo "adopt: install-state записан (status=$install_state_status, revision=$install_state_revision)." >&2
fi

# --- 5. Render memory/<alias>/{vpns,domains,proxies}.md из реального state -----

# Helper: filter out non-VPN outbound types (direct/block/dns/selector/urltest).
# selector/urltest — это auto-failover wrappers; их участников показываем отдельно.
vpn_outbounds="$(printf '%s' "$outbounds_detail" | jq -c '
  map(select(.type as $t | $t != "direct" and $t != "block" and $t != "dns" and $t != "selector" and $t != "urltest"))
')"

# All outbound tags that participate in ANY selector/urltest group — used to
# compute the "В auto-failover" column. Empty array if probe is v1 / no groups.
failover_member_tags="$(printf '%s' "$selector_groups" | jq -c '
  [ .[].outbounds // [] | .[]? | select(type == "string") ] | unique
')"

# vpns.md — таблица: | Tag | Тип | Host:port | Регион | В auto-failover | Mixed-port |
#
# In-auto-failover: tag presence in `failover_member_tags`.
# Mixed-port: reverse-lookup via `inbound_outbound_map` → match outbound_tag to
#   this VPN tag, then resolve the inbound_tag → listen_port via inbounds_detail.
#   Multiple ports → comma-separated. None → empty.
build_vpn_rows() {
  if [ "$(printf '%s' "$vpn_outbounds" | jq 'length')" = "0" ]; then
    printf '_(пусто — нет VPN outbound в /etc/sing-box/config.json)_\n'
    return
  fi
  printf '%s' "$vpn_outbounds" | jq -r \
    --argjson members "$failover_member_tags" \
    --argjson iom     "$inbound_outbound_map" \
    --argjson inb     "$inbounds_detail" \
    '
      # Build inbound_tag → listen_port lookup from inbounds_detail.
      ($inb | map({key: (.tag // ""), value: (.listen_port // 0)}) | from_entries) as $inb_port_by_tag
      | .[] |
      . as $vpn |
      ($vpn.tag // "?") as $tag |
      # Mixed-port: collect inbound_tags routed to this outbound, resolve to ports.
      ( [ $iom[]?
          | select(.outbound_tag == $tag)
          | ($inb_port_by_tag[.inbound_tag] // empty)
          | select(. != 0)
        ] | unique
      ) as $ports |
      ($members | index($tag)) as $is_failover |
      "| " + $tag +
      " | " + ($vpn.type // "?") +
      " | " + (($vpn.server // "?") + ":" + (($vpn.server_port // 0) | tostring)) +
      " | _?_" +
      " | " + (if $is_failover then "yes" else "no" end) +
      " | " + (if ($ports | length) == 0 then "_?_"
               else ($ports | map(tostring) | join(", ")) end) +
      " |"
    '
}

# Failover info — берём первый selector/urltest group (legacy memory schema
# хранит одну строку failover). Если групп нет — _?_. Plain selector без url/
# interval/tolerance (тип = "selector") даёт null в этих полях → "n/a".
failover_first="$(printf '%s' "$selector_groups" | jq -c '.[0] // null')"

failover_tags="_?_"
failover_url="_?_"
failover_interval="_?_"
failover_tolerance="_?_"
if [ "$failover_first" != "null" ] && [ -n "$failover_first" ]; then
  failover_tags="$(printf '%s' "$failover_first" | jq -r '
    (.outbounds // []) | if length == 0 then "_?_" else join(", ") end
  ')"
  failover_url="$(printf '%s' "$failover_first" | jq -r '
    if .failover_url == null then "n/a" else (.failover_url | tostring) end
  ')"
  failover_interval="$(printf '%s' "$failover_first" | jq -r '
    if .failover_interval == null then "n/a" else (.failover_interval | tostring) end
  ')"
  failover_tolerance="$(printf '%s' "$failover_first" | jq -r '
    if .failover_tolerance == null then "n/a" else (.failover_tolerance | tostring) end
  ')"
fi

# domains.md — таблица: | Домен | Outbound | Когда добавлен | Кем |
#
# Combine sources:
#   * `domain_outbound_map` — domains pulled inline from route.rules[].domain*
#     (already carries outbound_tag).
#   * `rule_set_domains` — domains discovered via rule_set / inline route.rules
#     domain lists; outbound mapping is not always direct → marked "_?_ (rule_set)"
#     if absent from domain_outbound_map.
build_domain_rows() {
  # Merge both sources into a list of {domain, outbound_label}.
  rows_json="$(jq -cn \
    --argjson dom "$domain_outbound_map" \
    --argjson rsd "$rule_set_domains" \
    '
      # Build map domain → unique outbound_tags from domain_outbound_map.
      ($dom | group_by(.domain) | map({
        key: .[0].domain,
        value: ([.[].outbound_tag] | unique | map(select(. != null)))
      }) | from_entries) as $by_dom
      | (
          # Start with explicit mappings.
          ($dom | map(.domain) // []) +
          # Add rule_set domains (some may overlap — dedup below).
          ($rsd // [])
        ) | unique
      | map(
          . as $d |
          ($by_dom[$d] // []) as $obs |
          {
            domain: $d,
            outbound:
              (if ($obs | length) == 0 then "_?_ (rule_set)"
               elif ($obs | length) == 1 then $obs[0]
               else (($obs | join(", ")) + " (multiple)") end)
          }
        )
    '
  )"
  if [ "$(printf '%s' "$rows_json" | jq 'length')" = "0" ]; then
    printf '_(пусто — нет доменов в route.rules / route.rule_set)_\n'
    return
  fi
  printf '%s' "$rows_json" | jq -r '
    .[] | "| " + .domain + " | " + .outbound + " | adopted | external |"
  '
}

# proxies.md — таблица: | Port | Outbound | Назначение | Listen IP |
#
# Outbound resolution: look up inbound by its tag (preferred) in
# `inbound_outbound_map`. Если у inbound нет tag — пробуем listen_port (fallback
# не сработает, потому что map хранит только tag'и; в этом случае → _?_).
# Multiple outbound_tags for same inbound → "<a>, <b> (multiple)".
build_proxy_rows() {
  if [ "$inbounds_count" = "0" ]; then
    printf '_(пусто — нет LAN proxy inbound mixed/socks/http)_\n'
    return
  fi
  printf '%s' "$inbounds_detail" | jq -r \
    --argjson iom "$inbound_outbound_map" \
    '
      .[] |
      . as $in |
      ($in.tag // "") as $tag |
      ( [ $iom[]?
          | select(.inbound_tag == $tag and $tag != "")
          | .outbound_tag
        ] | unique | map(select(. != null))
      ) as $obs |
      ( if ($tag == "") then "_?_"
        elif ($obs | length) == 0 then "_?_"
        elif ($obs | length) == 1 then $obs[0]
        else (($obs | join(", ")) + " (multiple)") end
      ) as $ob_label |
      "| " + (($in.listen_port // 0) | tostring) +
      " | " + $ob_label +
      " | adopted (" + ($in.type // "?") + ") | " + ($in.listen // "?") + " |"
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

# Choose NOTES wording based on probe schema version: v2 carries the mapping
# fields, v1 doesn't — be explicit about which placeholders are unresolvable.
if [ "$probe_schema_version" -ge 2 ] 2>/dev/null; then
  vpns_notes="Adopted from existing setup on $now_iso (probe schema v$probe_schema_version). 'В auto-failover' и 'Mixed-port' выведены из selector_groups + inbound_outbound_map. Region остаётся _?_ — probe не геолоцирует серверы. Уточнения — через bin/raw-ssh.sh с явным подтверждением (см. SKILL.md §Жёсткие правила)."
  domains_notes="Adopted from existing route.rules / route.rule_set on $now_iso (probe schema v$probe_schema_version). Outbound выведен из domain_outbound_map; для доменов, попавших сюда только через rule_set без явного route.rules entry, проставлен '_?_ (rule_set)' — это означает 'outbound определяется rule_set'."
  proxies_notes="Adopted from existing inbounds on $now_iso (probe schema v$probe_schema_version). Outbound каждого порта выведен из inbound_outbound_map. '_?_ (multiple)' = на один inbound смотрит несколько rule'ов с разными outbound'ами (требует ручной диагностики)."
else
  vpns_notes="Adopted from existing setup on $now_iso (probe schema v1 — старый формат). Маппинги outbound↔inbound и состав selector/urltest probe не эмитит, поля помечены _?_."
  domains_notes="Adopted from existing route.rules / route.rule_set on $now_iso (probe schema v1). Маппинг домен→outbound в probe пока не эмитится — поле помечено _?_."
  proxies_notes="Adopted from existing inbounds on $now_iso (probe schema v1). Outbound mapping каждого inbound пока не эмитится probe'ом."
fi

render_template "$SKILL_HOME/memory/_templates/vpns.md" "$mem_dir/vpns.md" \
  "ROUTER_ALIAS=$ROUTER_ALIAS" \
  "LAST_UPDATED_ISO=$now_iso" \
  "VPN_TABLE_ROWS=$vpn_rows" \
  "FAILOVER_TAGS=$failover_tags" \
  "FAILOVER_INTERVAL=$failover_interval" \
  "FAILOVER_URL=$failover_url" \
  "FAILOVER_TOLERANCE=$failover_tolerance" \
  "NOTES=$vpns_notes"

render_template "$SKILL_HOME/memory/_templates/domains.md" "$mem_dir/domains.md" \
  "ROUTER_ALIAS=$ROUTER_ALIAS" \
  "LAST_UPDATED_ISO=$now_iso" \
  "DOMAIN_TABLE_ROWS=$domain_rows" \
  "NOTES=$domains_notes"

render_template "$SKILL_HOME/memory/_templates/proxies.md" "$mem_dir/proxies.md" \
  "ROUTER_ALIAS=$ROUTER_ALIAS" \
  "LAST_UPDATED_ISO=$now_iso" \
  "ROUTER_HOST=$ROUTER_HOST" \
  "PROXY_TABLE_ROWS=$proxy_rows" \
  "NOTES=$proxies_notes"

# --- 6. Journal append ---------------------------------------------------------

if ! memory_journal_append "$ROUTER_ALIAS" "adopted_existing_setup" \
       "snapshot_before=$snapshot_label" \
       "source=external" \
       "outbounds_count=$outbounds_count" \
       "inbounds_count=$inbounds_count" \
       "domains_count=$domains_count" \
       "config_present=$config_present_str" \
       "rollback_runtime_present=$rollback_runtime_present_str" \
       "install_state_status=$install_state_status" \
       "install_state_revision=${install_state_revision:-0}"; then
  echo "adopt: не смог записать journal event (некритично, продолжаю)." >&2
fi

# --- 7. Summary ----------------------------------------------------------------

if [ "$quiet" != "1" ]; then
  install_state_summary_line="install-state.json:   $install_state_status (revision=${install_state_revision:-n/a})"
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
  $install_state_summary_line

Сделано:
  - /etc/vpn-kit/install-state.json   ← $install_state_status (source=adopt) на роутере
  - memory/$ROUTER_ALIAS/state.md     ← через doctor.sh
  - memory/$ROUTER_ALIAS/vpns.md      ← перерендерен (бэкап: .vpns.md.pre-adopt.bak)
  - memory/$ROUTER_ALIAS/domains.md   ← перерендерен (бэкап: .domains.md.pre-adopt.bak)
  - memory/$ROUTER_ALIAS/proxies.md   ← перерендерен (бэкап: .proxies.md.pre-adopt.bak)
  - memory/$ROUTER_ALIAS/journal.md   ← событие adopted_existing_setup

Ограничения (probe schema v$probe_schema_version):
  - Region у VPN-нод остаётся _?_ — probe не геолоцирует серверы.
  - Для доменов, попавших в memory только через rule_set (без явного route.rules
    entry), outbound = '_?_ (rule_set)' — это нормально (outbound определяется
    самим rule_set'ом). Уточнить можно через bin/raw-ssh.sh.
  - proxy_ports[].outbound в install-state временно "_unknown" (см. A.2 backlog).

Следующий шаг: прочитай memory/$ROUTER_ALIAS/state.md и обсуди с пользователем
что добавить (домен / VPN-ноду / LAN-прокси).
EOF
fi

exit 0
