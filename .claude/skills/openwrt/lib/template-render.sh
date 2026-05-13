#!/usr/bin/env bash
# lib/template-render.sh — simple {{KEY}} template substitution.
# Source this from bin/*.sh scripts.

# render_template <template-path> <output-path> KEY=VALUE [KEY=VALUE ...]
# Substitutes every {{KEY}} in template with VALUE. Multi-line values supported.
# Unsubstituted {{KEY}} placeholders are left as-is (caller can detect via grep).
render_template() {
  local tpl="$1" out="$2"; shift 2

  if [ ! -f "$tpl" ]; then
    echo "render_template: template not found: $tpl" >&2
    return 1
  fi

  # Build a temp file with substitutions applied sequentially.
  # Use awk for safe multi-line substitution (sed struggles with \n in repl).
  local tmp; tmp="$(mktemp -t openwrt-skill-render.XXXXXX)"
  cp "$tpl" "$tmp"

  for kv in "$@"; do
    local key="${kv%%=*}"
    local val="${kv#*=}"
    local marker="{{${key}}}"

    # Use awk: read file, replace marker with val (handles newlines in val).
    local tmp2; tmp2="$(mktemp -t openwrt-skill-render.XXXXXX)"
    KEY="$marker" VAL="$val" awk '
      BEGIN { key = ENVIRON["KEY"]; val = ENVIRON["VAL"]; klen = length(key) }
      {
        line = $0
        out = ""
        while ((idx = index(line, key)) > 0) {
          out = out substr(line, 1, idx-1) val
          line = substr(line, idx + klen)
        }
        print out line
      }
    ' "$tmp" > "$tmp2"
    mv "$tmp2" "$tmp"
  done

  mkdir -p "$(dirname "$out")"
  mv "$tmp" "$out"
}

# render_first_time_memory <router-alias> <router-host>
# Initialise memory/<alias>/{domains,vpns,proxies,quirks,journal}.md from templates
# if they don't exist yet.
render_first_time_memory() {
  local alias="$1" host="$2"
  : "${OPENWRT_SKILL_MEMORY:?}"

  local tpl_dir="$OPENWRT_SKILL_MEMORY/_templates"
  local out_dir="$OPENWRT_SKILL_MEMORY/$alias"
  local iso; iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$out_dir"

  for name in domains.md vpns.md proxies.md subnets.md pins.md quirks.md journal.md; do
    [ -f "$out_dir/$name" ] && continue
    [ -f "$tpl_dir/$name" ] || continue

    render_template "$tpl_dir/$name" "$out_dir/$name" \
      "ROUTER_ALIAS=$alias" \
      "ROUTER_HOST=$host" \
      "LAST_UPDATED_ISO=$iso" \
      "LAST_EVENT_ISO=$iso" \
      "DOMAIN_TABLE_ROWS=_(пока пусто — добавь через bin/add-domain.sh)_" \
      "VPN_TABLE_ROWS=_(пока пусто — добавь через bin/add-vpn.sh)_" \
      "PROXY_TABLE_ROWS=_(пока пусто — добавь через bin/add-proxy.sh)_" \
      "SUBNET_TABLE_ROWS=_(пока пусто — добавь через bin/add-ip.sh)_" \
      "PIN_TABLE_ROWS=_(пока пусто — добавь через bin/pin-device.sh)_" \
      "QUIRK_ENTRIES=_(никаких особенностей не записано)_" \
      "JOURNAL_ENTRIES=_(пусто)_" \
      "NOTES=" \
      "FAILOVER_TAGS=_(none)_" \
      "FAILOVER_INTERVAL=_?_" \
      "FAILOVER_URL=_?_" \
      "FAILOVER_TOLERANCE=_?_" \
      "ISP_PROVIDER=?" "REGION=?" "DPI_TYPE=?" "ZAPRET_STRATEGY=?" \
      "HW_MODEL=?" "HW_CPU=?" "HW_RAM=?" "HW_FLASH=?" "HW_WIFI=?"
  done
}
