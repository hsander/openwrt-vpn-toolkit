#!/bin/sh
# lan-migrate-runtime.sh — router-local transactional LAN migration runtime.
#
# A prepared bundle contains manifest.json, files/* and scripts/{apply,verify,rollback}.sh.
# The rollback timer remains armed while state is applied_unconfirmed. Only an
# explicit confirm commits the install state and removes the timer.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=vpn-kit-common.sh
. "$SCRIPT_DIR/vpn-kit-common.sh"

vpn_kit_require_cmd jq

: "${VPN_KIT_LAN_MIGRATION_DIR:=/etc/vpn-kit/lan-migrations}"

# Every live phase that can execute a lifecycle script owns a dedicated
# session/process group. This lets timer rollback terminate the whole tree,
# including a hung verify/rollback child that inherited the flock fd.
if [ "${VPN_KIT_LAN_SESSION:-0}" != 1 ] \
  && { [ -z "$VPN_KIT_TARGET_ROOT" ] || [ "${VPN_KIT_FORCE_SESSION:-0}" = 1 ]; }; then
  _needs_session=false
  case "${1:-}" in
    confirm|rollback) _needs_session=true ;;
    cutover)
      for _arg in "$@"; do [ "$_arg" = --foreground ] && _needs_session=true; done ;;
  esac
  if [ "$_needs_session" = true ]; then
    command -v setsid >/dev/null 2>&1 || {
      echo "lan-migrate: setsid is required for $1" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    }
    if [ -r "/proc/$$/stat" ]; then
      _current_pgid="$(awk '{print $5}' "/proc/$$/stat")"
    else
      _current_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
    fi
    if [ "$_current_pgid" != "$$" ]; then
      exec setsid env VPN_KIT_LAN_SESSION=1 "$0" "$@"
    fi
  fi
fi

usage() {
  cat <<'EOF'
Usage:
  vpn-kit-lan-migrate prepare --migration-id <id> --bundle-dir <dir>
  vpn-kit-lan-migrate cutover --migration-id <id> [--timeout-seconds <n>] [--foreground]
  vpn-kit-lan-migrate confirm --migration-id <id>
  vpn-kit-lan-migrate rollback --migration-id <id>
  vpn-kit-lan-migrate status --migration-id <id>
EOF
}

phase="${1:-}"
[ -n "$phase" ] || { usage >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
shift

migration_id=""
bundle_dir=""
timeout_seconds=900
foreground=false

while [ $# -gt 0 ]; do
  case "$1" in
    --migration-id) migration_id="${2:-}"; shift 2 ;;
    --bundle-dir) bundle_dir="${2:-}"; shift 2 ;;
    --timeout-seconds) timeout_seconds="${2:-}"; shift 2 ;;
    --foreground) foreground=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "lan-migrate: unknown arg: $1" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
  esac
done

vpn_kit_validate_step_id "$migration_id" || {
  echo "lan-migrate: invalid migration id: $migration_id" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
}
case "$timeout_seconds" in
  ''|*[!0-9]*) echo "lan-migrate: timeout must be an integer" >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac
[ "$timeout_seconds" -ge 60 ] || {
  echo "lan-migrate: timeout must be at least 60 seconds" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
}

migration_root="$(vpn_kit_target_path "$VPN_KIT_LAN_MIGRATION_DIR")"
migration_dir="$migration_root/$migration_id"
status_file="$migration_dir/status.json"
manifest="$migration_dir/manifest.json"
timer_file="$VPN_KIT_ROLLBACK_DIR/$migration_id.timer"

# Serialize state transitions. A detached cutover launcher does not own the
# lock; its foreground child acquires it and acknowledges only after the timer
# is armed. Explicit/timer rollback may preempt a stuck owner.
lock_owned=false
rollback_gate_owned=false
detached_launcher=false
[ "$phase" = cutover ] && [ "$foreground" != true ] && detached_launcher=true
lock_token="lan-$migration_id-$$-$(date +%s)"

process_start_id() {
  _pid="$1"
  if [ -r "/proc/$_pid/stat" ]; then
    awk '{print $22}' "/proc/$_pid/stat"
  else
    ps -o lstart= -p "$_pid" 2>/dev/null | sed 's/^ *//'
  fi
}

process_group_id() {
  _pid="$1"
  if [ -r "/proc/$_pid/stat" ]; then
    awk '{print $5}' "/proc/$_pid/stat"
  else
    ps -o pgid= -p "$_pid" 2>/dev/null | tr -d ' '
  fi
}

process_command() {
  _pid="$1"
  if [ -r "/proc/$_pid/cmdline" ]; then
    tr '\000' ' ' < "/proc/$_pid/cmdline"
  else
    ps -o command= -p "$_pid" 2>/dev/null
  fi
}

flock_wait_exclusive() {
  _fd="$1" _timeout="$2" _elapsed=0
  while ! flock -x -n "$_fd"; do
    [ "$_elapsed" -lt "$_timeout" ] || return 1
    sleep 1
    _elapsed=$((_elapsed + 1))
  done
}

release_transition_lock() {
  [ "$lock_owned" = true ] || return 0
  if [ -f "$transition_owner" ] \
    && [ "$(jq -r '.token // ""' "$transition_owner" 2>/dev/null || true)" = "$lock_token" ]; then
    rm -f "$transition_owner"
  fi
  exec 9>&-
  lock_owned=false
  if [ "$rollback_gate_owned" = true ]; then
    exec 8>&-
    rollback_gate_owned=false
  fi
}

on_term() {
  release_transition_lock
  trap - EXIT INT TERM
  exit 143
}

on_int() {
  release_transition_lock
  trap - EXIT INT TERM
  exit 130
}

owner_is_current_runtime() {
  [ -f "$transition_owner" ] || return 1
  _owner="$(jq -r '.pid // ""' "$transition_owner" 2>/dev/null || true)"
  _owner_start="$(jq -r '.start_id // ""' "$transition_owner" 2>/dev/null || true)"
  case "$_owner" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_owner" 2>/dev/null || return 1
  [ "$(process_start_id "$_owner")" = "$_owner_start" ] || return 1
  _command="$(process_command "$_owner")"
  printf '%s\n' "$_command" | grep -q 'lan-migrate-runtime.sh' || return 1
  printf '%s\n' "$_command" | grep -q -- "--migration-id $migration_id" || return 1
  return 0
}

stop_owner_tree() {
  _owner="$(jq -r '.pid' "$transition_owner")"
  _pgid="$(jq -r '.pgid // ""' "$transition_owner")"
  if [ "$_pgid" = "$_owner" ]; then
    kill -TERM "-$_pgid" 2>/dev/null || true
  else
    kill -TERM "$_owner" 2>/dev/null || true
  fi
  sleep 1
  if [ "$_pgid" = "$_owner" ]; then
    kill -KILL "-$_pgid" 2>/dev/null || true
    _tries=0
    while kill -0 "-$_pgid" 2>/dev/null && [ "$_tries" -lt 5 ]; do sleep 1; _tries=$((_tries + 1)); done
  else
    kill -KILL "$_owner" 2>/dev/null || true
    _tries=0
    while kill -0 "$_owner" 2>/dev/null && [ "$_tries" -lt 5 ]; do sleep 1; _tries=$((_tries + 1)); done
  fi
  # The subsequent flock acquisition is the authoritative proof that the
  # previous owner and all children which inherited fd 9 have exited.
  return 0
}

if [ "$phase" != rollback-applied ] && [ "$detached_launcher" != true ]; then
  vpn_kit_require_cmd flock
  transition_lock="$VPN_KIT_LOCK_DIR/vpn-kit-lan-$migration_id.lock"
  transition_owner="$transition_lock.owner.json"
  rollback_gate="$transition_lock.rollback-priority"
  mkdir -p "$VPN_KIT_LOCK_DIR"
  if [ "$phase" = rollback ]; then
    exec 8>"$rollback_gate"
    flock_wait_exclusive 8 "$VPN_KIT_LOCK_TIMEOUT" || {
      echo "lan-migrate: another rollback is already in progress" >&2
      exit "$VPN_KIT_EXIT_LOCK"
    }
    rollback_gate_owned=true
  fi
  exec 9>"$transition_lock"
  if ! flock -x -n 9; then
    if [ "$phase" = rollback ] && owner_is_current_runtime; then
      _owner="$(jq -r '.pid' "$transition_owner")"
      echo "lan-migrate: rollback preempts stuck transition pid=$_owner" >&2
      stop_owner_tree || {
        echo "lan-migrate: failed to stop active cutover process group" >&2
        exit "$VPN_KIT_EXIT_LOCK"
      }
    fi
    flock_wait_exclusive 9 "$VPN_KIT_LOCK_TIMEOUT" || {
      echo "lan-migrate: another transition is active: $migration_id" >&2
      exit "$VPN_KIT_EXIT_LOCK"
    }
  fi
  if [ "$phase" != rollback ]; then
    exec 8>"$rollback_gate"
    if ! flock -s -n 8; then
      exec 8>&-
      exec 9>&-
      echo "lan-migrate: rollback acquired priority: $migration_id" >&2
      exit "$VPN_KIT_EXIT_LOCK"
    fi
    exec 8>&-
  fi
  _start_id="$(process_start_id "$$")"
  _pgid="$(process_group_id "$$")"
  jq -n --argjson pid "$$" --arg start_id "$_start_id" --arg pgid "$_pgid" --arg token "$lock_token" \
    '{pid:$pid,start_id:$start_id,pgid:$pgid,token:$token}' \
    | vpn_kit_atomic_write "$transition_owner"
  lock_owned=true
  trap 'release_transition_lock' EXIT
  trap 'on_int' INT
  trap 'on_term' TERM
  case "${VPN_KIT_TEST_HOLD_LOCK_SECONDS:-0}" in
    ''|*[!0-9]*) ;;
    0) ;;
    *) sleep "$VPN_KIT_TEST_HOLD_LOCK_SECONDS" ;;
  esac
fi

write_status() {
  _state="$1"
  _detail="${2:-}"
  _snapshot="${3:-}"
  jq -n \
    --arg migration_id "$migration_id" \
    --arg state "$_state" \
    --arg detail "$_detail" \
    --arg snapshot_path "$_snapshot" \
    --arg updated_at "$(vpn_kit_now_iso8601)" \
    '{migration_id:$migration_id,state:$state,detail:$detail,updated_at:$updated_at}
     + (if ($snapshot_path | length) > 0 then {snapshot_path:$snapshot_path} else {} end)' \
    | vpn_kit_atomic_write "$status_file"
}

manifest_valid() {
  jq -e --arg id "$migration_id" '
    .schema_version == 1
    and .migration_id == $id
    and (.files | type == "array" and length > 0)
    and (.scripts | type == "object")
    and all(.files[];
      (.path | type == "string" and startswith("/"))
      and (.staged | type == "string" and startswith("files/"))
      and (.mode | type == "string")
      and (.before_sha256 | type == "string")
      and (.staged_sha256 | type == "string"))
  ' "$manifest" >/dev/null 2>&1 || return 1

  _count="$(jq '.files | length' "$manifest")"
  [ "$(jq '[.files[].path] | unique | length' "$manifest")" = "$_count" ] || return 1
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _path="$(jq -r ".files[$_i].path" "$manifest")"
    _staged="$(jq -r ".files[$_i].staged" "$manifest")"
    _before="$(jq -r ".files[$_i].before_sha256" "$manifest")"
    _after="$(jq -r ".files[$_i].staged_sha256" "$manifest")"
    _mode="$(jq -r ".files[$_i].mode" "$manifest")"
    case "$_staged" in
      files/*) _name="${_staged#files/}" ;;
      *) return 1 ;;
    esac
    case "$_name" in ''|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    case "$_path" in
      /etc/config/network|/etc/config/dhcp|/etc/config/firewall|/etc/sing-box/config.json|/etc/init.d/sing-box-tproxy|/usr/bin/polsha-fallback-watchdog|/usr/sbin/polsha-fallback-watchdog|/etc/polsha-fallback-watchdog.sh) ;;
      *) return 1 ;;
    esac
    _target="$(vpn_kit_target_path "$_path")"
    [ ! -L "$_target" ] || return 1
    printf '%s\n' "$_before" | grep -qE '^[0-9a-f]{64}$' || return 1
    printf '%s\n' "$_after" | grep -qE '^[0-9a-f]{64}$' || return 1
    case "$_mode" in 0600|0640|0644|0700|0750|0755) ;; *) return 1 ;; esac
    _i=$((_i + 1))
  done
  for _name in apply verify rollback; do
    _hash="$(jq -r ".scripts.$_name // \"\"" "$manifest")"
    printf '%s\n' "$_hash" | grep -qE '^[0-9a-f]{64}$' || return 1
  done
}

sha_file() {
  [ -f "$1" ] || { printf 'missing'; return; }
  vpn_kit_sha256 < "$1"
}

check_files() {
  _kind="$1"
  _count="$(jq '.files | length' "$manifest")"
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _path="$(jq -r ".files[$_i].path" "$manifest")"
    _target="$(vpn_kit_target_path "$_path")"
    if [ "$_kind" = before ]; then
      _expected="$(jq -r ".files[$_i].before_sha256" "$manifest")"
      _actual="$(sha_file "$_target")"
    else
      _staged="$(jq -r ".files[$_i].staged" "$manifest")"
      _expected="$(jq -r ".files[$_i].staged_sha256" "$manifest")"
      [ ! -L "$migration_dir/$_staged" ] || {
        echo "lan-migrate: staged file must not be a symlink: $_staged" >&2
        return "$VPN_KIT_EXIT_VALIDATION"
      }
      _actual="$(sha_file "$migration_dir/$_staged")"
    fi
    if [ "$_actual" != "$_expected" ]; then
      echo "lan-migrate: checksum mismatch ($_kind): $_path" >&2
      return "$VPN_KIT_EXIT_STALE"
    fi
    _i=$((_i + 1))
  done
}

check_scripts() {
  for _name in apply verify rollback; do
    _script="$migration_dir/scripts/$_name.sh"
    [ -f "$_script" ] && [ ! -L "$_script" ] || {
      echo "lan-migrate: invalid bundle script: scripts/$_name.sh" >&2
      return "$VPN_KIT_EXIT_VALIDATION"
    }
    _expected="$(jq -r ".scripts.$_name" "$manifest")"
    _actual="$(sha_file "$_script")"
    [ "$_actual" = "$_expected" ] || {
      echo "lan-migrate: script checksum mismatch: scripts/$_name.sh" >&2
      return "$VPN_KIT_EXIT_STALE"
    }
  done
}

snapshot_files() {
  _snapshot="$1"
  mkdir -p "$_snapshot/files"
  if [ -f "$VPN_KIT_STATE_FILE" ]; then
    cp "$VPN_KIT_STATE_FILE" "$_snapshot/state-before.json"
  else
    printf '{}\n' > "$_snapshot/state-before.json"
  fi
  _files='[]'
  _count="$(jq '.files | length' "$manifest")"
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _path="$(jq -r ".files[$_i].path" "$manifest")"
    _target="$(vpn_kit_target_path "$_path")"
    _backup="files/$_i-$(vpn_kit_safe_name "$_path")"
    if [ -e "$_target" ]; then
      cp -p "$_target" "$_snapshot/$_backup"
      _existed=true
    else
      _existed=false
    fi
    _files="$(printf '%s' "$_files" | jq \
      --arg path "$_target" --arg backup "$_backup" --argjson existed "$_existed" \
      '. + [{path:$path,backup:$backup,existed:$existed}]')"
    _i=$((_i + 1))
  done
  _rollback="$SCRIPT_DIR/lan-migrate-runtime.sh rollback-applied --migration-id $migration_id"
  printf '%s\n' "$_files" | jq \
    --arg step_id "$migration_id" \
    --arg created_at "$(vpn_kit_now_iso8601)" \
    --arg rollback_command "$_rollback" \
    '{step_id:$step_id,created_at:$created_at,state_revision_before:0,restore_state:false,files:.,rollback_command:$rollback_command}' \
    > "$_snapshot/meta.json"
}

copy_staged_files() {
  _count="$(jq '.files | length' "$manifest")"
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _path="$(jq -r ".files[$_i].path" "$manifest")"
    _target="$(vpn_kit_target_path "$_path")"
    _staged="$(jq -r ".files[$_i].staged" "$manifest")"
    _mode="$(jq -r ".files[$_i].mode" "$manifest")"
    mkdir -p "$(dirname "$_target")"
    cp "$migration_dir/$_staged" "$_target"
    chmod "$_mode" "$_target"
    _i=$((_i + 1))
  done
}

run_bundle_script() {
  _name="$1"
  _script="$migration_dir/scripts/$_name.sh"
  [ -f "$_script" ] || {
    echo "lan-migrate: missing bundle script: scripts/$_name.sh" >&2
    return "$VPN_KIT_EXIT_VALIDATION"
  }
  VPN_KIT_MIGRATION_ID="$migration_id" \
  VPN_KIT_MIGRATION_DIR="$migration_dir" \
  VPN_KIT_TARGET_ROOT="$VPN_KIT_TARGET_ROOT" \
    sh "$_script"
}

do_rollback() {
  _trigger="${1:-explicit}"
  [ -f "$status_file" ] || { echo "lan-migrate: migration not found" >&2; return "$VPN_KIT_EXIT_VALIDATION"; }
  _state="$(jq -r '.state' "$status_file")"
  case "$_state" in
    rolled_back|cancelled) return 0 ;;
    prepared)
      _snapshot="$(jq -r '.snapshot_path // ""' "$status_file")"
      [ -n "$_snapshot" ] && "$SCRIPT_DIR/snapshot-gc.sh" --delete-success "$_snapshot" >/dev/null 2>&1 || true
      write_status cancelled "prepared migration cancelled without restoring files"
      return 0 ;;
    confirmed)
      _snapshot="$(jq -r '.snapshot_path // ""' "$status_file")"
      rm -f "$timer_file"
      [ -n "$_snapshot" ] && "$SCRIPT_DIR/snapshot-gc.sh" --delete-success "$_snapshot" >/dev/null 2>&1 || true
      write_status committed "confirmation finalized"
      return 0 ;;
    applying|applied_unconfirmed|rollback_failed) ;;
    committed)
      echo "lan-migrate: committed migration cannot be rolled back automatically" >&2
      return "$VPN_KIT_EXIT_STALE" ;;
    *)
      echo "lan-migrate: rollback is not allowed from state $_state" >&2
      return "$VPN_KIT_EXIT_STALE" ;;
  esac
  _snapshot="$(jq -r '.snapshot_path // ""' "$status_file")"
  [ -n "$_snapshot" ] && [ -d "$_snapshot" ] || {
    echo "lan-migrate: snapshot unavailable" >&2
    return "$VPN_KIT_EXIT_VALIDATION"
  }
  "$SCRIPT_DIR/rollback-snapshot.sh" --snapshot "$_snapshot" --step-id "$migration_id" --triggered-by "$_trigger"
  rm -f "$timer_file"
  write_status rolled_back "rollback completed" "$(vpn_kit_target_path "$VPN_KIT_SNAPSHOT_DIR")/rolled-back/$(basename "$_snapshot")"
}

case "$phase" in
  prepare)
    [ -n "$bundle_dir" ] && [ -f "$bundle_dir/manifest.json" ] || {
      echo "lan-migrate: prepare requires --bundle-dir" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    }
    [ ! -e "$migration_dir" ] || {
      echo "lan-migrate: migration already exists: $migration_id" >&2
      exit "$VPN_KIT_EXIT_STALE"
    }
    mkdir -p "$migration_root"
    cp -R "$bundle_dir" "$migration_dir"
    manifest_valid || {
      rm -rf "$migration_dir"
      echo "lan-migrate: invalid manifest" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    }
    check_files staged || { rm -rf "$migration_dir"; exit "$VPN_KIT_EXIT_STALE"; }
    check_files before || { rm -rf "$migration_dir"; exit "$VPN_KIT_EXIT_STALE"; }
    check_scripts || { rm -rf "$migration_dir"; exit "$VPN_KIT_EXIT_STALE"; }
    chmod -R go-rwx "$migration_dir"
    mkdir -p "$VPN_KIT_SNAPSHOT_DIR"
    _snapshot="$VPN_KIT_SNAPSHOT_DIR/$migration_id-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    snapshot_files "$_snapshot"
    write_status prepared "validated; no network changes applied" "$_snapshot"
    cat "$status_file"
    ;;
  cutover)
    [ -f "$status_file" ] || { echo "lan-migrate: migration not found" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
    _state="$(jq -r '.state' "$status_file")"
    if [ "$_state" = applied_unconfirmed ]; then cat "$status_file"; exit 0; fi
    [ "$_state" = prepared ] || { echo "lan-migrate: cutover requires prepared state, got $_state" >&2; exit "$VPN_KIT_EXIT_STALE"; }
    if [ "$foreground" != true ]; then
      if command -v setsid >/dev/null 2>&1; then
        _launcher=setsid
      elif [ -z "$VPN_KIT_TARGET_ROOT" ]; then
        {
          echo "lan-migrate: setsid is required for detached cutover" >&2
          exit "$VPN_KIT_EXIT_VALIDATION"
        }
      else
        _launcher=''
      fi
      _log="$migration_dir/cutover.log"
      if [ -n "$_launcher" ]; then
        $_launcher "$SCRIPT_DIR/lan-migrate-runtime.sh" cutover --migration-id "$migration_id" \
          --timeout-seconds "$timeout_seconds" --foreground >"$_log" 2>&1 </dev/null &
      else
        "$SCRIPT_DIR/lan-migrate-runtime.sh" cutover --migration-id "$migration_id" \
          --timeout-seconds "$timeout_seconds" --foreground >"$_log" 2>&1 </dev/null &
      fi
      _child=$!
      _attempt=0
      while [ "$_attempt" -lt 15 ]; do
        if [ -f "$status_file" ] && [ -f "$timer_file" ]; then
          _child_state="$(jq -r '.state // ""' "$status_file" 2>/dev/null || true)"
          case "$_child_state" in
            applying|applied_unconfirmed)
              jq -n --arg migration_id "$migration_id" --arg state "$_child_state" --arg log "$_log" \
                '{migration_id:$migration_id,state:$state,rollback_armed:true,log:$log}'
              exit 0 ;;
          esac
        fi
        if ! kill -0 "$_child" 2>/dev/null; then
          echo "lan-migrate: detached cutover exited before rollback was armed" >&2
          tail -n 20 "$_log" >&2 2>/dev/null || true
          exit "$VPN_KIT_EXIT_VALIDATION"
        fi
        sleep 1
        _attempt=$((_attempt + 1))
      done
      if [ -n "$_launcher" ]; then
        kill -TERM "-$_child" 2>/dev/null || true
      else
        kill -TERM "$_child" 2>/dev/null || true
      fi
      sleep 1
      if [ -n "$_launcher" ]; then
        kill -KILL "-$_child" 2>/dev/null || true
        _stop_attempt=0
        while kill -0 "-$_child" 2>/dev/null && [ "$_stop_attempt" -lt 5 ]; do sleep 1; _stop_attempt=$((_stop_attempt + 1)); done
      else
        kill -KILL "$_child" 2>/dev/null || true
        _stop_attempt=0
        while kill -0 "$_child" 2>/dev/null && [ "$_stop_attempt" -lt 5 ]; do sleep 1; _stop_attempt=$((_stop_attempt + 1)); done
      fi
      echo "lan-migrate: detached cutover did not arm rollback within 15 seconds" >&2
      exit "$VPN_KIT_EXIT_VALIDATION"
    fi
    check_files before || exit "$VPN_KIT_EXIT_STALE"
    check_files staged || exit "$VPN_KIT_EXIT_STALE"
    check_scripts || exit "$VPN_KIT_EXIT_STALE"
    if [ -z "$VPN_KIT_TARGET_ROOT" ]; then
      [ -x /etc/init.d/vpn-kit-rollback ] \
        && /etc/init.d/vpn-kit-rollback enabled \
        && /etc/init.d/vpn-kit-rollback running || {
          echo "lan-migrate: rollback daemon is not enabled and running" >&2
          exit "$VPN_KIT_EXIT_VALIDATION"
        }
    fi
    _snapshot="$(jq -r '.snapshot_path' "$status_file")"
    _deadline=$(( $(date +%s) + timeout_seconds ))
    mkdir -p "$VPN_KIT_ROLLBACK_DIR"
    jq -n --arg step_id "$migration_id" --arg snapshot_path "$_snapshot" \
      --arg handler_command "$SCRIPT_DIR/lan-migrate-runtime.sh rollback --migration-id $migration_id" \
      --argjson deadline_unix "$_deadline" \
      '{step_id:$step_id,timer_type:"lan_migration",deadline_unix:$deadline_unix,snapshot_path:$snapshot_path,
        state_revision_before:0,handler_command:$handler_command}' \
      | vpn_kit_atomic_write "$timer_file"
    write_status applying "rollback timer armed" "$_snapshot"
    if ! copy_staged_files || ! run_bundle_script apply || ! run_bundle_script verify; then
      if do_rollback apply_failure; then
        exit "$VPN_KIT_EXIT_VALIDATION"
      fi
      write_status rollback_failed "automatic rollback failed; timer remains armed" "$_snapshot"
      exit 30
    fi
    write_status applied_unconfirmed "external confirmation required" "$_snapshot"
    cat "$status_file"
    ;;
  confirm)
    [ -f "$status_file" ] || { echo "lan-migrate: migration not found" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
    _state="$(jq -r '.state' "$status_file")"
    if [ "$_state" = committed ]; then cat "$status_file"; exit 0; fi
    if [ "$_state" = applied_unconfirmed ]; then
      check_scripts || exit "$VPN_KIT_EXIT_STALE"
      run_bundle_script verify
      _snapshot="$(jq -r '.snapshot_path' "$status_file")"
      write_status confirmed "external confirmation durable; cleanup pending" "$_snapshot"
    elif [ "$_state" != confirmed ]; then
      echo "lan-migrate: confirm requires applied_unconfirmed state" >&2
      exit "$VPN_KIT_EXIT_STALE"
    fi
    _snapshot="$(jq -r '.snapshot_path' "$status_file")"
    rm -f "$timer_file"
    "$SCRIPT_DIR/snapshot-gc.sh" --delete-success "$_snapshot" >/dev/null
    write_status committed "externally confirmed"
    cat "$status_file"
    ;;
  rollback)
    do_rollback explicit
    cat "$status_file"
    ;;
  rollback-applied)
    # Called by rollback-snapshot after files have already been restored.
    run_bundle_script rollback
    write_status rolled_back "timer restored snapshot"
    ;;
  status)
    [ -f "$status_file" ] || { echo "lan-migrate: migration not found" >&2; exit "$VPN_KIT_EXIT_VALIDATION"; }
    cat "$status_file"
    ;;
  *) usage >&2; exit "$VPN_KIT_EXIT_VALIDATION" ;;
esac
