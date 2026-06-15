#!/usr/bin/env bash
# bin/add-vpn.sh — add a new VLESS Reality outbound to an already-installed sing-box.
#
# Mutates /etc/sing-box/config.json on the router:
#   * appends a new vless outbound (Reality, xtls-rprx-vision)
#   * optionally appends the tag to the auto-failover urltest outbound
#   * optionally adds a mixed inbound on 192.168.1.1:<port> bound to this outbound
#   * excludes the new server IP from zapret2 (zapret-ip-user-exclude.txt) so the
#     DPI-bypass desync does not corrupt the VPN tunnel handshake
#
# Snapshot-before, sing-box check, atomic write, restart with reachability watch,
# auto-rollback on SSH loss. Secrets (uuid, public_key, short_id, server_name)
# never reach stdout/stderr/journal/memory MD — only host:port and tag are public.
#
# Usage:
#   bin/add-vpn.sh --router <alias> --url 'vless://...' [--tag <name>]
#                  [--add-proxy-port <port>] [--no-add-to-failover]
#                  [--add-to-failover] [--no-backup] [--force]
#
# Exit codes:
#   0   ok
#   2   router not found / SSH unreachable / remote file missing
#  13   validation / safety refuse / malformed URL
#  20   rollback fired
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
# shellcheck source=../lib/country-resolve.sh
. "$SKILL_HOME/lib/country-resolve.sh"
# shellcheck source=../lib/watchdog-sync.sh
. "$SKILL_HOME/lib/watchdog-sync.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/add-vpn.sh --router <alias> --url 'vless://...' [opts]

Добавляет новый VLESS Reality outbound в /etc/sing-box/config.json роутера.

Options:
  --router <alias>          alias из memory/routers.yaml (обяз.)
  --url '<vless://...>'     VLESS URL (обяз.). Парсится локально, секреты не логируются.
  --tag <name>              tag для outbound. По умолчанию берётся из #fragment URL
                            или vpn-N (следующий свободный).
  --add-proxy-port <port>   также добавить mixed-inbound 192.168.1.1:<port> → этот outbound.
                            Должен быть 4000-4099 и не использоваться.
  --add-to-failover         добавить tag в auto-failover.outbounds (по умолчанию: да).
  --no-add-to-failover      НЕ добавлять в auto-failover.
  --no-backup               (только для тестов) пропустить pre-backup.
  --force                   пропустить часть проверок (overwrite одинаковый tag).
EOF
  exit 64
}

router=""
url=""
tag=""
proxy_port=""
add_to_failover=1
country=""
no_backup=0
force=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --url) url="${2:-}"; shift 2 ;;
    --tag) tag="${2:-}"; shift 2 ;;
    --country) country="${2:-}"; shift 2 ;;
    --add-proxy-port) proxy_port="${2:-}"; shift 2 ;;
    --add-to-failover) add_to_failover=1; shift ;;
    --no-add-to-failover) add_to_failover=0; shift ;;
    --no-backup) no_backup=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage ;;
    *) echo "add-vpn: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "add-vpn: --router обязателен" >&2; usage; }
[ -z "$url" ]    && { echo "add-vpn: --url обязателен" >&2; usage; }

# Basic URL gate: only vless:// schemes accepted. Never echo the URL.
case "$url" in
  vless://*) ;;
  *) echo "add-vpn: --url должен начинаться с vless://" >&2; exit 13 ;;
esac

# Validate optional tag shape early (before parsing).
if [ -n "$tag" ]; then
  if ! printf '%s' "$tag" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    echo "add-vpn: невалидный --tag (a-zA-Z0-9_-)" >&2
    exit 13
  fi
  if [ "$tag" = "direct" ] || [ "$tag" = "auto-failover" ]; then
    echo "add-vpn: tag '$tag' зарезервирован" >&2
    exit 13
  fi
fi

# Validate optional proxy port.
if [ -n "$proxy_port" ]; then
  if ! printf '%s' "$proxy_port" | grep -qE '^[0-9]+$'; then
    echo "add-vpn: --add-proxy-port должен быть число" >&2
    exit 13
  fi
  if [ "$proxy_port" -lt 4000 ] || [ "$proxy_port" -gt 4099 ]; then
    echo "add-vpn: --add-proxy-port должен быть 4000..4099 (получено $proxy_port)" >&2
    exit 13
  fi
fi

# ---------------------------------------------------------------------------
# Resolve router (need ROUTER_ALIAS / ROUTER_HOST for messages) — SSH probe
# is deferred until AFTER URL parsing so that a malicious URL fails fast
# (with exit 13, not exit 2) even when SSH is down.
# ---------------------------------------------------------------------------
resolve_router_config "$router"

# ---------------------------------------------------------------------------
# Parse VLESS URL into shell-local vars. SECRETS HELD HERE — never echoed.
# ---------------------------------------------------------------------------
# parse_vless reads URL on stdin and emits KEY=VALUE on stdout for shell-read
# (not eval). Caller pipes the values into a chmod-600 tempfile and sources it,
# then deletes it. Output keys: host, port, uuid, pbk, sid, sni, flow, fp, frag.
parse_vless() {
  local raw without_scheme before_fragment main_part query frag
  local uuid host_port server server_port
  IFS= read -r raw

  case "$raw" in
    vless://*) ;;
    *) echo "parse_vless: not a vless:// URL" >&2; return 13 ;;
  esac
  without_scheme="${raw#vless://}"

  # split off fragment (#name)
  case "$without_scheme" in
    *\#*) frag="${without_scheme#*#}"; before_fragment="${without_scheme%%#*}" ;;
    *) frag=""; before_fragment="$without_scheme" ;;
  esac

  # split off query (?key=val&...)
  case "$before_fragment" in
    *\?*) main_part="${before_fragment%%\?*}"; query="${before_fragment#*\?}" ;;
    *) main_part="$before_fragment"; query="" ;;
  esac

  uuid="${main_part%@*}"
  host_port="${main_part#*@}"
  # host:port may have v6 brackets — for our use case (Reality) plain host:port
  server="${host_port%:*}"
  server_port="${host_port##*:}"

  # query_value extractor — POSIX, no echo.
  qv() {
    local key="$1" needle
    needle="${key}="
    printf '%s' "$query" | tr '&' '\n' | while IFS= read -r kv; do
      case "$kv" in
        "$needle"*) printf '%s' "${kv#"$needle"}"; break ;;
      esac
    done
  }

  local pbk sid sni flow fp
  pbk="$(qv pbk)"
  sid="$(qv sid)"
  sni="$(qv sni)"
  flow="$(qv flow)"
  fp="$(qv fp)"

  [ -n "$flow" ] || flow="xtls-rprx-vision"
  [ -n "$sni" ] || sni="$server"
  [ -n "$fp" ] || fp="chrome"

  if [ -z "$uuid" ] || [ -z "$server" ] || [ -z "$server_port" ] || [ -z "$pbk" ]; then
    echo "parse_vless: URL должен включать uuid, server, port, pbk" >&2
    return 13
  fi

  # URL-decode the fragment (just %XX → byte). Keep it simple, agent-side.
  if [ -n "$frag" ]; then
    frag="$(printf '%b' "$(printf '%s' "$frag" | sed 's/+/ /g; s/%/\\x/g')")"
  fi

  # Emit key=value lines. NOTE: values are not shell-quoted — caller handles.
  printf 'host=%s\n' "$server"
  printf 'port=%s\n' "$server_port"
  printf 'uuid=%s\n' "$uuid"
  printf 'pbk=%s\n' "$pbk"
  printf 'sid=%s\n' "$sid"
  printf 'sni=%s\n' "$sni"
  printf 'flow=%s\n' "$flow"
  printf 'fp=%s\n' "$fp"
  printf 'frag=%s\n' "$frag"
}

# Stash parsed fields into a chmod-600 tempfile, then source it.
parsed_tmp="$(mktemp -t openwrt-skill-vless.XXXXXX)"
chmod 600 "$parsed_tmp"
# shellcheck disable=SC2064
trap 'rm -f "$parsed_tmp"' EXIT INT TERM

if ! printf '%s\n' "$url" | parse_vless > "$parsed_tmp"; then
  echo "add-vpn: не удалось распарсить vless:// URL" >&2
  exit 13
fi

# Locals — these names must not be exported anywhere.
v_host=""; v_port=""; v_uuid=""; v_pbk=""; v_sid=""
v_sni=""; v_flow=""; v_fp=""; v_frag=""
while IFS='=' read -r k v; do
  case "$k" in
    host) v_host="$v" ;;
    port) v_port="$v" ;;
    uuid) v_uuid="$v" ;;
    pbk)  v_pbk="$v" ;;
    sid)  v_sid="$v" ;;
    sni)  v_sni="$v" ;;
    flow) v_flow="$v" ;;
    fp)   v_fp="$v" ;;
    frag) v_frag="$v" ;;
  esac
done < "$parsed_tmp"
rm -f "$parsed_tmp"
trap - EXIT INT TERM

# Validate parsed fields one more time. Refuse to continue if anything secret-looking is empty.
if [ -z "$v_host" ] || [ -z "$v_port" ] || [ -z "$v_uuid" ] || [ -z "$v_pbk" ]; then
  echo "add-vpn: парсер URL не нашёл всех обязательных полей" >&2
  exit 13
fi
case "$v_port" in ''|*[!0-9]*) echo "add-vpn: невалидный port в URL" >&2; exit 13 ;; esac

# Host-shape validation: refuse anything that isn't strictly hostname/IPv4-with-dots
# safe characters. Blocks shell-metachar injection via VLESS host segment.
case "$v_host" in
  *[!a-zA-Z0-9.:_-]*|'') echo "add-vpn: invalid host in URL: '$v_host'" >&2; exit 13 ;;
esac

# ---------------------------------------------------------------------------
# SSH alive check (deferred until after URL validation).
# ---------------------------------------------------------------------------
if ! ssh_check_alive 5; then
  cat >&2 <<EOF
add-vpn: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST).
Проверь: bin/setup-ssh.sh --router $ROUTER_ALIAS
EOF
  exit 2
fi

# ---------------------------------------------------------------------------
# Tag derivation: fragment > vpn-N
# ---------------------------------------------------------------------------
remote_cfg="/etc/sing-box/config.json"

# Fetch current config so we can detect existing tags / ports.
local_cfg="$(mktemp -t openwrt-skill-cfg.XXXXXX)"
local_new_cfg="$(mktemp -t openwrt-skill-cfgnew.XXXXXX)"
trap 'rm -f "$local_cfg" "$local_new_cfg"' EXIT INT TERM

if ! scp_from "$remote_cfg" "$local_cfg" >/dev/null 2>&1; then
  echo "add-vpn: не смог получить $remote_cfg с роутера (sing-box установлен?)" >&2
  exit 2
fi

if ! jq -e 'type == "object" and has("outbounds")' "$local_cfg" >/dev/null 2>&1; then
  echo "add-vpn: $remote_cfg не выглядит валидным sing-box config" >&2
  exit 13
fi

existing_tags="$(jq -r '.outbounds[].tag // empty' "$local_cfg")"

derive_tag_from_fragment() {
  local f="$1"
  # Sanitize: keep only [A-Za-z0-9_-], replace others with dash, collapse, trim.
  printf '%s' "$f" | tr ' ' '-' | sed 's/[^A-Za-z0-9_-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

if [ -z "$tag" ]; then
  if [ -n "$v_frag" ]; then
    tag="$(derive_tag_from_fragment "$v_frag")"
  fi
  if [ -z "$tag" ] || ! printf '%s' "$tag" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    # Fallback: vpn-N
    n=1
    while printf '%s\n' "$existing_tags" | grep -Fxq "vpn-$n"; do
      n=$((n + 1))
    done
    tag="vpn-$n"
  fi
fi

# Final tag sanity.
if ! printf '%s' "$tag" | grep -qE '^[a-zA-Z0-9_-]+$'; then
  echo "add-vpn: итоговый --tag '$tag' невалиден" >&2
  exit 13
fi

# Conflict check.
if printf '%s\n' "$existing_tags" | grep -Fxq "$tag"; then
  if [ "$force" != "1" ]; then
    echo "add-vpn: tag '$tag' уже есть в config.json (используй --force чтобы перезаписать или --tag <другой>)" >&2
    exit 13
  fi
fi

# Validate proxy port not already used.
if [ -n "$proxy_port" ]; then
  used="$(jq -r --arg p "$proxy_port" '.inbounds[]? | select(.listen_port == ($p|tonumber)) | .tag' "$local_cfg")"
  if [ -n "$used" ]; then
    echo "add-vpn: порт $proxy_port уже занят inbound'ом '$used'" >&2
    exit 13
  fi
fi

# ---------------------------------------------------------------------------
# Pre-backup
# ---------------------------------------------------------------------------
# Hard-fail if backup-now.sh isn't available or returns non-zero. No inline
# fallback: previous fallback wrote DIRECTORIES under /etc/vpn-kit/snapshots
# that were invisible to restore.sh / snapshot-list.sh (flat $id.tar.gz layout).
snapshot_id=""
if [ "$no_backup" = "1" ]; then
  snapshot_id="(no-backup)"
else
  if [ ! -x "$OPENWRT_SKILL_HOME/bin/backup-now.sh" ]; then
    echo "add-vpn: backup-now.sh не найден в $OPENWRT_SKILL_HOME/bin/ — починить перед использованием add/remove-vpn/proxy" >&2
    exit 2
  fi
  if ! snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" --label "before add-vpn $tag" --quiet)"; then
    echo "add-vpn: backup-now.sh failed — отказываюсь продолжать без снапшота" >&2
    exit 2
  fi
fi

# rollback_inline — delegate to restore.sh (flat snapshot layout).
rollback_inline() {
  [ -z "$snapshot_id" ] && return 0
  [ "$snapshot_id" = "(no-backup)" ] && {
    echo "add-vpn: rollback не возможен — запуск был с --no-backup" >&2
    return 0
  }
  echo "add-vpn: пытаюсь откатить из snapshot $snapshot_id ..." >&2
  if [ -x "$OPENWRT_SKILL_HOME/bin/restore.sh" ]; then
    "$OPENWRT_SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" --snapshot "$snapshot_id" >/dev/null 2>&1 || true
  else
    echo "add-vpn: restore.sh отсутствует — ручной откат необходим" >&2
  fi
}

# ---------------------------------------------------------------------------
# Build the new config.json with jq
# ---------------------------------------------------------------------------
# We pass secrets to jq via --arg (which is safe — jq just reads argv, doesn't
# log). Output goes to local tmpfile, never to stdout.
# Resolve --country to pool tag (e.g. usa → usa-pool).
pool_tag=""
if [ -n "$country" ]; then
  pool_tag="$(resolve_country_to_pool "$ROUTER_ALIAS" "$country")"
  # If resolve returned input unchanged and it looks like a bare country code, warn.
  if [ "$pool_tag" = "$country" ] && ! printf '%s' "$country" | grep -qE 'pool$'; then
    echo "add-vpn: --country '$country' не найден в countries.yaml; pool не будет обновлён" >&2
  fi
fi

jq_failed=0
jq \
  --arg tag "$tag" \
  --arg server "$v_host" \
  --argjson server_port "$v_port" \
  --arg uuid "$v_uuid" \
  --arg flow "$v_flow" \
  --arg sni "$v_sni" \
  --arg fp "$v_fp" \
  --arg pbk "$v_pbk" \
  --arg sid "$v_sid" \
  --argjson add_failover "$add_to_failover" \
  --arg proxy_port_str "$proxy_port" \
  --arg pool_tag "$pool_tag" \
  '
    # Remove any pre-existing outbound with the same tag (force/idempotent).
    .outbounds = ((.outbounds // []) | map(select((.tag // "") != $tag)))

    # Append the new vless outbound.
    | .outbounds += [{
        type: "vless",
        tag: $tag,
        server: $server,
        server_port: $server_port,
        uuid: $uuid,
        flow: $flow,
        tls: {
          enabled: true,
          server_name: $sni,
          utls: { enabled: true, fingerprint: $fp },
          reality: { enabled: true, public_key: $pbk, short_id: $sid }
        }
      }]

    # Add to auto-failover.outbounds if requested AND no pool is being used.
    # When --country is given, the node goes into the pool; the pool is in auto-failover.
    | (if ($add_failover == 1) and (($pool_tag | length) == 0) then
         .outbounds = (.outbounds | map(
           if (.type == "urltest" and .tag == "auto-failover") then
             .outbounds = ((.outbounds // []) + [$tag] | unique)
           else . end
         ))
       else . end)

    # Add to country pool if --country was given.
    | (if ($pool_tag | length) > 0 then
         if any(.outbounds[]?; .tag == $pool_tag) then
           # Pool exists: append node tag to its outbounds
           .outbounds = (.outbounds | map(
             if (.type == "urltest" and .tag == $pool_tag) then
               .outbounds = ((.outbounds // []) + [$tag] | unique)
             else . end
           ))
         else
           # Pool does not exist yet: create it
           .outbounds = (.outbounds + [{
             "type": "urltest",
             "tag": $pool_tag,
             "outbounds": [$tag],
             "url": "https://www.gstatic.com/generate_204",
             "interval": "3m",
             "tolerance": 500
           }])
           # Also add pool to auto-failover if it exists
           | .outbounds = (.outbounds | map(
               if (.type == "urltest" and .tag == "auto-failover") then
                 .outbounds = ((.outbounds // []) + [$pool_tag] | unique)
               else . end
             ))
         end
       else . end)

    # Optional mixed inbound + route rule.
    | (if ($proxy_port_str | length) > 0 then
         (.inbounds = ((.inbounds // []) + [{
            type: "mixed",
            tag: ("in-proxy-" + $proxy_port_str),
            listen: "192.168.1.1",
            listen_port: ($proxy_port_str | tonumber),
            sniff: true
          }]))
         | (.route = (.route // {}))
         | (.route.rules = (.route.rules // []))
         # Insert route rule BEFORE any auto-failover catch-all (action=route + outbound=auto-failover with no other matchers).
         | (.route.rules =
             (
               (.route.rules
                 | map(select(
                     ((.outbound // "") != "auto-failover")
                     or ((.inbound // null) != null)
                     or ((.domain // null) != null)
                     or ((.domain_suffix // null) != null)
                     or ((.rule_set // null) != null)
                     or ((.source_ip_cidr // null) != null)
                   ))
               )
               + [{
                   action: "route",
                   inbound: [("in-proxy-" + $proxy_port_str)],
                   outbound: $tag
                 }]
               +
               (
                 .route.rules
                   | map(select(
                       ((.outbound // "") == "auto-failover")
                       and ((.inbound // null) == null)
                       and ((.domain // null) == null)
                       and ((.domain_suffix // null) == null)
                       and ((.rule_set // null) == null)
                       and ((.source_ip_cidr // null) == null)
                     ))
               )
             ))
       else . end)
  ' "$local_cfg" > "$local_new_cfg" || jq_failed=1

if [ "$jq_failed" = "1" ] || ! jq -e '.outbounds' "$local_new_cfg" >/dev/null 2>&1; then
  echo "add-vpn: jq не смог собрать новый config.json" >&2
  rollback_inline
  exit 13
fi

# ---------------------------------------------------------------------------
# Upload + sing-box check + atomic mv
# ---------------------------------------------------------------------------
remote_new="/tmp/openwrt-skill-config-new.$$.json"

if ! scp_to "$local_new_cfg" "$remote_new" >/dev/null 2>&1; then
  echo "add-vpn: scp нового config.json не удался" >&2
  rollback_inline
  exit 2
fi

if ! ssh_run "sing-box check -c $remote_new" >/dev/null 2>&1; then
  echo "add-vpn: 'sing-box check' зафейлился на новом config'е — отмена" >&2
  ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
  rollback_inline
  exit 13
fi

# Atomic mv on router.
if ! ssh_run "chmod 600 $remote_new && mv -f $remote_new $remote_cfg" >/dev/null 2>&1; then
  echo "add-vpn: не смог mv $remote_new → $remote_cfg" >&2
  ssh_run "rm -f $remote_new" >/dev/null 2>&1 || true
  rollback_inline
  exit 2
fi

# ---------------------------------------------------------------------------
# zapret2 integration (idempotent)
# ---------------------------------------------------------------------------
# zapret2 (remittor) excludes IPs from desync via a plain ip-list file, not an
# nft set. We add the VPN server IP to /opt/zapret2/ipset/zapret-ip-user-exclude.txt
# so nfqws2 leaves the tunnel handshake untouched.
zapret_path="/etc/init.d/zapret2"
zapret_exclude_file="/opt/zapret2/ipset/zapret-ip-user-exclude.txt"

# Resolve hostname → IP server-side if not already an IP.
# v_host is shape-validated at parse time, but we still escape via printf %q
# before interpolating into the remote shell — defense in depth.
zapret_ip=""
case "$v_host" in
  *[!0-9.]*)
    v_host_q="$(printf '%q' "$v_host")"
    zapret_ip="$(ssh_run "nslookup $v_host_q 2>/dev/null | awk '/^Address[ :]/{ip=\$NF} END{if(ip)print ip}'" 2>/dev/null || true)"
    # Validate the looked-up address: only digits and dots, and must look v4.
    case "$zapret_ip" in
      ''|*[!0-9.]*)
        echo "add-vpn: zapret IP lookup failed or invalid: '$zapret_ip'" >&2
        exit 13
        ;;
    esac
    if ! printf '%s' "$zapret_ip" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      echo "add-vpn: zapret IP malformed: '$zapret_ip'" >&2
      exit 13
    fi
    ;;
  *)
    zapret_ip="$v_host"
    ;;
esac

if ssh_run "[ -f $zapret_path ]" >/dev/null 2>&1; then
  if [ -n "$zapret_ip" ]; then
    # Idempotent: append IP to zapret-ip-user-exclude.txt if missing, then restart
    # zapret2 so nfqws2 reloads the exclude list. zapret_ip is regex-validated
    # above (v4 only) so direct interpolation into the remote shell is safe.
    ssh_run "
      set -eu
      ip='$zapret_ip'
      f='$zapret_exclude_file'
      [ -f \"\$f\" ] || : > \"\$f\"
      if ! grep -qxF \"\$ip\" \"\$f\"; then
        printf '%s\\n' \"\$ip\" >> \"\$f\"
      fi
      /etc/init.d/zapret2 restart >/dev/null 2>&1 || true
    " >/dev/null 2>&1 || echo "add-vpn: WARN — zapret2 ip-exclude правка не удалась полностью (не критично)" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Staged-apply restart with reachability watch + auto-rollback
# ---------------------------------------------------------------------------
restart_failed=0
ssh_run "/etc/init.d/sing-box-tproxy restart" >/dev/null 2>&1 || restart_failed=1

# Poll SSH reachability for 30s.
reachable=0
end=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$end" ]; do
  if ssh_check_alive 3; then
    reachable=1
    break
  fi
  sleep 2
done

if [ "$restart_failed" = "1" ] || [ "$reachable" != "1" ]; then
  echo "add-vpn: restart/reachability fail — катываем" >&2
  rollback_inline
  exit 20
fi

# Quick sanity: sing-box status running.
if ! ssh_run "/etc/init.d/sing-box-tproxy status >/dev/null 2>&1 || pgrep -f sing-box >/dev/null" >/dev/null 2>&1; then
  echo "add-vpn: sing-box не запустился после restart — катываем" >&2
  rollback_inline
  exit 20
fi

# ---------------------------------------------------------------------------
# Sync vpn-nodes-watchdog NODES= list on router
# ---------------------------------------------------------------------------
sync_vpn_nodes_watchdog "$ROUTER_ALIAS"

# ---------------------------------------------------------------------------
# Update memory tables (NO secrets — only tag, host:port, region?, proxy port)
# ---------------------------------------------------------------------------
mem_dir="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"
vpns_md="$mem_dir/vpns.md"
proxies_md="$mem_dir/proxies.md"

# Journal first (atomic single-file append), then per-router flock around MD edits.
# ---------------------------------------------------------------------------
# Journal (NEVER pass uuid/pbk/sid/sni — helper rejects keys like *uuid* anyway)
# ---------------------------------------------------------------------------
journal_args=(
  "tag=$tag"
  "host=$v_host"
  "port=$v_port"
  "added_to_failover=$( [ "$add_to_failover" = "1" ] && echo true || echo false )"
)
[ -n "$proxy_port" ] && journal_args+=("proxy_port=$proxy_port")
[ -n "$snapshot_id" ] && journal_args+=("snapshot_before=$snapshot_id")

memory_journal_append "$ROUTER_ALIAS" "add_vpn" "${journal_args[@]}" || \
  echo "add-vpn: WARN — не смог записать journal" >&2

# Now serialise the markdown table mutations via per-router flock.
mem_lock="$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS/.lock"
mkdir -p "$OPENWRT_SKILL_MEMORY/$ROUTER_ALIAS"
touch "$mem_lock"
{
  flock -x -w 5 9 || { echo "add-vpn: не могу взять lock на memory" >&2; exit 12; }

  if [ -f "$vpns_md" ]; then
    in_fo="no"; [ "$add_to_failover" = "1" ] && in_fo="yes"
    proxy_cell="—"
    [ -n "$proxy_port" ] && proxy_cell="$proxy_port"
    row="| $tag | vless | $v_host:$v_port | ? | $in_fo | $proxy_cell |"

    if grep -q '{{VPN_TABLE_ROWS}}' "$vpns_md"; then
      tmp="$(mktemp)"
      awk -v r="$row" '{
        if ($0 ~ /\{\{VPN_TABLE_ROWS\}\}/) { print r } else { print }
      }' "$vpns_md" > "$tmp" && mv "$tmp" "$vpns_md"
    elif grep -qE '^\| (нет|_\(пока пусто.*\)_) ' "$vpns_md" 2>/dev/null; then
      tmp="$(mktemp)"
      awk -v r="$row" 'BEGIN{done=0}
        { if (!done && $0 ~ /_\(пока пусто/) { print r; done=1 } else { print } }
        END{ if (!done) print r }
      ' "$vpns_md" > "$tmp" && mv "$tmp" "$vpns_md"
    else
      tmp="$(mktemp)"
      awk -v r="$row" 'BEGIN{last=-1}
        /^\|/ { last=NR }
        { lines[NR]=$0 }
        END {
          for(i=1;i<=NR;i++) {
            print lines[i]
            if (i==last) print r
          }
          if (last==-1) print r
        }
      ' "$vpns_md" > "$tmp" && mv "$tmp" "$vpns_md"
    fi
  fi

  if [ -n "$proxy_port" ] && [ -f "$proxies_md" ]; then
    prow="| $proxy_port | $tag | через $tag | 192.168.1.1 |"
    if grep -q '{{PROXY_TABLE_ROWS}}' "$proxies_md"; then
      tmp="$(mktemp)"
      awk -v r="$prow" '{
        if ($0 ~ /\{\{PROXY_TABLE_ROWS\}\}/) { print r } else { print }
      }' "$proxies_md" > "$tmp" && mv "$tmp" "$proxies_md"
    elif grep -qE '_\(пока пусто' "$proxies_md" 2>/dev/null; then
      tmp="$(mktemp)"
      awk -v r="$prow" 'BEGIN{done=0}
        { if (!done && $0 ~ /_\(пока пусто/) { print r; done=1 } else { print } }
        END{ if (!done) print r }
      ' "$proxies_md" > "$tmp" && mv "$tmp" "$proxies_md"
    else
      tmp="$(mktemp)"
      awk -v r="$prow" 'BEGIN{last=-1}
        /^\|/ { last=NR }
        { lines[NR]=$0 }
        END {
          for(i=1;i<=NR;i++) {
            print lines[i]
            if (i==last) print r
          }
          if (last==-1) print r
        }
      ' "$proxies_md" > "$tmp" && mv "$tmp" "$proxies_md"
    fi
  fi
} 9>"$mem_lock"

# Clear secrets from shell for hygiene (best effort).
v_uuid=""; v_pbk=""; v_sid=""; v_sni=""

cat >&2 <<EOF

add-vpn: успех — добавлен outbound '$tag' (host=$v_host:$v_port).
  в auto-failover: $( [ "$add_to_failover" = "1" ] && echo "да" || echo "нет" )
  mixed inbound:   $( [ -n "$proxy_port" ] && echo ":$proxy_port → $tag" || echo "не добавлен" )

Следующий шаг:
  bin/health.sh --router $ROUTER_ALIAS
  bin/add-domain.sh --router $ROUTER_ALIAS --domain <name> [--outbound $tag]
EOF
exit 0
