#!/usr/bin/env bash
# lib/country-resolve.sh — pure local resolver: country code/alias → pool tag.
#
# Usage (source this file, then call the function):
#   . "$SKILL_HOME/lib/country-resolve.sh"
#   pool_tag="$(resolve_country_to_pool "$ROUTER_ALIAS" "$user_input")"
#
# Behaviour:
#   - country key (usa, pl, sg)     → pool tag (usa-pool, pl-pool, sg-pool)
#   - alias (us, poland, polsha)    → pool tag via alias → country → pool
#   - already a pool tag (usa-pool) → input unchanged
#   - anything else (usa-4, direct) → input unchanged  (backward-compat, exit 0)
#   - always exits 0
#   - case-insensitive
#   - pure bash + POSIX awk: no SSH, no jq, no GNU awk required

resolve_country_to_pool() {
  local alias="$1"
  local input="$2"
  local memory_dir="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"
  local yaml="$memory_dir/$alias/countries.yaml"

  if [ -z "$input" ]; then
    return 0
  fi
  if [ ! -f "$yaml" ]; then
    printf '%s' "$input"
    return 0
  fi

  local lower_input
  lower_input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"

  # POSIX awk: parse simple YAML (2-space / 4-space indent, no anchors)
  # Returns the pool tag or empty string if not found.
  local result
  result="$(awk -v inp="$lower_input" '
    BEGIN { section=""; cur_country=""; alias_target="" }

    /^countries:/ { section="countries"; cur_country=""; next }
    /^aliases:/   { section="aliases";   cur_country=""; next }

    # Blank / comment lines
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }

    section == "countries" {
      # 2-space indent = country key
      if ($0 ~ /^  [^ ]/) {
        # extract key: trim leading spaces and trailing colon
        line = $0
        gsub(/^[[:space:]]+/, "", line)
        gsub(/:.*$/, "", line)
        cur_country = line
      }
      # 4-space indent = pool: value
      if ($0 ~ /^    pool:/ && cur_country == inp) {
        line = $0
        gsub(/^.*pool:[[:space:]]*/, "", line)
        gsub(/[[:space:]]*$/, "", line)
        print line
        exit
      }
    }

    section == "aliases" {
      if ($0 ~ /^  [^ ]/) {
        line = $0
        gsub(/^[[:space:]]+/, "", line)
        # format: "key: value"
        n = split(line, parts, /:[[:space:]]*/)
        if (n >= 2 && parts[1] == inp) {
          alias_target = parts[2]
          gsub(/[[:space:]]/, "", alias_target)
        }
      }
    }

    END {
      # If alias matched, print target country name with marker
      if (alias_target != "") print "ALIAS:" alias_target
    }
  ' "$yaml")"

  # If alias needs second-pass pool lookup
  if printf '%s' "$result" | grep -q '^ALIAS:'; then
    local target_country="${result#ALIAS:}"
    result="$(awk -v country="$target_country" '
      BEGIN { section=""; cur_country="" }
      /^countries:/ { section="countries"; next }
      /^aliases:/   { section=""; next }
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      section == "countries" {
        if ($0 ~ /^  [^ ]/) {
          line = $0; gsub(/^[[:space:]]+/, "", line); gsub(/:.*$/, "", line)
          cur_country = line
        }
        if ($0 ~ /^    pool:/ && cur_country == country) {
          line = $0; gsub(/^.*pool:[[:space:]]*/, "", line); gsub(/[[:space:]]*$/, "", line)
          print line; exit
        }
      }
    ' "$yaml")"
  fi

  if [ -n "$result" ]; then
    printf '%s' "$result"
  else
    printf '%s' "$input"
  fi
  return 0
}
