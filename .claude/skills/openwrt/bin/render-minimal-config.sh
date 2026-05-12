#!/bin/sh
# render-minimal-config.sh — render minimal sing-box config from a VLESS Reality URL.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"
# shellcheck source=../lib/vpn-kit-common.sh
. "$LIB_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

vless_url=""
vless_url_file=""
node_name="vpn-node-1"
listen="0.0.0.0"
port="4000"
cache_file="/usr/share/sing-box/cache.db"
output=""
test_direct_outbound=0

while [ $# -gt 0 ]; do
  case "$1" in
    --vless-url) vless_url="${2:-}"; shift 2 ;;
    --vless-url-file) vless_url_file="${2:-}"; shift 2 ;;
    --node-name) node_name="${2:-}"; shift 2 ;;
    --listen) listen="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --cache-file) cache_file="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --test-direct-outbound) test_direct_outbound=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "render-minimal-config: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

# Если URL передан через файл — читаем оттуда. Это держит секрет из argv (ps,
# audit). Файл должен быть chmod 600 на ответственности caller'а.
if [ -n "$vless_url_file" ]; then
  if [ -n "$vless_url" ]; then
    echo "render-minimal-config: --vless-url и --vless-url-file одновременно — выбери один" >&2
    exit "$VPN_KIT_EXIT_VALIDATION"
  fi
  if [ ! -r "$vless_url_file" ]; then
    echo "render-minimal-config: --vless-url-file '$vless_url_file' не читается" >&2
    exit "$VPN_KIT_EXIT_VALIDATION"
  fi
  # Читаем первую непустую строку, обрезаем пробелы/CR.
  vless_url="$(head -1 "$vless_url_file" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
fi

case "$vless_url" in
  vless://*) ;;
  *) echo "render-minimal-config: VLESS URL must start with vless:// (use --vless-url or --vless-url-file)" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac
case "$port" in ''|*[!0-9]*) echo "render-minimal-config: --port must be integer" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;; esac

without_scheme="${vless_url#vless://}"
before_fragment="${without_scheme%%#*}"
main_part="${before_fragment%%\?*}"
query=""
case "$before_fragment" in
  *\?*) query="${before_fragment#*\?}" ;;
esac

uuid="${main_part%@*}"
host_port="${main_part#*@}"
server="${host_port%:*}"
server_port="${host_port##*:}"

query_value() {
  key="$1"
  printf '%s' "$query" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -1
}

flow="$(query_value flow)"
sni="$(query_value sni)"
fingerprint="$(query_value fp)"
public_key="$(query_value pbk)"
short_id="$(query_value sid)"

[ -n "$flow" ] || flow="xtls-rprx-vision"
[ -n "$sni" ] || sni="$server"
[ -n "$fingerprint" ] || fingerprint="chrome"

if [ -z "$uuid" ] || [ -z "$server" ] || [ -z "$server_port" ] || [ -z "$public_key" ]; then
  echo "render-minimal-config: VLESS URL must include uuid, server, port and pbk" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

template="$ROOT_DIR/templates/sing-box/config-minimal.json.tmpl"
rendered="$(sed \
  -e "s#__NODE_NAME__#$(printf '%s' "$node_name" | sed 's/[&/\]/\\&/g')#g" \
  -e "s#__LISTEN__#$(printf '%s' "$listen" | sed 's/[&/\]/\\&/g')#g" \
  -e "s#__PORT__#$port#g" \
  -e "s#__SERVER__#$(printf '%s' "$server" | sed 's/[&/\]/\\&/g')#g" \
  -e "s#__SERVER_PORT__#$server_port#g" \
  -e "s#__UUID__#$(printf '%s' "$uuid" | sed 's/[&/\]/\\&/g')#g" \
  -e "s#__FLOW__#$(printf '%s' "$flow" | sed 's/[&/\]/\\&/g')#g" \
  -e "s#__SNI__#$(printf '%s' "$sni" | sed 's/[&/\]/\\&/g')#g" \
  -e "s#__FINGERPRINT__#$(printf '%s' "$fingerprint" | sed 's/[&/\]/\\&/g')#g" \
  -e "s#__PUBLIC_KEY__#$(printf '%s' "$public_key" | sed 's/[&/\]/\\&/g')#g" \
  -e "s#__SHORT_ID__#$(printf '%s' "$short_id" | sed 's/[&/\]/\\&/g')#g" \
  -e "s#__CACHE_FILE__#$(printf '%s' "$cache_file" | sed 's/[&/\]/\\&/g')#g" \
  "$template")"

if ! printf '%s\n' "$rendered" | jq -e . >/dev/null; then
  echo "render-minimal-config: rendered config is invalid JSON" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
fi

if [ "$test_direct_outbound" = "1" ]; then
  rendered="$(printf '%s\n' "$rendered" | jq '.outbounds = [.outbounds[] | select(.tag == "direct")] | .route.final = "direct"')"
fi

if [ -n "$output" ]; then
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "$rendered" > "$output"
else
  printf '%s\n' "$rendered"
fi
