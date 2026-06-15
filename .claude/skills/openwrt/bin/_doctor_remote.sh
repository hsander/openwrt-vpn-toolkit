#!/bin/sh
# bin/_doctor_remote.sh — runs on the router via SSH stdin. Emits JSON to stdout.
# POSIX/busybox safe. No bash-isms.

# Note: we DO NOT use 'set -e' — every probe should run independently and report
# whatever it finds. Failures of individual checks must NOT abort the whole probe.

# ---------- helpers ----------
json_escape() {
  # stdin -> stdout, escapes \, ", \n, \r, \t
  awk 'BEGIN { ORS = "" }
       {
         gsub(/\\/, "\\\\")
         gsub(/"/, "\\\"")
         gsub(/\r/, "\\r")
         gsub(/\t/, "\\t")
         if (NR > 1) printf("\\n")
         printf("%s", $0)
       }'
}

b() {
  # 1 -> "true", 0 -> "false"
  [ "$1" = "1" ] && echo "true" || echo "false"
}

j_str() { printf '"%s"' "$(printf '%s' "$1" | json_escape)"; }
j_num() {
  case "$1" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------- probe ----------

openwrt_release_file=/etc/openwrt_release
openwrt_version=""
openwrt_target=""
if [ -f "$openwrt_release_file" ]; then
  openwrt_version="$(awk -F\' '/DISTRIB_RELEASE/ {print $2}' "$openwrt_release_file" 2>/dev/null)"
  openwrt_target="$(awk -F\' '/DISTRIB_TARGET/ {print $2}' "$openwrt_release_file" 2>/dev/null)"
fi

arch="$(uname -m 2>/dev/null)"
ram_mb="$(awk '/^MemTotal/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null)"

# Package install check — apk on 24.10+, opkg fallback
if command -v apk >/dev/null 2>&1; then
  pkg_check() { apk info --installed "$1" >/dev/null 2>&1; }
  pkg_mgr="apk"
elif command -v opkg >/dev/null 2>&1; then
  pkg_check() { opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; }
  pkg_mgr="opkg"
else
  pkg_check() { return 1; }
  pkg_mgr="unknown"
fi

pkg_singbox=0;     pkg_check sing-box && pkg_singbox=1
pkg_httpsdns=0;    pkg_check https-dns-proxy && pkg_httpsdns=1
pkg_nft_tproxy=0;  pkg_check kmod-nft-tproxy && pkg_nft_tproxy=1
pkg_nft_queue=0;   pkg_check kmod-nft-queue && pkg_nft_queue=1
pkg_jq=0;          pkg_check jq && pkg_jq=1
pkg_curl=0;        pkg_check curl && pkg_curl=1

singbox_version=""
if command -v sing-box >/dev/null 2>&1; then
  singbox_version="$(sing-box version 2>/dev/null | awk 'NR==1 {print $NF}')"
fi

# sing-box config
config_present=0; [ -f /etc/sing-box/config.json ] && config_present=1
config_valid=0
if [ "$config_present" = "1" ] && command -v sing-box >/dev/null 2>&1; then
  sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 && config_valid=1
fi

# rules: соберём ВСЕ *.json в /etc/sing-box/rules/, не хардкодим конкретное имя.
# Реальные роутеры держат там user-vpn-domains.json, tg-pin-domains.json, pin-*.json, и т.п.
rules_present=0
rules_count=0
rules_files_json="[]"
if [ -d /etc/sing-box/rules ]; then
  # POSIX glob: если совпадений нет, цикл не отработает (мы фильтруем -f).
  _rules_acc=""
  for _rf in /etc/sing-box/rules/*.json; do
    [ -f "$_rf" ] || continue
    rules_count=$((rules_count + 1))
    _rf_base="${_rf##*/}"
    _rf_esc="$(printf '%s' "$_rf_base" | json_escape)"
    if [ -z "$_rules_acc" ]; then
      _rules_acc="\"$_rf_esc\""
    else
      _rules_acc="$_rules_acc,\"$_rf_esc\""
    fi
  done
  [ "$rules_count" -gt 0 ] && rules_present=1
  rules_files_json="[$_rules_acc]"
fi

# tproxy
tproxy_installed=0; [ -f /etc/init.d/sing-box-tproxy ] && tproxy_installed=1
tproxy_running=0
if [ "$tproxy_installed" = "1" ]; then
  /etc/init.d/sing-box-tproxy status >/dev/null 2>&1 && tproxy_running=1
fi

# Probe reliability flags. Если jq отсутствует или config битый — мы НЕ МОЖЕМ
# распарсить outbounds/inbounds/rule_set, и потребитель (doctor.sh, adopt.sh)
# должен видеть это явно, а не интерпретировать "0" как реальное отсутствие.
jq_present=0
command -v jq >/dev/null 2>&1 && jq_present=1

config_jq_parseable=0
if [ "$config_present" = "1" ] && [ "$jq_present" = "1" ]; then
  jq -e . /etc/sing-box/config.json >/dev/null 2>&1 && config_jq_parseable=1
fi

# probe_reliable: true только если все необходимые для парсинга условия выполнены.
# Если config'а нет — это НЕ degraded (отсутствие — это валидное состояние).
probe_reliable=1
degraded_reasons=""
add_degraded() {
  if [ -z "$degraded_reasons" ]; then
    degraded_reasons="\"$1\""
  else
    degraded_reasons="$degraded_reasons,\"$1\""
  fi
  probe_reliable=0
}
[ "$jq_present" = "0" ] && add_degraded "jq-missing-on-router"
if [ "$config_present" = "1" ] && [ "$jq_present" = "1" ] && [ "$config_jq_parseable" = "0" ]; then
  add_degraded "config-json-unparseable"
fi

# outbounds
outbound_count=0
outbound_tags=""
has_failover=0
if [ "$config_jq_parseable" = "1" ]; then
  outbound_count="$(jq -r '.outbounds | length' /etc/sing-box/config.json 2>/dev/null)"
  outbound_tags="$(jq -r '.outbounds | map(.tag) | join(",")' /etc/sing-box/config.json 2>/dev/null)"
  echo "$outbound_tags" | grep -q 'auto-failover' && has_failover=1
fi

# --- adopt-mode probe: structural detail (no secrets) ---------------------
# Defaults: empty arrays. Filled only when config.json exists AND jq parses it.
# STRICT secret hygiene: only tag/type/server/server_port for outbounds;
# only tag/type/listen/listen_port for inbounds. No uuid/password/keys.
outbounds_detail_json='[]'
inbounds_detail_json='[]'
rule_set_domains_json='[]'
config_proxy_ports_json='[]'
# v2 fields (additive): selector/urltest groups, inbound→outbound and domain→outbound maps.
# Same secret hygiene: only tags, types, domains, rule indices. No server/uuid/keys.
selector_groups_json='[]'
inbound_outbound_map_json='[]'
domain_outbound_map_json='[]'
# v3 fields: local rule_set file contents and rule_set→outbound route mapping.
# Same secret hygiene: only rule-set names, filenames, domains, match type and outbound tags.
rule_set_file_domains_json='[]'
rule_set_outbound_map_json='[]'
rule_set_file_tag_map_json='[]'

if [ "$config_jq_parseable" = "1" ]; then
  # outbounds_detail: keep ONLY tag/type/server/server_port.
  # Pick outbounds with a non-null tag (skip anything we can't cleanly identify).
  _od="$(jq -c '
    [
      (.outbounds // [])[]
      | select(type == "object")
      | select(.tag != null and .tag != "")
      | select(.type != null and .type != "")
      | {
          tag:         (.tag | tostring),
          type:        (.type | tostring),
          server:      (if (.server // null) == null then null else (.server | tostring) end),
          server_port: (if (.server_port // null) == null then 0 else (.server_port | tonumber? // 0) end)
        }
    ]
  ' /etc/sing-box/config.json 2>/dev/null)"
  [ -n "$_od" ] && outbounds_detail_json="$_od"

  # inbounds_detail: only mixed/socks/http; tag/type/listen/listen_port.
  _id="$(jq -c '
    [
      (.inbounds // [])[]
      | select(type == "object")
      | select(.type == "mixed" or .type == "socks" or .type == "http")
      | {
          tag:         ((.tag // "") | tostring),
          type:        (.type | tostring),
          listen:      ((.listen // "") | tostring),
          listen_port: ((.listen_port // 0) | tonumber? // 0)
        }
    ]
  ' /etc/sing-box/config.json 2>/dev/null)"
  [ -n "$_id" ] && inbounds_detail_json="$_id"

  # config_proxy_ports: flat int list, derived from inbounds_detail.
  _cp="$(printf '%s' "$_id" | jq -c '
    [ .[] | .listen_port | select(. != null and . != 0) ] | unique
  ' 2>/dev/null)"
  [ -n "$_cp" ] && config_proxy_ports_json="$_cp"

  # rule_set_domains: flatten any string under route.rules[].domain and
  # route.rule_set[..].domain (covers domain as string OR array of strings).
  _rd="$(jq -c '
    def flat_domains(x):
      if x == null then []
      elif (x | type) == "string" then [x]
      elif (x | type) == "array" then [ x[] | select(type == "string") ]
      else [] end;
    [
      ( (.route.rules // [])[]?     | flat_domains(.domain) ),
      ( (.route.rule_set // [])[]?  | flat_domains(.domain) )
    ] | flatten | unique
  ' /etc/sing-box/config.json 2>/dev/null)"
  [ -n "$_rd" ] && rule_set_domains_json="$_rd"

  # selector_groups: selector/urltest outbounds with their member list + failover knobs.
  # `default` falls back to first member when not set. No server addresses leaked.
  _sg="$(jq -c '
    [
      (.outbounds // [])[]
      | select(type == "object")
      | select(.type == "selector" or .type == "urltest")
      | {
          tag:                ((.tag // "") | tostring),
          type:               (.type | tostring),
          default:            (.default // ((.outbounds // [])[0] // null)),
          outbounds:          (.outbounds // []),
          failover_url:       (if .type == "urltest" then (.url // null)       else null end),
          failover_interval:  (if .type == "urltest" then (.interval // null)  else null end),
          failover_tolerance: (if .type == "urltest" then (.tolerance // null) else null end)
        }
    ]
  ' /etc/sing-box/config.json 2>/dev/null)"
  [ -n "$_sg" ] && [ "$_sg" != "null" ] && selector_groups_json="$_sg"

  # inbound_outbound_map: every (rule.inbound[i] -> rule.outbound) pair,
  # with fallback to .route.final when rule has no explicit outbound.
  # via_rule_index is the index into .route.rules (stable ordering).
  _iom="$(jq -c '
    . as $cfg
    | ($cfg.route.final // null) as $fallback
    | [
        ($cfg.route.rules // []) | to_entries[]
        | .key as $i
        | .value
        | select(type == "object")
        | select(((.inbound // []) | type) == "array")
        | select(((.inbound // []) | length) > 0)
        | (.outbound // $fallback) as $ob
        | (.inbound[])
        | select(type == "string")
        | {inbound_tag: ., outbound_tag: $ob, via_rule_index: $i}
      ]
  ' /etc/sing-box/config.json 2>/dev/null)"
  [ -n "$_iom" ] && [ "$_iom" != "null" ] && inbound_outbound_map_json="$_iom"

  # rule_set_outbound_map: every route.rules[] reference to a rule_set tag,
  # mapped to the rule outbound. This lets doctor resolve external rule-set
  # files like /etc/sing-box/rules/polsha-only-domains.json -> outbound polsha.
  _rsom="$(jq -c '
    . as $cfg
    | ($cfg.route.final // null) as $fallback
    | [
        ($cfg.route.rules // []) | to_entries[]
        | .key as $i
        | .value
        | select(type == "object")
        | (.outbound // $fallback) as $ob
        | (
            (.rule_set // [])
            | if type == "array" then . else [.] end
            | .[] | select(type == "string")
            | {rule_set: ., outbound_tag: $ob, via_rule_index: $i}
          )
      ]
  ' /etc/sing-box/config.json 2>/dev/null)"
  [ -n "$_rsom" ] && [ "$_rsom" != "null" ] && rule_set_outbound_map_json="$_rsom"

  # rule_set_file_tag_map: route.rule_set definitions bind tags to local files.
  # Use this instead of guessing tags from filenames: e.g. tag "polsha-only"
  # points to file "polsha-only-domains.json".
  _rsftm="$(jq -c '
    [
      (.route.rule_set // [])[]
      | select(type == "object")
      | select(.tag != null and .tag != "")
      | select(.path != null and .path != "")
      | {
          tag: (.tag | tostring),
          file: ((.path | tostring) | split("/")[-1])
        }
    ]
  ' /etc/sing-box/config.json 2>/dev/null)"
  [ -n "$_rsftm" ] && [ "$_rsftm" != "null" ] && rule_set_file_tag_map_json="$_rsftm"

  # rule_set_file_domains: read local rule-set files from /etc/sing-box/rules.
  # Files can contain sing-box JSONC-style comment-only lines, so strip those
  # before jq. Only public domain matcher values are emitted.
  _rsfd='[]'
  if [ -d /etc/sing-box/rules ]; then
    for _rf in /etc/sing-box/rules/*.json; do
      [ -f "$_rf" ] || continue
      _rf_base="${_rf##*/}"
      _rs_tag="$(printf '%s' "$rule_set_file_tag_map_json" | jq -r --arg file "$_rf_base" '
        (map(select(.file == $file))[0].tag // "")
      ' 2>/dev/null)"
      [ -n "$_rs_tag" ] || _rs_tag="${_rf_base%.json}"
      _one="$(
        sed '/^[[:space:]]*\/\//d' "$_rf" 2>/dev/null | jq -c \
          --arg rule_set "$_rs_tag" \
          --arg file "$_rf_base" \
          '
            def vals(x):
              if x == null then []
              elif (x | type) == "string" then [x]
              elif (x | type) == "array" then [ x[] | select(type == "string") ]
              else [] end;
            [
              (.rules // [])[]?
              | (
                  ( vals(.domain)         | .[] | {domain: ., match_type: "domain"} ),
                  ( vals(.domain_suffix)  | .[] | {domain: ., match_type: "domain_suffix"} ),
                  ( vals(.domain_keyword) | .[] | {domain: ., match_type: "domain_keyword"} ),
                  ( vals(.domain_regex)   | .[] | {domain: ., match_type: "domain_regex"} )
                )
              | . + {rule_set: $rule_set, file: $file}
            ]
          ' 2>/dev/null
      )"
      [ -n "$_one" ] && [ "$_one" != "null" ] || continue
      _merged="$(jq -cn --argjson a "$_rsfd" --argjson b "$_one" '$a + $b' 2>/dev/null)"
      [ -n "$_merged" ] && _rsfd="$_merged"
    done
  fi
  rule_set_file_domains_json="$_rsfd"

  # domain_outbound_map: flatten domain / domain_suffix / domain_keyword / domain_regex
  # from inline .route.rules[], then merge domains read from local rule_set files.
  _dom="$(jq -c '
    . as $cfg
    | ($cfg.route.final // null) as $fallback
    | [
        ($cfg.route.rules // []) | to_entries[]
        | .key as $i
        | .value
        | select(type == "object")
        | (.outbound // $fallback) as $ob
        | (
            ( (.domain         // []) | (if type == "array" then . else [.] end)
              | .[] | select(type == "string")
              | {domain: ., match_type: "domain",         outbound_tag: $ob, via_rule_index: $i} ),
            ( (.domain_suffix  // []) | (if type == "array" then . else [.] end)
              | .[] | select(type == "string")
              | {domain: ., match_type: "domain_suffix",  outbound_tag: $ob, via_rule_index: $i} ),
            ( (.domain_keyword // []) | (if type == "array" then . else [.] end)
              | .[] | select(type == "string")
              | {domain: ., match_type: "domain_keyword", outbound_tag: $ob, via_rule_index: $i} ),
            ( (.domain_regex   // []) | (if type == "array" then . else [.] end)
              | .[] | select(type == "string")
              | {domain: ., match_type: "domain_regex",   outbound_tag: $ob, via_rule_index: $i} )
          )
      ]
  ' /etc/sing-box/config.json 2>/dev/null)"
  [ -n "$_dom" ] && [ "$_dom" != "null" ] || _dom='[]'

  # Add file-backed rule_set domains to domain_outbound_map. If the config has
  # several route rules referencing the same rule_set, emit one row per route.
  _file_dom="$(jq -cn \
    --argjson files "$rule_set_file_domains_json" \
    --argjson routes "$rule_set_outbound_map_json" \
    '
      [
        $files[]? as $f
        | ([ $routes[]? | select(.rule_set == $f.rule_set) ]) as $rs
        | if ($rs | length) > 0 then
            $rs[]
            | {
                domain: $f.domain,
                match_type: $f.match_type,
                outbound_tag: .outbound_tag,
                via_rule_index: .via_rule_index,
                rule_set: $f.rule_set,
                rule_set_file: $f.file
              }
          else
            {
              domain: $f.domain,
              match_type: $f.match_type,
              outbound_tag: null,
              via_rule_index: null,
              rule_set: $f.rule_set,
              rule_set_file: $f.file
            }
          end
      ]
    ' 2>/dev/null)"
  [ -n "$_file_dom" ] && [ "$_file_dom" != "null" ] || _file_dom='[]'

  _combined_dom="$(jq -cn --argjson inline "$_dom" --argjson files "$_file_dom" '$inline + $files' 2>/dev/null)"
  [ -n "$_combined_dom" ] && [ "$_combined_dom" != "null" ] && domain_outbound_map_json="$_combined_dom"

  _combined_rule_set_domains="$(jq -cn \
    --argjson inline "$rule_set_domains_json" \
    --argjson files "$rule_set_file_domains_json" \
    '($inline + ($files | map(.domain))) | unique' 2>/dev/null)"
  [ -n "$_combined_rule_set_domains" ] && [ "$_combined_rule_set_domains" != "null" ] && rule_set_domains_json="$_combined_rule_set_domains"
fi

# DNS chain
peerdns="$(uci -q get network.wan.peerdns 2>/dev/null)"
[ -z "$peerdns" ] && peerdns="?"
dnsmasq_server="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)"
[ -z "$dnsmasq_server" ] && dnsmasq_server="?"
httpsdns_port="$(uci -q get https-dns-proxy.@https-dns-proxy[0].listen_port 2>/dev/null)"
[ -z "$httpsdns_port" ] && httpsdns_port="?"
dns_redirect_present=0
[ -f /etc/nftables.d/10-dns-redirect.nft ] && dns_redirect_present=1

# zapret2 (remittor) — opt path /opt/zapret2, init /etc/init.d/zapret2
zapret_installed=0
[ -d /opt/zapret2 ] && zapret_installed=1
zapret_running=0
if [ "$zapret_installed" = "1" ] && [ -f /etc/init.d/zapret2 ]; then
  /etc/init.d/zapret2 status >/dev/null 2>&1 && zapret_running=1
fi

# watchdog
watchdog_conf_present=0
watchdog_conf_mode=""
if [ -f /etc/router-watchdog.conf ]; then
  watchdog_conf_present=1
  watchdog_conf_mode="$(stat -c %a /etc/router-watchdog.conf 2>/dev/null)"
  [ -z "$watchdog_conf_mode" ] && watchdog_conf_mode="$(stat -f %A /etc/router-watchdog.conf 2>/dev/null)"
fi
watchdog_cron_count="$(crontab -l 2>/dev/null | grep -c 'watchdog' 2>/dev/null)"
[ -z "$watchdog_cron_count" ] && watchdog_cron_count=0

# fakeip cache
fakeip_cache_present=0
[ -f /usr/share/sing-box/cache.db ] && fakeip_cache_present=1

# skill state
skill_state_present=0
[ -f /etc/vpn-kit/install-state.json ] && skill_state_present=1

# snapshots
snapshot_count=0
if [ -d /etc/vpn-kit/snapshots ]; then
  snapshot_count="$(ls /etc/vpn-kit/snapshots 2>/dev/null | wc -l | awk '{print $1}')"
fi

probed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
hostname="$(uname -n 2>/dev/null)"

# ---------- emit JSON ----------
printf '{\n'
printf '  "hostname": %s,\n' "$(j_str "$hostname")"
printf '  "openwrt_version": %s,\n' "$(j_str "$openwrt_version")"
printf '  "openwrt_target": %s,\n' "$(j_str "$openwrt_target")"
printf '  "arch": %s,\n' "$(j_str "$arch")"
printf '  "ram_mb": %s,\n' "$(j_num "$ram_mb")"
printf '  "package_manager": %s,\n' "$(j_str "$pkg_mgr")"
printf '  "packages": {\n'
printf '    "sing-box": %s,\n' "$(b "$pkg_singbox")"
printf '    "https-dns-proxy": %s,\n' "$(b "$pkg_httpsdns")"
printf '    "kmod-nft-tproxy": %s,\n' "$(b "$pkg_nft_tproxy")"
printf '    "kmod-nft-queue": %s,\n' "$(b "$pkg_nft_queue")"
printf '    "jq": %s,\n' "$(b "$pkg_jq")"
printf '    "curl": %s\n' "$(b "$pkg_curl")"
printf '  },\n'
printf '  "singbox_version": %s,\n' "$(j_str "$singbox_version")"
printf '  "config": {\n'
printf '    "present": %s,\n' "$(b "$config_present")"
printf '    "valid": %s,\n' "$(b "$config_valid")"
printf '    "outbound_count": %s,\n' "$(j_num "$outbound_count")"
printf '    "outbound_tags": %s,\n' "$(j_str "$outbound_tags")"
printf '    "has_auto_failover": %s\n' "$(b "$has_failover")"
printf '  },\n'
printf '  "rules": { "present": %s, "count": %s, "files": %s },\n' "$(b "$rules_present")" "$(j_num "$rules_count")" "$rules_files_json"
printf '  "tproxy": { "installed": %s, "running": %s },\n' "$(b "$tproxy_installed")" "$(b "$tproxy_running")"
printf '  "dns": {\n'
printf '    "peerdns": %s,\n' "$(j_str "$peerdns")"
printf '    "dnsmasq_server": %s,\n' "$(j_str "$dnsmasq_server")"
printf '    "httpsdns_port": %s,\n' "$(j_str "$httpsdns_port")"
printf '    "redirect_nft_present": %s\n' "$(b "$dns_redirect_present")"
printf '  },\n'
printf '  "zapret": { "installed": %s, "running": %s },\n' "$(b "$zapret_installed")" "$(b "$zapret_running")"
printf '  "watchdog": {\n'
printf '    "conf_present": %s,\n' "$(b "$watchdog_conf_present")"
printf '    "conf_mode": %s,\n' "$(j_str "$watchdog_conf_mode")"
printf '    "cron_count": %s\n' "$(j_num "$watchdog_cron_count")"
printf '  },\n'
printf '  "fakeip_cache_present": %s,\n' "$(b "$fakeip_cache_present")"
printf '  "skill_state_present": %s,\n' "$(b "$skill_state_present")"
printf '  "snapshot_count": %s,\n' "$(j_num "$snapshot_count")"
printf '  "probed_at": %s,\n' "$(j_str "$probed_at")"
printf '  "probe_reliable": %s,\n' "$(b "$probe_reliable")"
printf '  "degraded_reasons": [%s],\n' "$degraded_reasons"
printf '  "outbounds_detail": %s,\n' "$outbounds_detail_json"
printf '  "inbounds_detail": %s,\n' "$inbounds_detail_json"
printf '  "rule_set_domains": %s,\n' "$rule_set_domains_json"
printf '  "config_proxy_ports": %s,\n' "$config_proxy_ports_json"
printf '  "probe_schema_version": 3,\n'
printf '  "selector_groups": %s,\n' "$selector_groups_json"
printf '  "inbound_outbound_map": %s,\n' "$inbound_outbound_map_json"
printf '  "rule_set_file_domains": %s,\n' "$rule_set_file_domains_json"
printf '  "rule_set_outbound_map": %s,\n' "$rule_set_outbound_map_json"
printf '  "rule_set_file_tag_map": %s,\n' "$rule_set_file_tag_map_json"
printf '  "domain_outbound_map": %s\n' "$domain_outbound_map_json"
printf '}\n'
