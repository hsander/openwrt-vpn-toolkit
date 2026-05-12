#!/bin/sh
# install-minimal.sh — install the first minimal profile file set.
#
# Usage:
#   install-minimal.sh (--vless-url <url> | --vless-url-file <path>)
#                      [--root <target-root>] [--writer <id>]
#                      [--node-name <name>] [--listen <ip>] [--port <port>]
#                      [--activate] [--skip-packages] [--test-direct-outbound]
#
# Prefer --vless-url-file: URL остаётся в файле (chmod 600), не попадает в argv
# (видимое через ps/auditd). --vless-url оставлен только для локальных тестов.
#
# With --root this performs an offline install into a target root for tests.
# Without --root it uses staged-apply for the file changes. With --activate it
# installs packages, applies firewall/cron/service activation, and verifies the
# sing-box config before committing the activation step. Root installs simulate
# activation and record the command plan without touching host services.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"
# shellcheck source=../lib/vpn-kit-common.sh
. "$LIB_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

target_root="${VPN_KIT_TARGET_ROOT:-}"
writer="claude-code@install-minimal"
vless_url=""
vless_url_file=""
node_name="vpn-node-1"
listen="0.0.0.0"
port="4000"
activate=0
skip_packages=0
packages="sing-box jq curl ca-bundle"
test_direct_outbound=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) target_root="${2:-}"; shift 2 ;;
    --writer) writer="${2:-}"; shift 2 ;;
    --vless-url) vless_url="${2:-}"; shift 2 ;;
    --vless-url-file) vless_url_file="${2:-}"; shift 2 ;;
    --node-name) node_name="${2:-}"; shift 2 ;;
    --listen) listen="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --activate) activate=1; shift ;;
    --skip-packages) skip_packages=1; shift ;;
    --test-direct-outbound) test_direct_outbound=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "install-minimal: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

# Exactly one of --vless-url / --vless-url-file is required. install-minimal сам
# URL не парсит — пробрасывает в render-minimal-config.sh. При файле передаём
# --vless-url-file (URL не появляется в argv ни одного процесса).
if [ -n "$vless_url" ] && [ -n "$vless_url_file" ]; then
  echo "install-minimal: --vless-url и --vless-url-file одновременно — выбери один" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi
if [ -z "$vless_url" ] && [ -z "$vless_url_file" ]; then
  echo "install-minimal: --vless-url или --vless-url-file обязателен" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi
if [ -n "$vless_url_file" ] && [ ! -r "$vless_url_file" ]; then
  echo "install-minimal: --vless-url-file '$vless_url_file' не читается" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi
vpn_kit_validate_writer_id "$writer" || { echo "install-minimal: invalid writer" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
case "$port" in ''|*[!0-9]*) echo "install-minimal: --port must be integer" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;; esac

export VPN_KIT_TARGET_ROOT="$target_root"

state_file="$(vpn_kit_target_path /etc/vpn-kit/install-state.json)"
state_dir="$(vpn_kit_target_path /etc/vpn-kit)"
sing_box_dir="$(vpn_kit_target_path /etc/sing-box)"
sing_box_config="$(vpn_kit_target_path /etc/sing-box/config.json)"
sing_box_init="$(vpn_kit_target_path /etc/init.d/sing-box-tproxy)"
dns_watchdog="$(vpn_kit_target_path /usr/bin/dns-watchdog.sh)"
vpn_watchdog="$(vpn_kit_target_path /usr/bin/vpn-nodes-watchdog.sh)"
firewall_rule="$(vpn_kit_target_path /etc/vpn-kit/firewall/lan-proxy-${port}.uci)"
dnsmasq_additions="$(vpn_kit_target_path /etc/vpn-kit/dnsmasq-additions.conf)"
cron_file="$(vpn_kit_target_path /etc/vpn-kit/cron/minimal.crontab)"
activation_log="$(vpn_kit_target_path /etc/vpn-kit/activation/minimal.commands.log)"
cache_file="/usr/share/sing-box/cache.db"

if [ ! -f "$state_file" ]; then
  "$SCRIPT_DIR/install-safety.sh" ${target_root:+--root "$target_root"} --writer "$writer" >/dev/null
fi

tmpdir="$(mktemp -d -t vpnkit-minimal.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM
payload="$tmpdir/payload"
mkdir -p "$payload/etc/sing-box" "$payload/etc/init.d" "$payload/usr/bin" "$payload/etc/vpn-kit/firewall" "$payload/etc/vpn-kit/cron"

# Пробрасываем URL дальше тем же способом, каким получили. Если работаем с
# --vless-url-file — файл (chmod 600) читается ТОЛЬКО внутри render-minimal-config.sh,
# в argv install-minimal'а его нет, в argv render-minimal-config'а — только путь.
if [ -n "$vless_url_file" ]; then
  set -- --vless-url-file "$vless_url_file"
else
  set -- --vless-url "$vless_url"
fi

if [ "$test_direct_outbound" = "1" ]; then
  "$SCRIPT_DIR/render-minimal-config.sh" \
    "$@" \
    --node-name "$node_name" \
    --listen "$listen" \
    --port "$port" \
    --cache-file "$cache_file" \
    --output "$payload/etc/sing-box/config.json" \
    --test-direct-outbound
else
  "$SCRIPT_DIR/render-minimal-config.sh" \
    "$@" \
    --node-name "$node_name" \
    --listen "$listen" \
    --port "$port" \
    --cache-file "$cache_file" \
    --output "$payload/etc/sing-box/config.json"
fi

cp "$ROOT_DIR/templates/sing-box/init.d-sing-box-tproxy" "$payload/etc/init.d/sing-box-tproxy"
sed "s#__PORT__#$port#g" "$ROOT_DIR/templates/watchdogs/vpn-nodes-watchdog.sh.tmpl" > "$payload/usr/bin/vpn-nodes-watchdog.sh"
cp "$ROOT_DIR/templates/watchdogs/dns-watchdog.sh.tmpl" "$payload/usr/bin/dns-watchdog.sh"
sed "s#__PORT__#$port#g" "$ROOT_DIR/templates/firewall/lan-proxy.uci.tmpl" > "$payload/etc/vpn-kit/firewall/lan-proxy-${port}.uci"
cp "$ROOT_DIR/templates/dns-chain/dnsmasq-additions.conf" "$payload/etc/vpn-kit/dnsmasq-additions.conf"
cat > "$payload/etc/vpn-kit/cron/minimal.crontab" <<EOF
* * * * * /usr/bin/dns-watchdog.sh
* * * * * sleep 30; /usr/bin/vpn-nodes-watchdog.sh
EOF

chmod 0600 "$payload/etc/sing-box/config.json"
chmod 0755 "$payload/etc/init.d/sing-box-tproxy" "$payload/usr/bin/dns-watchdog.sh" "$payload/usr/bin/vpn-nodes-watchdog.sh"
chmod 0644 "$payload/etc/vpn-kit/firewall/lan-proxy-${port}.uci" "$payload/etc/vpn-kit/dnsmasq-additions.conf" "$payload/etc/vpn-kit/cron/minimal.crontab"

sha_file() { vpn_kit_sha256 < "$1"; }
config_sha="$(sha_file "$payload/etc/sing-box/config.json")"
init_sha="$(sha_file "$payload/etc/init.d/sing-box-tproxy")"
dns_watchdog_sha="$(sha_file "$payload/usr/bin/dns-watchdog.sh")"
vpn_watchdog_sha="$(sha_file "$payload/usr/bin/vpn-nodes-watchdog.sh")"
firewall_sha="$(sha_file "$payload/etc/vpn-kit/firewall/lan-proxy-${port}.uci")"
dnsmasq_sha="$(sha_file "$payload/etc/vpn-kit/dnsmasq-additions.conf")"
cron_sha="$(sha_file "$payload/etc/vpn-kit/cron/minimal.crontab")"

copy_payload() {
  mkdir -p "$sing_box_dir" "$(dirname "$sing_box_init")" "$(dirname "$dns_watchdog")" \
    "$(dirname "$firewall_rule")" "$(dirname "$dnsmasq_additions")" "$(dirname "$cron_file")"
  cp "$payload/etc/sing-box/config.json" "$sing_box_config"
  cp "$payload/etc/init.d/sing-box-tproxy" "$sing_box_init"
  cp "$payload/usr/bin/dns-watchdog.sh" "$dns_watchdog"
  cp "$payload/usr/bin/vpn-nodes-watchdog.sh" "$vpn_watchdog"
  cp "$payload/etc/vpn-kit/firewall/lan-proxy-${port}.uci" "$firewall_rule"
  cp "$payload/etc/vpn-kit/dnsmasq-additions.conf" "$dnsmasq_additions"
  cp "$payload/etc/vpn-kit/cron/minimal.crontab" "$cron_file"
  chmod 0600 "$sing_box_config"
  chmod 0755 "$sing_box_init" "$dns_watchdog" "$vpn_watchdog"
  chmod 0644 "$firewall_rule" "$dnsmasq_additions" "$cron_file"
}

activation_commands_file() {
  out="$1"
  cat > "$out" <<EOF
sing-box check -c "$sing_box_config"
uci -q delete firewall.vpn_kit_lan_proxy_${port} || true
uci set firewall.vpn_kit_lan_proxy_${port}=rule
uci set firewall.vpn_kit_lan_proxy_${port}.name='vpn-kit LAN proxy ${port}'
uci set firewall.vpn_kit_lan_proxy_${port}.src='lan'
uci set firewall.vpn_kit_lan_proxy_${port}.proto='tcp'
uci set firewall.vpn_kit_lan_proxy_${port}.dest_port='${port}'
uci set firewall.vpn_kit_lan_proxy_${port}.target='ACCEPT'
uci commit firewall
/etc/init.d/firewall reload
mkdir -p /etc/crontabs
touch /etc/crontabs/root
grep -F '/usr/bin/dns-watchdog.sh' /etc/crontabs/root >/dev/null || echo '* * * * * /usr/bin/dns-watchdog.sh' >> /etc/crontabs/root
grep -F '/usr/bin/vpn-nodes-watchdog.sh' /etc/crontabs/root >/dev/null || echo '* * * * * sleep 30; /usr/bin/vpn-nodes-watchdog.sh' >> /etc/crontabs/root
/etc/init.d/cron enable
/etc/init.d/cron restart
/etc/init.d/sing-box-tproxy enable
/etc/init.d/sing-box-tproxy restart
EOF
}

write_activation_state() {
  input_state="$1"
  output_state="$2"
  mode="$3"
  activated_at="$(vpn_kit_now_iso8601)"
  jq \
    --arg now "$activated_at" \
    --arg mode "$mode" \
    --argjson port "$port" \
    --arg packages "$packages" \
    '
      .last_modified_at = $now
      | .components["sing-box"].activated = true
      | .components["sing-box"].service = "sing-box-tproxy"
      | .components["sing-box"].activation_mode = $mode
      | .activation = {
          profile:"minimal",
          activated_at:$now,
          mode:$mode,
          packages:($packages | split(" ")),
          services:["sing-box-tproxy","cron"],
          firewall_rules:[{name:"vpn-kit LAN proxy", port:$port, src:"lan", proto:"tcp"}],
          checks:["sing-box check", "service enabled/start"]
        }
      | .committed_steps = (.committed_steps // [])
    ' "$input_state" > "$output_state"
}

simulate_activation() {
  mkdir -p "$(dirname "$activation_log")"
  commands="$tmpdir/activation.commands"
  activation_commands_file "$commands"
  {
    printf '# openwrt-vpn-kit minimal activation command plan\n'
    if [ "$skip_packages" = "0" ]; then
      printf 'apk update\n'
      printf 'apk add %s\n' "$packages"
    fi
    cat "$commands"
  } > "$activation_log"
}

install_packages_live() {
  [ "$skip_packages" = "0" ] || return 0
  vpn_kit_require_cmd apk
  apk update
  # shellcheck disable=SC2086
  apk add $packages
}

activate_live() {
  activation_script="$tmpdir/activate-minimal.sh"
  activation_commands_file "$activation_script.body"
  {
    printf '#!/bin/sh\nset -eu\n'
    cat "$activation_script.body"
  } > "$activation_script"
  chmod +x "$activation_script"

  if [ -n "${VPN_KIT_ACTIVATE_DRY_RUN_LOG:-}" ]; then
    mkdir -p "$(dirname "$VPN_KIT_ACTIVATE_DRY_RUN_LOG")"
    {
      printf '# openwrt-vpn-kit minimal activation dry-run\n'
      if [ "$skip_packages" = "0" ]; then
        printf 'apk update\n'
        printf 'apk add %s\n' "$packages"
      fi
      cat "$activation_script.body"
    } > "$VPN_KIT_ACTIVATE_DRY_RUN_LOG"
    write_activation_state "$state_file" "$tmpdir/activation-state.json" "dry-run"
    dry_rev="$(env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/state-read.sh" --revision)"
    printf '%s\n' "$(cat "$tmpdir/activation-state.json")" | env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/state-write.sh" \
      --expected-revision "$dry_rev" \
      --writer "$writer" >/dev/null
    env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/state-read.sh" --revision
    return 0
  fi

  install_packages_live

  activation_state="$tmpdir/activation-state.json"
  write_activation_state "$state_file" "$activation_state" "live"
  activation_rev="$(env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/state-read.sh" --revision)"
  activation_out="$tmpdir/activation.out"
  if env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/staged-apply.sh" \
      --step-id activate-minimal \
      --expected-revision "$activation_rev" \
      --writer "$writer" \
      --new-state "$activation_state" \
      --snapshot-path /etc/config/firewall \
      --snapshot-path /etc/crontabs/root \
      --apply "$activation_script" \
      --verify "sing-box check -c '$sing_box_config' && /etc/init.d/sing-box-tproxy enabled && /etc/init.d/sing-box-tproxy status >/dev/null" \
      --rollback-command "/etc/init.d/firewall reload >/dev/null 2>&1 || true; /etc/init.d/cron restart >/dev/null 2>&1 || true; /etc/init.d/sing-box-tproxy stop >/dev/null 2>&1 || true" \
      --timeout-seconds 30 > "$activation_out"; then
    awk '/^[0-9]+$/ {rev=$0} END {if (rev != "") print rev; else exit 1}' "$activation_out" || {
      cat "$activation_out" >&2 || true
      return "$VPN_KIT_EXIT_VALIDATION"
    }
  else
    rc=$?
    cat "$activation_out" >&2 || true
    return "$rc"
  fi
}

current_rev="$(env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/state-read.sh" --revision)"
now="$(vpn_kit_now_iso8601)"

new_state="$tmpdir/new-state.json"
jq \
  --arg now "$now" \
  --arg node_name "$node_name" \
  --arg config "$sing_box_config" \
  --arg init "$sing_box_init" \
  --arg dns_watchdog "$dns_watchdog" \
  --arg vpn_watchdog "$vpn_watchdog" \
  --arg firewall_rule "$firewall_rule" \
  --arg dnsmasq "$dnsmasq_additions" \
  --arg cron "$cron_file" \
  --arg config_sha "$config_sha" \
  --arg init_sha "$init_sha" \
  --arg dns_watchdog_sha "$dns_watchdog_sha" \
  --arg vpn_watchdog_sha "$vpn_watchdog_sha" \
  --arg firewall_sha "$firewall_sha" \
  --arg dnsmasq_sha "$dnsmasq_sha" \
  --arg cron_sha "$cron_sha" \
  --argjson port "$port" \
  '
    .profile = "minimal"
    | .last_modified_at = $now
    | .components["sing-box"] = {
        version:"unknown",
        init:$init,
        binary:"/usr/bin/sing-box",
        config_sha256:$config_sha
      }
    | .components.watchdogs = {version:"0.1.0", instances:2}
    | .files_owned_by_skill = ((.files_owned_by_skill // []) + [$config, $init, $dns_watchdog, $vpn_watchdog, $firewall_rule, $dnsmasq, $cron] | unique)
    | .owned_file_checksums = ((.owned_file_checksums // {}) + {
        ($config):$config_sha,
        ($init):$init_sha,
        ($dns_watchdog):$dns_watchdog_sha,
        ($vpn_watchdog):$vpn_watchdog_sha,
        ($firewall_rule):$firewall_sha,
        ($dnsmasq):$dnsmasq_sha,
        ($cron):$cron_sha
      })
    | .proxy_ports = ((.proxy_ports // []) + [{port:$port, listen:"0.0.0.0", outbound:$node_name, type:"mixed"}] | unique_by(.port, .listen, .type))
    | .firewall_rules_added = ((.firewall_rules_added // []) + [{name:("vpn-kit LAN proxy " + ($port|tostring)), src_zone:"lan", dest_port:$port, enabled:true}] | unique_by(.name))
    | .cron_entries = ((.cron_entries // []) + [
        {schedule:"* * * * *", cmd:"/usr/bin/dns-watchdog.sh"},
        {schedule:"* * * * *", cmd:"sleep 30; /usr/bin/vpn-nodes-watchdog.sh"}
      ] | unique_by(.cmd))
  ' "$state_file" > "$new_state"

if [ -n "$target_root" ]; then
  copy_payload
  printf '%s\n' "$(cat "$new_state")" | env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/state-write.sh" \
    --expected-revision "$current_rev" \
    --writer "$writer" >/dev/null
  committed_rev="$(env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/state-read.sh" --revision)"
  if [ "$activate" = "1" ]; then
    simulate_activation
    activation_state="$tmpdir/activation-state.json"
    write_activation_state "$state_file" "$activation_state" "rootfs-simulated"
    printf '%s\n' "$(cat "$activation_state")" | env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/state-write.sh" \
      --expected-revision "$committed_rev" \
      --writer "$writer" >/dev/null
    committed_rev="$(env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/state-read.sh" --revision)"
  fi
else
  apply_script="$tmpdir/apply-minimal.sh"
  cat > "$apply_script" <<EOF
#!/bin/sh
set -eu
mkdir -p "$sing_box_dir" "$(dirname "$sing_box_init")" "$(dirname "$dns_watchdog")" "$(dirname "$firewall_rule")" "$(dirname "$dnsmasq_additions")" "$(dirname "$cron_file")"
cp "$payload/etc/sing-box/config.json" "$sing_box_config"
cp "$payload/etc/init.d/sing-box-tproxy" "$sing_box_init"
cp "$payload/usr/bin/dns-watchdog.sh" "$dns_watchdog"
cp "$payload/usr/bin/vpn-nodes-watchdog.sh" "$vpn_watchdog"
cp "$payload/etc/vpn-kit/firewall/lan-proxy-${port}.uci" "$firewall_rule"
cp "$payload/etc/vpn-kit/dnsmasq-additions.conf" "$dnsmasq_additions"
cp "$payload/etc/vpn-kit/cron/minimal.crontab" "$cron_file"
chmod 0600 "$sing_box_config"
chmod 0755 "$sing_box_init" "$dns_watchdog" "$vpn_watchdog"
chmod 0644 "$firewall_rule" "$dnsmasq_additions" "$cron_file"
EOF
  chmod +x "$apply_script"
  committed_rev="$(env VPN_KIT_STATE_FILE="$state_file" "$LIB_DIR/staged-apply.sh" \
    --step-id install-minimal-files \
    --expected-revision "$current_rev" \
    --writer "$writer" \
    --new-state "$new_state" \
    --snapshot-path "$sing_box_config" \
    --snapshot-path "$sing_box_init" \
    --snapshot-path "$dns_watchdog" \
    --snapshot-path "$vpn_watchdog" \
    --snapshot-path "$firewall_rule" \
    --snapshot-path "$dnsmasq_additions" \
    --snapshot-path "$cron_file" \
    --apply "$apply_script" \
    --verify "test -s '$sing_box_config' && test -x '$sing_box_init' && test -x '$dns_watchdog' && test -x '$vpn_watchdog'" \
    --rollback-command "true" \
    --timeout-seconds 15)"
  if [ "$activate" = "1" ]; then
    committed_rev="$(activate_live)"
  fi
fi

raw_committed_rev="$committed_rev"
committed_rev="$(printf '%s\n' "$raw_committed_rev" | awk '/^[0-9]+$/ {rev=$0} END {if (rev != "") print rev; else exit 1}')" || {
  echo "install-minimal: could not parse committed revision from: $raw_committed_rev" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
}

env VPN_KIT_JOURNAL_FILE="$(vpn_kit_target_path /etc/vpn-kit/journal/events.jsonl)" \
  "$LIB_DIR/journal-append.sh" setup_completed profile=minimal step_id=install-minimal-files state_revision="$committed_rev" >/dev/null 2>&1 || true

jq -n \
  --arg status ok \
  --arg profile minimal \
  --argjson revision "$committed_rev" \
  --arg config "$sing_box_config" \
  --arg init "$sing_box_init" \
  --argjson activated "$activate" \
  --argjson port "$port" \
  '{status:$status, profile:$profile, revision:$revision, activated:$activated, files:{sing_box_config:$config, sing_box_init:$init}, proxy_port:$port}'
