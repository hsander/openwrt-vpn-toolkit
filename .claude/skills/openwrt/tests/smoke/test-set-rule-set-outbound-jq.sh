#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required" >&2
  exit 0
fi

tmp_in="$(mktemp -t openwrt-skill-set-rule-in.XXXXXX)"
tmp_out="$(mktemp -t openwrt-skill-set-rule-out.XXXXXX)"
trap 'rm -f "$tmp_in" "$tmp_out"' EXIT

cat > "$tmp_in" <<'JSON'
{
  "outbounds": [
    { "tag": "direct-out" },
    { "tag": "usa-4-crip" },
    { "tag": "pl-pool" }
  ],
  "route": {
    "rules": [
      { "inbound": ["tproxy-in", "dns-in"], "outbound": "direct-out" },
      { "rule_set": ["telegram", "tg-pin"], "outbound": "usa-4-crip" },
      { "rule_set": ["polsha-only"], "outbound": "polsha" },
      { "inbound": ["proxy-usa-4-crip"], "outbound": "usa-4-crip" }
    ]
  }
}
JSON

jq --arg rs "telegram" --arg outbound "pl-pool" '
  def has_rs:
    (.rule_set? // null) as $v
    | if $v == null then false
      elif ($v | type) == "array" then any($v[]; . == $rs)
      elif ($v | type) == "string" then $v == $rs
      else false end;
  .route.rules |= map(if has_rs then .outbound = $outbound else . end)
' "$tmp_in" > "$tmp_out"

before_count="$(jq -r '.route.rules | length' "$tmp_in")"
after_count="$(jq -r '.route.rules | length' "$tmp_out")"
[ "$before_count" = "$after_count" ] || {
  echo "FAIL: route.rules count changed: $before_count -> $after_count" >&2
  exit 1
}

telegram_outbound="$(jq -r '.route.rules[] | select((.rule_set // []) | index("telegram")) | .outbound' "$tmp_out")"
[ "$telegram_outbound" = "pl-pool" ] || {
  echo "FAIL: telegram outbound is $telegram_outbound" >&2
  exit 1
}

inbound_rules="$(jq -r '[.route.rules[] | select(has("inbound"))] | length' "$tmp_out")"
[ "$inbound_rules" = "2" ] || {
  echo "FAIL: inbound rules were not preserved" >&2
  exit 1
}

echo "ok: set-rule-set-outbound jq preserves non-rule_set rules"
