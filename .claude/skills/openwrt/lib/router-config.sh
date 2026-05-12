#!/usr/bin/env bash
# lib/router-config.sh — resolve router connection settings from memory/routers.yaml.
# Source this file from bin/*.sh scripts; do not execute directly.

# Exports on success:
#   ROUTER_ALIAS, ROUTER_HOST, ROUTER_USER, ROUTER_SSH_KEY, ROUTER_SSH_ALIAS, ROUTER_NOTES
# Exit codes:
#   0   ok
#   2   registry missing or router not found
#   13  validation error (bad alias / host / user / ssh_alias / key_path shape)

# Requires: yq (Mike Farah's yq, v4+; install: brew install yq)

# --- input validators ------------------------------------------------------
# These run BEFORE any yq invocation that would otherwise interpolate the
# value into a yq expression string. Even though we now use strenv(...) for
# the actual lookup, we still want to refuse junk shapes early (and refuse
# data that could later end up in a shell command via $ROUTER_HOST etc.).

_vpn_kit_validate_alias() {
  # alias: [a-zA-Z0-9_-], 1..32 chars. Used as a yaml map key.
  printf '%s' "$1" | grep -qE '^[a-zA-Z0-9_-]{1,32}$'
}

_vpn_kit_validate_host() {
  # Hostnames, FQDNs, IPv4, IPv6-in-brackets-not-supported (we don't use those here).
  # Allow alnum, dot, colon (for IPv6 textually), underscore, hyphen.
  printf '%s' "$1" | grep -qE '^[a-zA-Z0-9.:_-]+$'
}

_vpn_kit_validate_user() {
  printf '%s' "$1" | grep -qE '^[a-zA-Z0-9._-]{1,32}$'
}

_vpn_kit_validate_ssh_alias() {
  printf '%s' "$1" | grep -qE '^[a-zA-Z0-9._-]{1,64}$'
}

_vpn_kit_validate_key_path() {
  # Already ~-expanded upstream; absolute or relative is both fine here, but
  # disallow shell metachars.
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._/~-]+$'
}

resolve_router_config() {
  local alias="$1"
  : "${OPENWRT_SKILL_HOME:?OPENWRT_SKILL_HOME must be set}"
  : "${OPENWRT_SKILL_MEMORY:=$OPENWRT_SKILL_HOME/memory}"

  local registry="$OPENWRT_SKILL_MEMORY/routers.yaml"

  if [ ! -f "$registry" ]; then
    cat >&2 <<EOF
openwrt-skill: registry not found: $registry

Создай его из шаблона:
  cp $OPENWRT_SKILL_MEMORY/routers.yaml.example $registry
И добавь свои роутеры (alias, host, ssh_key).
EOF
    return 2
  fi

  if ! command -v yq >/dev/null 2>&1; then
    echo "openwrt-skill: 'yq' не установлен. brew install yq" >&2
    return 2
  fi

  if [ -z "$alias" ]; then
    # No alias provided — try default_router
    alias="$(yq -r '.default_router // ""' "$registry")"
    if [ -z "$alias" ] || [ "$alias" = "null" ]; then
      echo "openwrt-skill: --router не указан и default_router не задан в routers.yaml" >&2
      _list_routers "$registry" >&2
      return 2
    fi
  fi

  # SECURITY: validate alias BEFORE feeding it into ANY yq expression.
  # Without this, alias=`"; system "..."` corrupts the yq path expression.
  # We additionally use strenv() for the value lookups below, but defence in
  # depth is cheap — refuse the input outright.
  if ! _vpn_kit_validate_alias "$alias"; then
    echo "openwrt-skill: invalid router alias '$alias' (allowed: [a-zA-Z0-9_-]{1,32})" >&2
    return 13
  fi

  # Existence check via strenv (no interpolation into the yq expression).
  if ! ALIAS="$alias" yq -e '.routers[strenv(ALIAS)]' "$registry" >/dev/null 2>&1; then
    echo "openwrt-skill: роутер '$alias' не найден в $registry" >&2
    _list_routers "$registry" >&2
    return 2
  fi

  ROUTER_ALIAS="$alias"
  ROUTER_HOST="$(ALIAS="$alias" yq -r '.routers[strenv(ALIAS)].host'              "$registry")"
  ROUTER_USER="$(ALIAS="$alias" yq -r '.routers[strenv(ALIAS)].user // "root"'    "$registry")"
  ROUTER_SSH_KEY="$(ALIAS="$alias" yq -r '.routers[strenv(ALIAS)].ssh_key // ""'  "$registry")"
  ROUTER_SSH_ALIAS="$(ALIAS="$alias" yq -r '.routers[strenv(ALIAS)].ssh_alias // ""' "$registry")"
  ROUTER_NOTES="$(ALIAS="$alias" yq -r '.routers[strenv(ALIAS)].notes // ""'      "$registry")"

  # Expand leading ~ to $HOME
  if [ -n "$ROUTER_SSH_KEY" ] && [ "$ROUTER_SSH_KEY" != "null" ]; then
    case "$ROUTER_SSH_KEY" in
      "~"|"~/"*) ROUTER_SSH_KEY="${HOME}${ROUTER_SSH_KEY#\~}" ;;
    esac
  else
    ROUTER_SSH_KEY=""
  fi

  [ "$ROUTER_SSH_ALIAS" = "null" ] && ROUTER_SSH_ALIAS=""
  [ "$ROUTER_NOTES" = "null" ] && ROUTER_NOTES=""

  export ROUTER_ALIAS ROUTER_HOST ROUTER_USER ROUTER_SSH_KEY ROUTER_SSH_ALIAS ROUTER_NOTES
  return 0
}

_list_routers() {
  local registry="$1"
  echo
  echo "Доступные роутеры:"
  yq -r '.routers | keys | .[]' "$registry" 2>/dev/null | sed 's/^/  - /'
  echo
}

# Append a new router to routers.yaml. Used by setup-ssh.sh.
register_router() {
  local alias="$1" host="$2" user="$3" key_path="$4" ssh_alias="$5" notes="${6:-}"
  : "${OPENWRT_SKILL_MEMORY:?}"
  local registry="$OPENWRT_SKILL_MEMORY/routers.yaml"

  # --- validate every interpolated input ----------------------------------
  if ! _vpn_kit_validate_alias "$alias"; then
    echo "register_router: invalid alias '$alias' (allowed: [a-zA-Z0-9_-]{1,32})" >&2
    return 13
  fi
  if ! _vpn_kit_validate_host "$host"; then
    echo "register_router: invalid host '$host' (allowed: [a-zA-Z0-9.:_-]+)" >&2
    return 13
  fi
  if ! _vpn_kit_validate_user "$user"; then
    echo "register_router: invalid user '$user' (allowed: [a-zA-Z0-9._-]{1,32})" >&2
    return 13
  fi
  if ! _vpn_kit_validate_ssh_alias "$ssh_alias"; then
    echo "register_router: invalid ssh_alias '$ssh_alias' (allowed: [a-zA-Z0-9._-]{1,64})" >&2
    return 13
  fi
  if ! _vpn_kit_validate_key_path "$key_path"; then
    echo "register_router: invalid key_path '$key_path' (allowed: [A-Za-z0-9._/~-]+)" >&2
    return 13
  fi

  if [ ! -f "$registry" ]; then
    # Initialize from example if user hasn't done it yet
    cp "$OPENWRT_SKILL_MEMORY/routers.yaml.example" "$registry"
    # Strip the example block — keep header only
    yq -i '.routers = {}' "$registry"
  fi

  # All writes go through strenv() so even a (theoretically) tainted local
  # value cannot break out of the yq expression context.
  ALIAS="$alias" V="$host"      yq -i '.routers[strenv(ALIAS)].host      = strenv(V)' "$registry"
  ALIAS="$alias" V="$user"      yq -i '.routers[strenv(ALIAS)].user      = strenv(V)' "$registry"
  ALIAS="$alias" V="$key_path"  yq -i '.routers[strenv(ALIAS)].ssh_key   = strenv(V)' "$registry"
  ALIAS="$alias" V="$ssh_alias" yq -i '.routers[strenv(ALIAS)].ssh_alias = strenv(V)' "$registry"

  # Idempotency: only set notes if currently empty/null. This avoids
  # repeatedly overwriting a user-supplied notes field with the default
  # "added by setup-ssh.sh" on every re-run.
  if [ -n "$notes" ]; then
    local current_notes
    current_notes="$(ALIAS="$alias" yq -r '.routers[strenv(ALIAS)].notes // ""' "$registry")"
    if [ -z "$current_notes" ] || [ "$current_notes" = "null" ]; then
      ALIAS="$alias" V="$notes" yq -i '.routers[strenv(ALIAS)].notes = strenv(V)' "$registry"
    fi
  fi
}
