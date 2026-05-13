#!/usr/bin/env bash
# lib/ssh-runner.sh — thin SSH helpers used by bin/*.sh.
# Source this from a script that already resolved router config via lib/router-config.sh.
# Requires: $ROUTER_HOST, $ROUTER_USER, $ROUTER_SSH_KEY (optional), $ROUTER_SSH_ALIAS (optional).

# Returns the SSH target string: ssh_alias if available, else user@host.
_ssh_target() {
  if [ -n "${ROUTER_SSH_ALIAS:-}" ]; then
    printf '%s' "$ROUTER_SSH_ALIAS"
  else
    printf '%s@%s' "${ROUTER_USER:-root}" "${ROUTER_HOST:?}"
  fi
}

_ssh_key_arg() {
  if [ -n "${ROUTER_SSH_KEY:-}" ] && [ -f "${ROUTER_SSH_KEY:-/nonexistent}" ]; then
    printf -- '-i %s' "$ROUTER_SSH_KEY"
  fi
}

_ssh_common_opts() {
  cat <<EOF
-o BatchMode=yes
-o StrictHostKeyChecking=accept-new
-o ServerAliveInterval=15
-o ServerAliveCountMax=4
EOF
}

# ssh_check_alive — return 0 if router answers within timeout, 1 otherwise.
ssh_check_alive() {
  local timeout="${1:-5}"
  # shellcheck disable=SC2046,SC2086
  ssh $(_ssh_key_arg) $(_ssh_common_opts | xargs) -o ConnectTimeout="$timeout" "$(_ssh_target)" true 2>/dev/null
}

# ssh_run — run a one-liner remote command. Forwards exit code.
# Usage: ssh_run 'uci show network'
ssh_run() {
  local cmd="$1"
  # shellcheck disable=SC2046,SC2086
  ssh $(_ssh_key_arg) $(_ssh_common_opts | xargs) -o ConnectTimeout=15 "$(_ssh_target)" "$cmd"
}

# ssh_run_remote — send a script via stdin and run on the router.
# Usage: ssh_run_remote < bin/_doctor_remote.sh
ssh_run_remote() {
  # shellcheck disable=SC2046,SC2086
  ssh $(_ssh_key_arg) $(_ssh_common_opts | xargs) -o ConnectTimeout=15 "$(_ssh_target)" 'sh -s'
}

# scp_to — copy a local file to the router.
# Usage: scp_to <local-path> <remote-path>
# -O forces legacy SCP protocol so we don't depend on openssh-sftp-server
# being installed on the router (minimal OpenWRT builds ship sshd without it).
scp_to() {
  local src="$1" dst="$2"
  # shellcheck disable=SC2046,SC2086
  scp -O $(_ssh_key_arg) $(_ssh_common_opts | xargs) -o ConnectTimeout=15 "$src" "$(_ssh_target):$dst"
}

# scp_from — copy a remote file to local.
scp_from() {
  local src="$1" dst="$2"
  # shellcheck disable=SC2046,SC2086
  scp -O $(_ssh_key_arg) $(_ssh_common_opts | xargs) -o ConnectTimeout=15 "$(_ssh_target):$src" "$dst"
}

# ssh_run_remote_with_args — pipe a script via stdin AND supply positional args.
# Usage: ssh_run_remote_with_args /path/to/script.sh "arg1" "arg2"
ssh_run_remote_with_args() {
  local script="$1"; shift
  # Encode args as a single safe string passed as first command arg
  local args=""
  for a in "$@"; do
    args+=$(printf '%q ' "$a")
  done
  # shellcheck disable=SC2046,SC2086
  ssh $(_ssh_key_arg) $(_ssh_common_opts | xargs) -o ConnectTimeout=15 "$(_ssh_target)" \
    "sh -s -- $args" < "$script"
}
