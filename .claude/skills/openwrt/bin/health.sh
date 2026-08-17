#!/usr/bin/env bash
# bin/health.sh — runtime health probe of an installed router.
#
# Where doctor.sh checks CONFIG state (files, packages, validity), health.sh
# checks RUNTIME state (process up, nft rules loaded, DNS returns FakeIP,
# SOCKS exit IP responds).
#
# Usage:
#   bin/health.sh --router <alias> [--json] [--ip-exit-only]
#
# Exit codes:
#   0   все критические probes прошли
#   1   как минимум один критический probe зафейлился
#   2   router not found / SSH unreachable
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

# Per-line secret regex (single-line patterns). Multi-line PEM blocks are
# handled by the awk filter inside sanitize() below — `sed` is per-line and
# cannot match across newlines, so a PEM private key would slip through.
_HEALTH_SECRET_RE='(vless://[^[:space:]]+|vless%3A%2F%2F[^[:space:]]+|bot[0-9]+:[A-Za-z0-9_-]{20,}|"bot_token":[[:space:]]*"[^"]*"|BOT_TOKEN=[^[:space:]]+|TG_TOKEN=[^[:space:]]+)'

usage() {
  cat >&2 <<'EOF'
Usage: bin/health.sh --router <alias> [--json] [--ip-exit-only]

Проверяет runtime-состояние роутера: sing-box процесс, nft таблица, DNS FakeIP,
SOCKS5 exit IP (если есть mixed-inbound на 4000).

Options:
  --router <alias>      alias из memory/routers.yaml (обяз.)
  --json                JSON вместо markdown-таблицы
  --ip-exit-only        напечатать ТОЛЬКО external IP через SOCKS5 (одна строка)
EOF
  exit 64
}

router=""
emit_json=0
ip_exit_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --json) emit_json=1; shift ;;
    --ip-exit-only) ip_exit_only=1; shift ;;
    -h|--help) usage ;;
    *) echo "health: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "health: --router обязателен" >&2; usage; }

resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
health: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
EOF
  exit 2
fi

# --- Remote probe script -------------------------------------------------------
# Emits k=v lines. Multi-line values use base64 to avoid newline parsing.
read -r -d '' REMOTE_PROBE <<'REMOTE_SH' || true
set +e

# --- sing-box process ---
SB_PID="$(pgrep -f 'sing-box' 2>/dev/null | head -1)"
SB_RUNNING=0
[ -n "$SB_PID" ] && SB_RUNNING=1
echo "sb_running=$SB_RUNNING"
echo "sb_pid=${SB_PID:-}"

# pgrep -fa equivalent: full cmdline
SB_CMDLINE=""
if [ -n "$SB_PID" ] && [ -r "/proc/$SB_PID/cmdline" ]; then
  SB_CMDLINE="$(tr '\0' ' ' < "/proc/$SB_PID/cmdline")"
fi
echo "sb_cmdline_b64=$(printf '%s' "$SB_CMDLINE" | base64 2>/dev/null | tr -d '\n')"

# --- nft table inet sing_box_tproxy ---
NFT_OUT="$(nft list table inet sing_box_tproxy 2>&1 | head -40)"
NFT_OK=0
if printf '%s' "$NFT_OUT" | grep -q 'table inet sing_box_tproxy'; then
  NFT_OK=1
fi
echo "nft_ok=$NFT_OK"
echo "nft_out_b64=$(printf '%s' "$NFT_OUT" | base64 2>/dev/null | tr -d '\n')"

# Rule count in mangle_prerouting (rough sanity).
NFT_RULES_COUNT="$(nft list chain inet sing_box_tproxy mangle_prerouting 2>/dev/null | grep -cE '^[[:space:]]+(ip|meta|tcp|udp|@)' )"
echo "nft_rules_count=$NFT_RULES_COUNT"

# proxy_subnets set head
PSUB_HEAD="$(nft list set inet sing_box_tproxy proxy_subnets 2>/dev/null | head -10)"
echo "proxy_subnets_b64=$(printf '%s' "$PSUB_HEAD" | base64 2>/dev/null | tr -d '\n')"

# --- DNS: nslookup of a "well-known proxied domain" against 127.0.0.42 ---
# We try youtube.com which is conventionally on the VPN list.
DNS_OUT="$(nslookup youtube.com 127.0.0.42 2>&1 | tail -5)"
DNS_FAKEIP_OK=0
# FakeIP convention in sing-box: 198.18.0.0/15.
if printf '%s' "$DNS_OUT" | grep -qE 'Address[[:space:]]*:?[[:space:]]+198\.(18|19)\.'; then
  DNS_FAKEIP_OK=1
fi
echo "dns_fakeip_ok=$DNS_FAKEIP_OK"
echo "dns_out_b64=$(printf '%s' "$DNS_OUT" | base64 2>/dev/null | tr -d '\n')"

# --- Mixed inbound :4000 — does it exist? Then try curl through it. ---
MIXED_4000_PRESENT=0
if [ -f /etc/sing-box/config.json ]; then
  if grep -qE '"listen_port":[[:space:]]*4000' /etc/sing-box/config.json 2>/dev/null; then
    MIXED_4000_PRESENT=1
  fi
fi
echo "mixed_4000_present=$MIXED_4000_PRESENT"

SOCKS_EXIT_IP=""
SOCKS_EXIT_ERR=""
if [ "$MIXED_4000_PRESENT" = "1" ] && command -v curl >/dev/null 2>&1; then
  # socks5h: hostname resolution via proxy.
  SOCKS_EXIT_IP="$(curl --max-time 10 -sS --proxy socks5h://192.168.99.1:4000 https://api.ipify.org 2>/tmp/.health_curl_err || true)"
  SOCKS_EXIT_ERR="$(cat /tmp/.health_curl_err 2>/dev/null | head -3)"
  rm -f /tmp/.health_curl_err 2>/dev/null
fi
echo "socks_exit_ip=$SOCKS_EXIT_IP"
echo "socks_exit_err_b64=$(printf '%s' "$SOCKS_EXIT_ERR" | base64 2>/dev/null | tr -d '\n')"

# --- Recent log lines ---
LOG_OUT="$(logread -e 'sing-box' 2>/dev/null | tail -20)"
echo "log_out_b64=$(printf '%s' "$LOG_OUT" | base64 2>/dev/null | tr -d '\n')"

# --- service status (init.d) ---
SVC_STATUS="unknown"
if [ -x /etc/init.d/sing-box-tproxy ]; then
  if /etc/init.d/sing-box-tproxy status >/dev/null 2>&1; then
    SVC_STATUS="running"
  else
    SVC_STATUS="stopped"
  fi
fi
echo "svc_status=$SVC_STATUS"

exit 0
REMOTE_SH

# Run the probe.
probe_out=""
if ! probe_out="$(printf '%s' "$REMOTE_PROBE" | ssh_run_remote 2>/dev/null)"; then
  echo "health: удалённый probe не отработал" >&2
  exit 2
fi

# Parse k=v lines.
get_kv() {
  printf '%s\n' "$probe_out" | awk -F= -v k="$1" '$1==k {sub(/^[^=]+=/, ""); print; exit}'
}
get_b64() {
  local b64; b64="$(get_kv "$1")"
  [ -z "$b64" ] && return 0
  printf '%s' "$b64" | base64 -d 2>/dev/null || true
}

sb_running="$(get_kv sb_running)"
sb_pid="$(get_kv sb_pid)"
sb_cmdline="$(get_b64 sb_cmdline_b64)"
nft_ok="$(get_kv nft_ok)"
nft_rules_count="$(get_kv nft_rules_count)"
nft_out="$(get_b64 nft_out_b64)"
proxy_subnets_head="$(get_b64 proxy_subnets_b64)"
dns_fakeip_ok="$(get_kv dns_fakeip_ok)"
dns_out="$(get_b64 dns_out_b64)"
mixed_4000_present="$(get_kv mixed_4000_present)"
socks_exit_ip="$(get_kv socks_exit_ip)"
socks_exit_err="$(get_b64 socks_exit_err_b64)"
log_out="$(get_b64 log_out_b64)"
svc_status="$(get_kv svc_status)"

# Sanitize: strip any secret-looking patterns. Two-pass:
#   (1) awk filter that tracks PEM-block state across lines — replaces the
#       whole block with a single "[REDACTED PEM BLOCK]" line. `sed` cannot
#       do this because it processes line-by-line.
#   (2) sed pass for single-line patterns (vless://, bot<n>:, TG_TOKEN=, etc.)
# Use '#' as the s-delimiter because the regex contains '|' for alternation;
# BSD/macOS sed otherwise mis-parses it.
sanitize() {
  printf '%s' "$1" | awk '
    BEGIN { in_pem = 0 }
    /-----BEGIN [A-Z]+ PRIVATE KEY-----/ { in_pem = 1; print "[REDACTED PEM BLOCK]"; next }
    /-----END [A-Z]+ PRIVATE KEY-----/   { in_pem = 0; next }
    in_pem { next }
    { print }
  ' | sed -E "s#$_HEALTH_SECRET_RE#[REDACTED]#g"
}

# Sanitize EVERY value that flows to stdout/JSON. The previous version only
# scrubbed log_out and nft_out, leaving sb_cmdline and dns_out unsanitized —
# both can plausibly carry secrets (cmdline → config flags w/ tokens, dns_out
# → CNAME chains revealing infra).
sb_cmdline="$(sanitize "$sb_cmdline")"
dns_out="$(sanitize "$dns_out")"
proxy_subnets_head="$(sanitize "$proxy_subnets_head")"
socks_exit_err="$(sanitize "$socks_exit_err")"
log_out_safe="$(sanitize "$log_out")"
nft_out_safe="$(sanitize "$nft_out")"

# --- --ip-exit-only shortcut ---------------------------------------------------
if [ "$ip_exit_only" = "1" ]; then
  if [ -n "$socks_exit_ip" ]; then
    printf '%s\n' "$socks_exit_ip"
    exit 0
  fi
  echo "health: SOCKS exit IP недоступен (mixed:4000 present=$mixed_4000_present, err=$socks_exit_err)" >&2
  exit 1
fi

# Compute pass/fail of critical checks.
crit_pass=1
[ "$sb_running" = "1" ] || crit_pass=0
[ "$nft_ok" = "1" ] || crit_pass=0
[ "$dns_fakeip_ok" = "1" ] || crit_pass=0

# --- JSON output ---------------------------------------------------------------
if [ "$emit_json" = "1" ]; then
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg router "$ROUTER_ALIAS" \
      --arg host "$ROUTER_HOST" \
      --argjson sb_running "${sb_running:-0}" \
      --arg sb_pid "${sb_pid:-}" \
      --arg sb_cmdline "$sb_cmdline" \
      --argjson nft_ok "${nft_ok:-0}" \
      --argjson nft_rules_count "${nft_rules_count:-0}" \
      --argjson dns_fakeip_ok "${dns_fakeip_ok:-0}" \
      --arg dns_out "$dns_out" \
      --argjson mixed_4000_present "${mixed_4000_present:-0}" \
      --arg socks_exit_ip "${socks_exit_ip:-}" \
      --arg socks_exit_err "${socks_exit_err:-}" \
      --arg svc_status "${svc_status:-unknown}" \
      --arg log_tail "$log_out_safe" \
      --argjson critical_pass "$crit_pass" \
      '{
        router: $router, host: $host,
        sing_box: {
          running: ($sb_running == 1), pid: $sb_pid, cmdline: $sb_cmdline,
          init_d_status: $svc_status
        },
        nft: { ok: ($nft_ok == 1), rules_count: $nft_rules_count },
        dns: { fakeip_ok: ($dns_fakeip_ok == 1), raw: $dns_out },
        socks_exit: {
          mixed_4000_present: ($mixed_4000_present == 1),
          ip: $socks_exit_ip, err: $socks_exit_err
        },
        log_tail_redacted: $log_tail,
        critical_pass: ($critical_pass == 1)
      }'
  else
    # Fallback minimal JSON (jq not local).
    printf '{"router":"%s","critical_pass":%s,"sb_running":%s,"nft_ok":%s,"dns_fakeip_ok":%s,"socks_exit_ip":"%s"}\n' \
      "$ROUTER_ALIAS" "$( [ "$crit_pass" = "1" ] && echo true || echo false )" \
      "$( [ "$sb_running" = "1" ] && echo true || echo false )" \
      "$( [ "$nft_ok" = "1" ] && echo true || echo false )" \
      "$( [ "$dns_fakeip_ok" = "1" ] && echo true || echo false )" \
      "${socks_exit_ip:-}"
  fi
  [ "$crit_pass" = "1" ] || exit 1
  exit 0
fi

# --- Markdown output -----------------------------------------------------------
icon() { [ "$1" = "1" ] && echo "✓" || echo "✗"; }

cat <<EOF
## Health: $ROUTER_ALIAS ($ROUTER_HOST)

| Probe | Status | Detail |
|-------|:------:|--------|
| sing-box process | $(icon "$sb_running") | $( [ "$sb_running" = "1" ] && echo "PID $sb_pid" || echo "не запущен" ) |
| init.d status | $( [ "$svc_status" = "running" ] && echo "✓" || echo "✗" ) | $svc_status |
| nft table sing_box_tproxy | $(icon "$nft_ok") | rules in mangle_prerouting: $nft_rules_count |
| DNS → FakeIP (198.18.x) | $(icon "$dns_fakeip_ok") | $(printf '%s' "$dns_out" | tr '\n' ' ' | cut -c1-80) |
| mixed inbound :4000 | $(icon "$mixed_4000_present") | $( [ "$mixed_4000_present" = "1" ] && echo "есть" || echo "нет (skip SOCKS test)" ) |
| SOCKS5 exit IP | $( [ -n "$socks_exit_ip" ] && echo "✓" || echo "—" ) | $( [ -n "$socks_exit_ip" ] && echo "$socks_exit_ip" || echo "${socks_exit_err:-(skipped)}" ) |

EOF

if [ -n "$proxy_subnets_head" ]; then
  cat <<EOF
### proxy_subnets (head)

\`\`\`
$proxy_subnets_head
\`\`\`

EOF
fi

if [ -n "$log_out_safe" ]; then
  cat <<EOF
### Recent sing-box log (sanitized, tail -20)

\`\`\`
$log_out_safe
\`\`\`

EOF
fi

echo "## Summary"
if [ "$crit_pass" = "1" ]; then
  echo "**OK** — все критические probes прошли (process + nft + DNS FakeIP)."
else
  echo "**FAIL** — критические probes не прошли:"
  [ "$sb_running" = "1" ] || echo "  - sing-box не запущен"
  [ "$nft_ok" = "1" ] || echo "  - nft table inet sing_box_tproxy отсутствует"
  [ "$dns_fakeip_ok" = "1" ] || echo "  - DNS не возвращает FakeIP (198.18.x) для youtube.com"
fi

[ "$crit_pass" = "1" ] || exit 1
exit 0
