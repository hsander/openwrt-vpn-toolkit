#!/usr/bin/env bash
# bin/restore.sh — restore router state from a /etc/vpn-kit/snapshots/<id>.tar.gz.
#
# Flow:
#   1. Resolve router + SSH alive.
#   2. Validate snapshot pair exists on router (.tar.gz + .meta.json).
#   3. Verify tarball sha256 against meta (unless --force).
#   4. Take a "safety" pre-restore snapshot via bin/backup-now.sh (unless --no-pre-backup),
#      so we can undo a bad restore.
#   5. tar -xzf snapshot -C / on the router (overwrite).
#   6. sing-box check on the restored config. If invalid → roll forward to the
#      safety snapshot and exit 20. Don't leave the router in a broken state.
#   7. Reload services: sing-box-tproxy, zapret2 (if present), dnsmasq, fw4.
#   8. Reachability watch (30s). If SSH dies — print panic message with the
#      safety snapshot id so the user can recover manually.
#   9. Refresh state.md via bin/doctor.sh (--no-render off — we want it written).
#  10. Journal the restore. memory MAY BE STALE (domains.md/vpns.md/proxies.md
#      not regenerated); journal entry calls this out.
#
# Usage:
#   bin/restore.sh --router <alias> --snapshot <id> [--force] [--no-pre-backup]
#
# Exit codes:
#   0   ok
#   2   router not found / SSH unreachable
#  13   validation (snapshot missing, sha mismatch w/o --force, secret in field)
#  20   restored state invalid → automatically rolled back to safety snapshot
#       (fires on sing-box-check failure OR post-restore reachability loss)
#  30   CATASTROPHIC: rollback to safety snapshot ALSO failed — router state
#       is unknown, manual recovery required (commands printed)
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
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/restore.sh --router <alias> --snapshot <id> [--force] [--no-pre-backup]

Восстанавливает роутер из снимка /etc/vpn-kit/snapshots/<id>.tar.gz.
ПЕРЕД restore'ом снимается "safety" snapshot — чтобы можно было откатить откат.

Options:
  --router <alias>     alias из memory/routers.yaml (обяз.)
  --snapshot <id>      snap-YYYYMMDDTHHMMSSZ из bin/snapshot-list.sh (обяз.)
  --force              продолжить даже при mismatch sha256 (опасно)
  --no-pre-backup      НЕ делать safety-snapshot перед restore (НЕ рекомендуется)
EOF
  exit 64
}

router=""
snapshot=""
force=0
no_pre_backup=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --snapshot) snapshot="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    --no-pre-backup) no_pre_backup=1; shift ;;
    -h|--help) usage ;;
    *) echo "restore: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "restore: --router обязателен" >&2; usage; }
[ -z "$snapshot" ] && { echo "restore: --snapshot обязателен" >&2; usage; }

# --- Resolve router + SSH alive ------------------------------------------------
# Done BEFORE snapshot-id shape validation so an unreachable-host error
# (exit 2) takes precedence over a bad-id error (exit 13).
resolve_router_config "$router"

if ! ssh_check_alive 5; then
  cat >&2 <<EOF
restore: SSH недоступен для '$ROUTER_ALIAS' (host=$ROUTER_HOST, user=$ROUTER_USER).
Проверь: ping -c1 $ROUTER_HOST, или bin/setup-ssh.sh --router $ROUTER_ALIAS
EOF
  exit 2
fi

# Validate snapshot id shape (snap-YYYYMMDDTHHMMSSZ OR inline-...).
case "$snapshot" in
  snap-*|inline-*) ;;
  *) echo "restore: невалидный --snapshot id '$snapshot' (ожидался 'snap-...' или 'inline-...')" >&2; exit 13 ;;
esac

SNAP_DIR_REMOTE="/etc/vpn-kit/snapshots"
TAR_PATH="$SNAP_DIR_REMOTE/${snapshot}.tar.gz"
META_PATH="$SNAP_DIR_REMOTE/${snapshot}.meta.json"

# --- Step 1: validate presence + sha256 ----------------------------------------
# Probe the snapshot in one ssh round-trip.
probe_out="$(ssh_run "
set -u
TAR='$TAR_PATH'
META='$META_PATH'
if [ ! -f \"\$TAR\" ]; then echo 'missing_tar=1'; fi
if [ ! -f \"\$META\" ]; then echo 'missing_meta=1'; fi
if [ -f \"\$TAR\" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    SHA=\"\$(sha256sum \"\$TAR\" | awk '{print \$1}')\"
  else
    SHA=\"\"
  fi
  echo \"actual_sha=\$SHA\"
fi
if [ -f \"\$META\" ]; then
  EXPECTED=\"\$(grep -E '^  \"sha256\":' \"\$META\" | head -n1 | sed -e 's/.*\"sha256\":[[:space:]]*\"//' -e 's/\".*//')\"
  LABEL=\"\$(grep -E '^  \"label\":' \"\$META\" | head -n1 | sed -e 's/.*\"label\":[[:space:]]*\"//' -e 's/\".*//')\"
  CREATED=\"\$(grep -E '^  \"created\":' \"\$META\" | head -n1 | sed -e 's/.*\"created\":[[:space:]]*\"//' -e 's/\".*//')\"
  echo \"expected_sha=\$EXPECTED\"
  echo \"label=\$LABEL\"
  echo \"created=\$CREATED\"
fi
" 2>/dev/null || true)"

missing_tar="$(printf '%s\n' "$probe_out" | awk -F= '$1=="missing_tar"{print $2; exit}')"
missing_meta="$(printf '%s\n' "$probe_out" | awk -F= '$1=="missing_meta"{print $2; exit}')"
actual_sha="$(printf '%s\n' "$probe_out" | awk -F= '$1=="actual_sha"{sub(/^[^=]+=/,""); print; exit}')"
expected_sha="$(printf '%s\n' "$probe_out" | awk -F= '$1=="expected_sha"{sub(/^[^=]+=/,""); print; exit}')"
snap_label="$(printf '%s\n' "$probe_out" | awk -F= '$1=="label"{sub(/^[^=]+=/,""); print; exit}')"
snap_created="$(printf '%s\n' "$probe_out" | awk -F= '$1=="created"{sub(/^[^=]+=/,""); print; exit}')"

if [ "${missing_tar:-0}" = "1" ] || [ "${missing_meta:-0}" = "1" ]; then
  cat >&2 <<EOF
restore: снимок '$snapshot' не найден на роутере.
  tar:  $TAR_PATH $( [ "${missing_tar:-0}" = "1" ] && echo "(нет)" || echo "(есть)" )
  meta: $META_PATH $( [ "${missing_meta:-0}" = "1" ] && echo "(нет)" || echo "(есть)" )

Список доступных снимков:
  bin/snapshot-list.sh --router $ROUTER_ALIAS
EOF
  exit 13
fi

if [ -n "$expected_sha" ] && [ -n "$actual_sha" ] && [ "$expected_sha" != "$actual_sha" ]; then
  cat >&2 <<EOF
restore: !!! WARNING !!! sha256 НЕ СОВПАДАЕТ для $TAR_PATH:
  expected (meta): $expected_sha
  actual (file):   $actual_sha

Файл мог быть подменён или повреждён. Это серьёзный сигнал.
EOF
  if [ "$force" != "1" ]; then
    echo "restore: отказываюсь продолжать без --force" >&2
    exit 13
  fi
  echo "restore: --force указан, продолжаю несмотря на mismatch" >&2
fi

# --- Step 2: safety pre-restore snapshot ---------------------------------------
safety_snapshot_id=""
if [ "$no_pre_backup" = "1" ]; then
  echo "restore: WARN — --no-pre-backup, safety snapshot не создаётся" >&2
else
  if ! safety_snapshot_id="$("$OPENWRT_SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
                              --label "safety before restore $snapshot" --quiet 2>/dev/null)"; then
    echo "restore: backup-now (safety) упал — отказываюсь продолжать" >&2
    exit 2
  fi
  if [ -z "$safety_snapshot_id" ]; then
    echo "restore: safety snapshot id пуст — отказываюсь продолжать" >&2
    exit 2
  fi
fi

cat >&2 <<EOF

restore: применяю '$snapshot' к роутеру '$ROUTER_ALIAS'.
  label:           ${snap_label:-(none)}
  created:         ${snap_created:-?}
  safety snapshot: ${safety_snapshot_id:-(skipped)}

EOF

# --- Helper: roll back to safety snapshot --------------------------------------
# Used by BOTH the sing-box-check-fail branch and the reachability-fail branch.
# Returns 0 if rollback applied cleanly, non-zero otherwise.
# Caller is responsible for the exit code (20 on success, 30 on failure).
rollback_to_safety() {
  local reason="$1"
  if [ -z "$safety_snapshot_id" ]; then
    cat >&2 <<EOF
restore: $reason; safety snapshot не создавался (--no-pre-backup), откатывать некуда.
Роутер сейчас может иметь битый config.json. РУЧНОЕ ВМЕШАТЕЛЬСТВО:
  bin/raw-ssh.sh --router $ROUTER_ALIAS --reason "fix broken config after restore"
EOF
    return 1
  fi
  echo "restore: $reason — пытаюсь откатиться к safety snapshot '$safety_snapshot_id' …" >&2
  # Note: this ssh_run may hang if SSH is currently dead; we use a shortish
  # ConnectTimeout via the lib-default. If it fails, we return non-zero and
  # the caller exits 30 with manual instructions.
  if ! ssh_run "tar -xzf '$SNAP_DIR_REMOTE/${safety_snapshot_id}.tar.gz' -C / 2>/dev/null" >/dev/null 2>&1; then
    return 1
  fi
  ssh_run "
set +e
[ -x /etc/init.d/sing-box-tproxy ] && (/etc/init.d/sing-box-tproxy reload >/dev/null 2>&1 || /etc/init.d/sing-box-tproxy restart >/dev/null 2>&1)
[ -x /etc/init.d/dnsmasq ]         && /etc/init.d/dnsmasq reload >/dev/null 2>&1
command -v fw4 >/dev/null 2>&1     && fw4 reload >/dev/null 2>&1
true
" >/dev/null 2>&1 || true
  return 0
}

# --- Step 3: tar -xzf -C / -----------------------------------------------------
# Note: tarball was made with absolute paths (-P), so -C / overwrites in place.
# --keep-old-files=no would FAIL on conflicts; we want overwrite, hence default
# (busybox tar does not support --keep-old-files=no semantics consistently).
if ! ssh_run "tar -xzf '$TAR_PATH' -C / 2>/dev/null" >/dev/null 2>&1; then
  echo "restore: tar -xzf не удался — состояние НЕ изменено (пытаюсь)" >&2
  exit 2
fi

# --- Step 4: validate restored config ------------------------------------------
# Skip the sing-box check if the binary isn't installed on the router — otherwise
# we'd interpret "binary missing" as "config broken" and trigger a needless
# auto-rollback. If sing-box isn't installed yet, the restore did the file-level
# job; the user can install sing-box separately.
restored_ok=1
if ssh_run "command -v sing-box >/dev/null 2>&1" >/dev/null 2>&1; then
  if ssh_run "[ -f /etc/sing-box/config.json ]" >/dev/null 2>&1; then
    if ! ssh_run "sing-box check -c /etc/sing-box/config.json" >/dev/null 2>&1; then
      restored_ok=0
    fi
  fi
else
  echo "restore: sing-box не установлен на роутере — пропускаю validate restored config (file-level restore OK)" >&2
fi

if [ "$restored_ok" = "0" ]; then
  cat >&2 <<EOF
restore: !!! PROBLEM !!! восстановленный config.json НЕ проходит sing-box check.
Это означает, что снимок '$snapshot' сам по себе плохой.
EOF
  if rollback_to_safety "sing-box check failed"; then
    cat >&2 <<EOF
restore: откатились на safety snapshot '$safety_snapshot_id'.
Никакой restore НЕ применён, состояние = до операции.
EOF
    exit 20
  fi
  cat >&2 <<EOF
restore: !!! CATASTROPHIC !!! не смог применить safety snapshot '${safety_snapshot_id:-(none)}'.
Роутер в неизвестном состоянии. РУЧНОЕ ВМЕШАТЕЛЬСТВО:
  ssh $(_ssh_target)
  tar -xzf $SNAP_DIR_REMOTE/${safety_snapshot_id}.tar.gz -C /
  /etc/init.d/sing-box-tproxy restart
EOF
  exit 30
fi

# --- Step 5: reload services ---------------------------------------------------
# Best-effort reloads. We don't fail if zapret2 doesn't exist (optional).
ssh_run "
set +e
[ -x /etc/init.d/sing-box-tproxy ] && (/etc/init.d/sing-box-tproxy reload >/dev/null 2>&1 || /etc/init.d/sing-box-tproxy restart >/dev/null 2>&1)
[ -x /etc/init.d/zapret2 ]         && /etc/init.d/zapret2 restart >/dev/null 2>&1
[ -x /etc/init.d/dnsmasq ]         && /etc/init.d/dnsmasq reload >/dev/null 2>&1
command -v fw4 >/dev/null 2>&1     && fw4 reload >/dev/null 2>&1
true
" >/dev/null 2>&1 || true

# --- Step 6: reachability watch (30s) ------------------------------------------
reachable=0
end=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$end" ]; do
  if ssh_check_alive 3; then
    reachable=1
    break
  fi
  sleep 2
done

if [ "$reachable" != "1" ]; then
  cat >&2 <<EOF
restore: !!! PROBLEM !!! SSH не вернулся в течение 30s после restore.
Это означает, что снимок '$snapshot' оставил роутер неконтактным.
EOF
  # The runbook (05-restore.md) promises auto-rollback on reachability fail.
  # Try the same safety-snapshot rollback we use for sing-box-check failure.
  # ssh_run inside rollback_to_safety will retry-connect; if the router is
  # totally dead it'll fail and we fall through to exit 30.
  if rollback_to_safety "post-restore reachability lost"; then
    # Did the rollback restore SSH? Re-probe briefly.
    rb_reach=0
    rb_end=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$rb_end" ]; do
      if ssh_check_alive 3; then rb_reach=1; break; fi
      sleep 2
    done
    if [ "$rb_reach" = "1" ]; then
      cat >&2 <<EOF
restore: откатились на safety snapshot '$safety_snapshot_id' и SSH вернулся.
Никакой restore НЕ применён, состояние = до операции.
EOF
      exit 20
    fi
    cat >&2 <<EOF
restore: !!! CATASTROPHIC !!! safety snapshot '$safety_snapshot_id' распакован,
но SSH всё ещё не отвечает. Возможно, проблема в сети, не в конфиге.
  bin/restore.sh --router $ROUTER_ALIAS --snapshot $safety_snapshot_id
  (попробуй после возврата связи; если нет — физический reset / failsafe).
EOF
    exit 30
  fi
  cat >&2 <<EOF
restore: !!! CATASTROPHIC !!! не смог применить safety snapshot '${safety_snapshot_id:-(none)}'
(SSH мёртв либо snapshot отсутствует).
Если роутер вернётся — откати вручную:
  bin/restore.sh --router $ROUTER_ALIAS --snapshot ${safety_snapshot_id:-<safety_id>}
Если нет — физический reset / failsafe.
EOF
  exit 30
fi

# --- Step 7: refresh state.md via doctor ---------------------------------------
if [ -x "$OPENWRT_SKILL_HOME/bin/doctor.sh" ]; then
  "$OPENWRT_SKILL_HOME/bin/doctor.sh" --router "$ROUTER_ALIAS" --quiet >/dev/null 2>&1 || \
    echo "restore: doctor.sh упал после restore (не критично)" >&2
fi

# --- Step 8: journal -----------------------------------------------------------
# Use the snap label as reason if there's no other. Label is already secret-free
# (backup-now validates).
reason_for_journal="${snap_label:-(no label)}"
journal_args=(
  "from_snapshot=$snapshot"
  "safety_snapshot=${safety_snapshot_id:-none}"
  "reason=$reason_for_journal"
  "memory_stale_warning=true"
)
memory_journal_append "$ROUTER_ALIAS" "restore" "${journal_args[@]}" || \
  echo "restore: WARN — журнал не записан" >&2

# --- Step 9: summary -----------------------------------------------------------
cat <<EOF

restore: успех.
  router:          $ROUTER_ALIAS
  restored:        $snapshot (label: ${snap_label:-none}, created: ${snap_created:-?})
  safety snapshot: ${safety_snapshot_id:-(skipped — --no-pre-backup)}

ВНИМАНИЕ: memory/$ROUTER_ALIAS/domains.md, vpns.md, proxies.md МОГУТ БЫТЬ УСТАРЕВШИМИ
(restore вернул on-router state на момент снимка, но memory НЕ пересобрана).

Следующие шаги:
  bin/health.sh --router $ROUTER_ALIAS         # проверить runtime (sing-box, DNS, IP exit)
  bin/doctor.sh --router $ROUTER_ALIAS         # уже запущено, state.md обновлён

Если что-то пошло не так — откати restore:
  bin/restore.sh --router $ROUTER_ALIAS --snapshot ${safety_snapshot_id:-<safety_id>}
EOF

exit 0
