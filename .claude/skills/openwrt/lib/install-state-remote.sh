#!/usr/bin/env bash
# lib/install-state-remote.sh — thin agent-side wrapper around the on-router
# state-write.sh / state-read.sh, providing CAS read+write of
# /etc/vpn-kit/install-state.json over SSH.
#
# Contract:
#   - lib/ssh-runner.sh MUST be sourced first by the caller, with
#     ROUTER_HOST/ROUTER_USER (or ROUTER_SSH_ALIAS) already resolved via
#     lib/router-config.sh.
#   - Local `jq` is required for parsing the read-side; remote `jq` is required
#     by state-{read,write}.sh and is checked by install-safety.sh on deploy.
#   - Caller is responsible for merging dynamic_additions[] / domain mutations
#     into the JSON payload via jq BEFORE calling remote_cas_write. This shim
#     does NOT do any business-level merge.
#
# Exit codes (mirror state-write.sh):
#   0   committed; new revision printed on stdout
#   2   state file does not exist on router (only from remote_read_state_json
#       when called with --strict; default: returns "{}" with rc=0)
#   11  STALE: caller's --expected-revision != on-disk revision
#   12  LOCK: could not acquire lock on router
#   13  VALIDATION: malformed JSON / bad args
#   2x  SSH transport failure (whatever ssh returns)

# Guard against double-source.
if [ -n "${_VPN_KIT_INSTALL_STATE_REMOTE_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_VPN_KIT_INSTALL_STATE_REMOTE_LOADED=1

: "${VPN_KIT_REMOTE_STATE_FILE:=/etc/vpn-kit/install-state.json}"
: "${VPN_KIT_REMOTE_LIB_DIR:=/usr/lib/vpn-kit}"
: "${VPN_KIT_REMOTE_TMP_DIR:=/tmp}"
: "${VPN_KIT_CAS_MAX_RETRIES:=3}"

# remote_read_revision <alias-unused-kept-for-symmetry>
# Echoes current on-router revision (0 if file missing). rc=0 on success,
# rc=13 if remote file exists but is malformed JSON.
remote_read_revision() {
  local rev rc out
  out="$(ssh_run "$VPN_KIT_REMOTE_LIB_DIR/state-read.sh --revision" 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    # state file absent — initial revision
    echo "0"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  rev="$(printf '%s' "$out" | tr -d '[:space:]')"
  case "$rev" in
    ''|*[!0-9]*) echo "remote_read_revision: bad revision: '$rev'" >&2; return 13 ;;
  esac
  printf '%s\n' "$rev"
}

# remote_read_state_json
# Echoes the full install-state.json from the router. If absent, echoes "{}"
# and returns 0 (so callers can pipe into jq unconditionally).
remote_read_state_json() {
  local out rc
  out="$(ssh_run "$VPN_KIT_REMOTE_LIB_DIR/state-read.sh" 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf '{}\n'
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  printf '%s\n' "$out"
}

# remote_cas_write <writer> <expected_revision> <new_json_payload>
# Sends the payload to /tmp on the router, invokes state-write.sh with CAS
# semantics, cleans up /tmp. Retries on LOCK (12) with jittered sleep; STALE
# (11) propagates immediately — caller must re-read and rebuild.
# On success, echoes the new revision (state-write.sh stdout) and returns 0.
remote_cas_write() {
  local writer="$1" expected_rev="$2" payload="$3"
  local attempt=1 rc out tmp

  if [ -z "$writer" ] || [ -z "$expected_rev" ] || [ -z "$payload" ]; then
    echo "remote_cas_write: writer/expected_rev/payload required" >&2
    return 13
  fi

  # Sanity-check payload locally before paying SSH RTT.
  if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "remote_cas_write: payload is not a valid JSON object" >&2
    return 13
  fi

  tmp="$VPN_KIT_REMOTE_TMP_DIR/vpn-kit-install-state.$$.json"

  while [ "$attempt" -le "$VPN_KIT_CAS_MAX_RETRIES" ]; do
    # Push payload to /tmp via stdin (avoids local temp file + scp roundtrip).
    if ! printf '%s' "$payload" | ssh_run "cat > '$tmp'"; then
      echo "remote_cas_write: failed to upload payload to $tmp" >&2
      return 2
    fi

    # Invoke remote state-write.sh; capture stdout (new revision).
    out="$(ssh_run "$VPN_KIT_REMOTE_LIB_DIR/state-write.sh \
      --expected-revision '$expected_rev' \
      --writer '$writer' \
      < '$tmp' \
      ; rc=\$? ; rm -f '$tmp' ; exit \$rc")"
    rc=$?

    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi

    if [ "$rc" -eq 11 ] || [ "$rc" -eq 13 ]; then
      # STALE or VALIDATION — no point retrying; caller must rebuild.
      return "$rc"
    fi

    if [ "$rc" -ne 12 ]; then
      # Unknown failure (ssh transport / unexpected). Don't loop forever.
      return "$rc"
    fi

    # LOCK contention — jittered backoff 100-1100ms.
    if [ "$attempt" -lt "$VPN_KIT_CAS_MAX_RETRIES" ]; then
      local jitter_ms
      jitter_ms=$(awk 'BEGIN{srand(); print 100 + int(rand()*1000)}')
      sleep "$(awk -v ms="$jitter_ms" 'BEGIN{printf "%.3f", ms/1000}')"
    fi
    attempt=$((attempt + 1))
  done

  return 12
}
