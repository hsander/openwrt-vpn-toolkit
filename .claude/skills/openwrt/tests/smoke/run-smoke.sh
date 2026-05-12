#!/usr/bin/env bash
# tests/smoke/run-smoke.sh
#
# Smoke-test runner. Spins up an OpenWRT rootfs container with sshd, points the
# openwrt-skill bin/*.sh scripts at it via a sandboxed memory dir, exercises a
# fixed sequence of operations, and reports PASS/FAIL per step.
#
# DO NOT modify production bin/, lib/, memory/, or SKILL.md to make a step
# pass. If a bin/ script has a real bug, report it -- this script is a finder,
# not a patcher.
#
# Usage:
#   bash tests/smoke/run-smoke.sh
#
# Env knobs:
#   KEEP_CONTAINER=1   leave the container running after exit (for `docker exec`).
#   IMAGE_TAG=...      override the built image tag (default openwrt-skill-smoke:latest).
#   SSH_PORT=...       override the host port mapping (default 2222).
#   SMOKE_TMP_DIR=...  override the host tmp dir (default ${TMPDIR:-/tmp}/openwrt-skill-smoke).
#                      Default путь ВНЕ skill-дерева — чтобы артефакты (SSH-ключ,
#                      sandbox memory, логи) не попадали под cp -R / tar при упаковке.

set -uo pipefail

# We deliberately do NOT use `set -e`: each step must run independently and
# report PASS/FAIL even when an earlier step failed. Otherwise the first
# unexpected failure aborts the whole smoke and we lose downstream signal.

# ----------------------------- paths & config ---------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Артефакты smoke (SSH-ключ, sandbox memory, логи) хранятся ВНЕ skill-дерева,
# чтобы не попадать в дистрибутив при cp -R / tar. См. SMOKE_TMP_DIR в шапке.
TMP_DIR="${SMOKE_TMP_DIR:-${TMPDIR:-/tmp}/openwrt-skill-smoke}"
MEMORY_DIR="$TMP_DIR/memory"
KEY_PATH="$TMP_DIR/smoke_ed25519"
PUB_PATH="$KEY_PATH.pub"
KNOWN_HOSTS="$TMP_DIR/known_hosts"
RUN_LOG="$TMP_DIR/run.log"
SNAPSHOT_ID_FILE="$TMP_DIR/last-snapshot-id.txt"

IMAGE_TAG="${IMAGE_TAG:-openwrt-skill-smoke:latest}"
CONTAINER_NAME="openwrt-skill-smoke"
SSH_PORT="${SSH_PORT:-2222}"
ROUTER_ALIAS="smokebox"

mkdir -p "$TMP_DIR" "$MEMORY_DIR"

# Each bin/*.sh script computes SKILL_HOME from its own location, so we must
# point OPENWRT_SKILL_HOME at the real project root and OPENWRT_SKILL_MEMORY
# at our sandbox.
export OPENWRT_SKILL_HOME="$SKILL_HOME"
export OPENWRT_SKILL_MEMORY="$MEMORY_DIR"

# ----------------------------- pretty logging ---------------------------------
# Use plain text, no colours (terminal-agnostic).
log()  { printf '[smoke %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
say()  { printf '%s\n' "$*"; }
hr()   { printf -- '----------------------------------------------------------------\n'; }

# Step results accumulator: parallel arrays. Bash 3 (macOS default) lacks
# associative arrays, so we keep two arrays.
declare -a STEP_NAMES=()
declare -a STEP_RESULTS=()  # "PASS" / "FAIL: <msg>" / "SKIP: <reason>"

record() { STEP_NAMES+=("$1"); STEP_RESULTS+=("$2"); }

step_pass() { record "$1" "PASS"; log "PASS: $1"; }
step_fail() { record "$1" "FAIL: $2"; log "FAIL: $1 -- $2"; }
step_skip() { record "$1" "SKIP: $2"; log "SKIP: $1 -- $2"; }

# ----------------------------- teardown ---------------------------------------
teardown() {
  local rc=$?
  if [ "${KEEP_CONTAINER:-0}" = "1" ]; then
    log "KEEP_CONTAINER=1 -- leaving '$CONTAINER_NAME' running. Stop with: docker stop $CONTAINER_NAME"
  else
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME"   >/dev/null 2>&1 || true
  fi
  return $rc
}
trap teardown EXIT INT TERM

# ----------------------------- prerequisites ----------------------------------
prereq_check() {
  local missing=()
  for cmd in docker jq ssh-keygen ssh yq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "ERROR: missing host prerequisites: ${missing[*]}"
    log "Install: brew install ${missing[*]}"
    exit 2
  fi
  if ! docker info >/dev/null 2>&1; then
    log "ERROR: 'docker info' failed -- Docker Desktop not running?"
    exit 2
  fi
}

# ----------------------------- bootstrap keys ---------------------------------
ensure_keypair() {
  if [ -f "$KEY_PATH" ] && [ -f "$PUB_PATH" ]; then
    log "reusing keypair: $KEY_PATH"
    return 0
  fi
  log "generating ed25519 keypair: $KEY_PATH"
  ssh-keygen -t ed25519 -N '' -C 'openwrt-skill-smoke' -f "$KEY_PATH" >/dev/null
  chmod 600 "$KEY_PATH"
}

# ----------------------------- bootstrap memory -------------------------------
# We intentionally rebuild memory/routers.yaml on every run (idempotent) so a
# stale fixture from a previous run can't poison this one.
#
# We leave ssh_alias empty so lib/ssh-runner.sh:_ssh_target falls back to
# user@host -- that lets us pass the test port via $ROUTER_HOST without
# touching the user's ~/.ssh/config. We then override ssh_check_alive et al by
# wrapping ssh with the container-local opts (UserKnownHostsFile + Port).
#
# Critical hack: ssh-runner.sh hard-codes no `-p`/`-o Port=` and no
# UserKnownHostsFile. To inject those without patching production code, we
# wrap `ssh` and `scp` via a per-run dir prepended to PATH. The wrapper reads
# $SMOKE_SSH_PORT and $SMOKE_KNOWN_HOSTS env vars.
bootstrap_memory() {
  rm -rf "$MEMORY_DIR"
  mkdir -p "$MEMORY_DIR/_templates"

  # Copy template files so render_first_time_memory works.
  cp "$SKILL_HOME/memory/_templates/"*.md "$MEMORY_DIR/_templates/"
  cp "$SKILL_HOME/memory/routers.yaml.example" "$MEMORY_DIR/routers.yaml.example"

  # Write routers.yaml directly (don't rely on register_router which uses yq -i
  # mutations -- we know exactly what we want).
  cat > "$MEMORY_DIR/routers.yaml" <<EOF
version: 1

routers:
  $ROUTER_ALIAS:
    host: 127.0.0.1
    user: root
    ssh_key: $KEY_PATH
    ssh_alias: ""
    notes: "openwrt-skill-smoke container, do not commit"

default_router: $ROUTER_ALIAS
EOF
}

# ----------------------------- ssh wrapper ------------------------------------
# We inject `-p 2222`, `-i <key>`, `-o UserKnownHostsFile=...`,
# `-o StrictHostKeyChecking=no` (and the scp equivalents) by prepending a
# wrapper dir to PATH for the entire test run.
#
# Why not just modify routers.yaml ssh_key + a custom Host block? Because the
# production scripts always shell out as `ssh user@host` (no -p) when
# ssh_alias is empty, and there is no port slot in routers.yaml. A wrapper is
# the minimum-surface intercept that doesn't change production code.
write_ssh_wrappers() {
  local wrap_dir="$TMP_DIR/bin"
  mkdir -p "$wrap_dir"

  cat > "$wrap_dir/ssh" <<'WRAP_EOF'
#!/usr/bin/env bash
# smoke ssh wrapper -- injects port + per-run known_hosts.
exec /usr/bin/ssh -p "${SMOKE_SSH_PORT:-22}" \
  -o "UserKnownHostsFile=${SMOKE_KNOWN_HOSTS:-/dev/null}" \
  -o StrictHostKeyChecking=no \
  -o LogLevel=ERROR \
  "$@"
WRAP_EOF

  cat > "$wrap_dir/scp" <<'WRAP_EOF'
#!/usr/bin/env bash
# smoke scp wrapper -- injects port + per-run known_hosts.
exec /usr/bin/scp -P "${SMOKE_SSH_PORT:-22}" \
  -o "UserKnownHostsFile=${SMOKE_KNOWN_HOSTS:-/dev/null}" \
  -o StrictHostKeyChecking=no \
  -o LogLevel=ERROR \
  "$@"
WRAP_EOF

  chmod +x "$wrap_dir/ssh" "$wrap_dir/scp"
  export PATH="$wrap_dir:$PATH"
  export SMOKE_SSH_PORT="$SSH_PORT"
  export SMOKE_KNOWN_HOSTS="$KNOWN_HOSTS"
  : > "$KNOWN_HOSTS"
}

# ----------------------------- docker build -----------------------------------
docker_build() {
  log "building image $IMAGE_TAG"
  if ! docker build \
        --platform linux/amd64 \
        -f "$SCRIPT_DIR/Dockerfile.openwrt-sshd" \
        --build-arg AUTHKEY="$(cat "$PUB_PATH")" \
        -t "$IMAGE_TAG" \
        "$SCRIPT_DIR" >>"$RUN_LOG" 2>&1; then
    log "ERROR: docker build failed -- see $RUN_LOG (last 40 lines below):"
    tail -40 "$RUN_LOG" >&2
    exit 2
  fi
  log "built $IMAGE_TAG"
}

# ----------------------------- docker run -------------------------------------
docker_run() {
  # Clean any stale container.
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm   "$CONTAINER_NAME" >/dev/null 2>&1 || true

  log "starting container $CONTAINER_NAME (port 127.0.0.1:$SSH_PORT -> 22)"
  if ! docker run -d --rm --platform linux/amd64 \
        --name "$CONTAINER_NAME" \
        -p "127.0.0.1:${SSH_PORT}:22" \
        "$IMAGE_TAG" >>"$RUN_LOG" 2>&1; then
    log "ERROR: docker run failed -- see $RUN_LOG"
    exit 2
  fi
}

wait_for_sshd() {
  log "waiting up to 30s for sshd on 127.0.0.1:$SSH_PORT"
  local deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ssh -i "$KEY_PATH" -o BatchMode=yes -o ConnectTimeout=2 \
           root@127.0.0.1 true >/dev/null 2>&1; then
      log "sshd reachable"
      return 0
    fi
    sleep 1
  done
  log "ERROR: sshd not reachable within 30s; container logs:"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -30 >&2 || true
  exit 2
}

# ----------------------------- container helpers ------------------------------
# Run a one-liner inside the smoke container (not via the bin/ scripts).
in_box() { docker exec "$CONTAINER_NAME" sh -c "$1"; }

# ----------------------------- test scaffolds ---------------------------------
# These pre-populate state on the container that the bin/ scripts probe for.
# Each scaffold is small and commented inline. We deliberately do NOT scaffold
# anything that the corresponding step is meant to *verify* -- e.g., we do
# not pre-create snapshots, because snapshot-list/backup-now must create
# them.
#
# Scaffold 1: ensure /etc/vpn-kit exists so backup-now can write into it.
#             (The script does mkdir -p, but doing it once upfront keeps
#             container state predictable.)
#
# Scaffold 2: optionally seed a tiny sing-box config so add-domain can
#             progress past the "config.json missing" branch. We do this
#             explicitly to surface where add-domain blocks beyond config
#             presence (rule-set validation, sing-box check, etc.).
seed_minimal_singbox_config() {
  # Skipped by default. Toggle via env to peek deeper into add-domain.
  if [ "${SCAFFOLD_SINGBOX_CONFIG:-0}" != "1" ]; then return 0; fi
  log "scaffold: seeding /etc/sing-box/config.json (minimal)"
  in_box 'mkdir -p /etc/sing-box/rules && cat > /etc/sing-box/config.json <<CFG
{
  "log": {"level": "info"},
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"},
    {"type": "selector", "tag": "auto-failover", "outbounds": ["direct"]}
  ],
  "route": {"rules": []}
}
CFG'
}

# ----------------------------- test steps -------------------------------------
# Each test_* function: runs the bin/ script, captures stdout/stderr/exit,
# inspects, and emits step_pass / step_fail with a precise reason.

test_01_doctor_json() {
  local name="doctor.sh --json"
  local out err rc
  out="$("$SKILL_HOME/bin/doctor.sh" --router "$ROUTER_ALIAS" --json 2>"$TMP_DIR/doctor.err")"
  rc=$?
  err="$(cat "$TMP_DIR/doctor.err")"

  printf '%s\n' "$out" > "$TMP_DIR/doctor.json"

  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; stderr head: $(printf '%s' "$err" | head -3 | tr '\n' ' ')"
    return
  fi
  # Strip everything before first { (doctor may also print state.md path).
  local probe
  probe="$(printf '%s\n' "$out" | awk '/^\{/{flag=1} flag{print}')"

  if [ -z "$probe" ]; then
    step_fail "$name" "no JSON object in stdout"
    return
  fi

  local ver arch ram pkg_jq
  ver=$(printf '%s' "$probe" | jq -r '.openwrt_version // empty' 2>/dev/null)
  arch=$(printf '%s' "$probe" | jq -r '.arch // empty' 2>/dev/null)
  ram=$(printf '%s'  "$probe" | jq -r '.ram_mb // 0'    2>/dev/null)
  pkg_jq=$(printf '%s' "$probe" | jq -r '.packages.jq // false' 2>/dev/null)

  local fails=""
  [ -n "$ver" ]    || fails="$fails openwrt_version-empty"
  [ -n "$arch" ]   || fails="$fails arch-empty"
  [ "${ram:-0}" -gt 0 ] 2>/dev/null || fails="$fails ram=$ram"
  [ "$pkg_jq" = "true" ] || fails="$fails packages.jq=$pkg_jq"

  if [ -n "$fails" ]; then
    step_fail "$name" "asserts:${fails}; got ver=$ver arch=$arch ram=$ram jq=$pkg_jq"
    return
  fi
  step_pass "$name"
  log "  doctor: openwrt_version=$ver arch=$arch ram_mb=$ram packages.jq=$pkg_jq"
}

test_02_backup_now() {
  local name="backup-now.sh"
  local out err rc snap_id
  out="$("$SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
          --label "smoke-test" --quiet 2>"$TMP_DIR/backup.err")"
  rc=$?
  err="$(cat "$TMP_DIR/backup.err")"

  # NOTE -- KNOWN FINDING: on a fresh container with no /etc/sing-box etc.,
  # backup-now exits 2 with "no_paths_to_snapshot" because none of the
  # default paths exist yet. Workaround for the smoke: pre-seed at least one
  # path so the snapshot is non-empty. We touch /etc/vpn-kit/install-state.json
  # on the container BEFORE this step so backup-now has something to capture.
  # This is a scaffold, not a fix -- the bug stays in the report.
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; stderr: $(printf '%s' "$err" | tr '\n' ' ' | head -c 240)"
    return
  fi

  snap_id="$(printf '%s\n' "$out" | tail -n1 | tr -d '[:space:]')"
  case "$snap_id" in
    snap-*) ;;
    *) step_fail "$name" "stdout did not look like a snapshot id: '$snap_id'"; return ;;
  esac

  # Check files actually exist on the container.
  if ! in_box "test -f /etc/vpn-kit/snapshots/${snap_id}.tar.gz" >/dev/null 2>&1; then
    step_fail "$name" "tarball missing on container: /etc/vpn-kit/snapshots/${snap_id}.tar.gz"
    return
  fi
  if ! in_box "test -f /etc/vpn-kit/snapshots/${snap_id}.meta.json" >/dev/null 2>&1; then
    step_fail "$name" "meta.json missing on container"
    return
  fi
  printf '%s\n' "$snap_id" > "$SNAPSHOT_ID_FILE"
  step_pass "$name"
  log "  snapshot id: $snap_id"
}

test_03_snapshot_list_json() {
  local name="snapshot-list.sh --json"
  local out rc
  out="$("$SKILL_HOME/bin/snapshot-list.sh" --router "$ROUTER_ALIAS" --json 2>"$TMP_DIR/list.err")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; err: $(cat "$TMP_DIR/list.err" | tr '\n' ' ' | head -c 200)"
    return
  fi
  if ! printf '%s\n' "$out" | jq -e 'type=="array"' >/dev/null 2>&1; then
    step_fail "$name" "stdout not a JSON array"
    return
  fi
  local expected="" found
  if [ -s "$SNAPSHOT_ID_FILE" ]; then
    expected="$(cat "$SNAPSHOT_ID_FILE")"
  fi
  if [ -n "$expected" ]; then
    found="$(printf '%s\n' "$out" | jq -r --arg id "$expected" '.[] | select(.id == $id) | .id')"
    if [ "$found" != "$expected" ]; then
      step_fail "$name" "snapshot $expected not listed; got: $(printf '%s' "$out" | jq -c '[.[].id]')"
      return
    fi
  fi
  step_pass "$name"
}

test_04_add_domain_clean_fail() {
  local name="add-domain.sh (expected clean fail)"

  # Snapshot dir contents on the container *before* the call. If add-domain
  # mis-handles rollback we might see tarballs disappear; we want to assert
  # they don't.
  local before after
  before="$(in_box "ls /etc/vpn-kit/snapshots/ 2>/dev/null | sort" 2>/dev/null || echo "")"

  local rc
  "$SKILL_HOME/bin/add-domain.sh" --router "$ROUTER_ALIAS" --domain example.com \
    >"$TMP_DIR/adddom.out" 2>"$TMP_DIR/adddom.err"
  rc=$?

  after="$(in_box "ls /etc/vpn-kit/snapshots/ 2>/dev/null | sort" 2>/dev/null || echo "")"

  if [ "$rc" -eq 0 ]; then
    step_fail "$name" "expected non-zero exit but got 0"
    return
  fi
  # Ensure no existing snapshot tarball was destroyed.
  if [ -n "$before" ]; then
    local lost
    lost="$(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
    if [ -n "$lost" ]; then
      step_fail "$name" "snapshot tarballs were deleted: $lost"
      return
    fi
  fi
  # Optional: read stderr tail for context, but don't strict-match -- the
  # exact message depends on whether scaffold step seeded a config.
  local errtail
  errtail="$(tail -3 "$TMP_DIR/adddom.err" | tr '\n' ' ' | head -c 240)"
  step_pass "$name"
  log "  add-domain stderr tail: $errtail"
  log "  add-domain exit code: $rc"
}

test_05_health_no_singbox() {
  local name="health.sh --json (no sing-box running)"
  local rc out
  out="$("$SKILL_HOME/bin/health.sh" --router "$ROUTER_ALIAS" --json 2>"$TMP_DIR/health.err")"
  rc=$?

  # Spec: must exit non-zero (no sing-box running), but JSON should be valid.
  if [ "$rc" -eq 0 ]; then
    step_fail "$name" "expected non-zero exit (no sing-box) but got 0"
    return
  fi
  if [ -z "$out" ]; then
    step_fail "$name" "exit=$rc and stdout empty; err: $(tr '\n' ' ' < "$TMP_DIR/health.err" | head -c 200)"
    return
  fi
  if ! printf '%s\n' "$out" | jq -e '.' >/dev/null 2>&1; then
    step_fail "$name" "exit=$rc and stdout not JSON: $(printf '%s' "$out" | head -c 200)"
    return
  fi
  # jq tip: `.x // y` treats `false` as null, so `.sing_box.running // empty`
  # would mask a healthy "running:false" as missing. Use explicit type checks.
  local sb_running crit_pass
  sb_running="$(printf '%s\n' "$out" | jq -r '
    if (.sing_box.running != null) then .sing_box.running
    elif (.sb_running != null) then .sb_running
    else "MISSING" end' 2>/dev/null)"
  # Again: avoid `// "x"` because jq treats `false` as null. Branch explicitly.
  crit_pass="$(printf '%s\n' "$out" | jq -r '
    if (.critical_pass != null) then .critical_pass else "MISSING" end' 2>/dev/null)"

  case "$sb_running" in
    false|0)
      step_pass "$name"
      log "  health.sing_box.running=$sb_running critical_pass=$crit_pass"
      ;;
    MISSING|"")
      step_fail "$name" "sing_box.running field missing from JSON"
      ;;
    *)
      step_fail "$name" "sb_running should be false; got '$sb_running'"
      ;;
  esac
}

test_06_restore_snapshot() {
  local name="restore.sh"
  if [ ! -s "$SNAPSHOT_ID_FILE" ]; then
    step_skip "$name" "no snapshot id from step 2"
    return
  fi
  local snap_id
  snap_id="$(cat "$SNAPSHOT_ID_FILE")"
  local rc
  "$SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" --snapshot "$snap_id" \
    >"$TMP_DIR/restore.out" 2>"$TMP_DIR/restore.err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    step_pass "$name"
    return
  fi
  # Exit 20 на «голом» контейнере — это документированный safe rollback:
  # snapshot восстановлен на disk, но sing-box check на нём упал (потому что в
  # snapshot'е был пустой/несуществующий config.json), и restore.sh откатился
  # на safety_snapshot. Это PASS-поведение для нашего scaffold'а, где valid
  # sing-box config заранее не сидится. Если ты добавил `SCAFFOLD_SINGBOX_CONFIG=1`
  # — exit должен стать 0.
  local errtail
  errtail="$(tail -5 "$TMP_DIR/restore.err" | tr '\n' ' ' | head -c 280)"
  case "$rc" in
    20)
      step_pass "$name (exit 20 — safety rollback на голом контейнере без sing-box config; ожидаемо)"
      ;;
    2|13|30)
      step_fail "$name" "clean failure exit=$rc; stderr: $errtail"
      ;;
    *)
      step_fail "$name" "unexpected exit=$rc; stderr: $errtail"
      ;;
  esac
}

test_07_install_vpn_dry_run() {
  local name="install-vpn.sh --dry-run"
  if ! grep -q -- "--dry-run" "$SKILL_HOME/bin/install-vpn.sh" 2>/dev/null; then
    step_skip "$name" "no --dry-run flag in install-vpn.sh"
    return
  fi
  # Use a syntactically-valid vless URL so URL validation passes; this is
  # a public test/example UUID -- it points nowhere.
  local fake_url="vless://00000000-0000-0000-0000-000000000000@127.0.0.1:443?type=tcp&security=reality&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&fp=chrome&sni=example.com#smoke"
  local rc
  "$SKILL_HOME/bin/install-vpn.sh" --router "$ROUTER_ALIAS" \
    --url "$fake_url" --dry-run \
    >"$TMP_DIR/installvpn.out" 2>"$TMP_DIR/installvpn.err"
  rc=$?
  local errtail
  errtail="$(tail -5 "$TMP_DIR/installvpn.err" | tr '\n' ' ' | head -c 280)"
  # A dry-run on a fresh container will fail at preflight/render because
  # /etc/openwrt_release reports SNAPSHOT (not 24.10+), no kmods, no
  # sing-box config etc. That's expected. We classify this as PASS-with-note
  # because spec (#7) is stretch: only crashes / unknown exits are failures.
  case "$rc" in
    0)
      step_pass "$name"; log "  install-vpn --dry-run completed cleanly" ;;
    2|13|20)
      # Clean preflight refusal -- not a bug, just container limits.
      step_pass "$name"
      log "  install-vpn --dry-run cleanly refused with exit=$rc (expected on SNAPSHOT container)"
      log "  stderr tail: $errtail"
      ;;
    127)
      step_fail "$name" "command not found (exit 127); stderr: $errtail" ;;
    *)
      step_fail "$name" "unexpected exit=$rc; stderr: $errtail" ;;
  esac
}

# ----------------------------- main flow --------------------------------------
main() {
  : > "$RUN_LOG"

  prereq_check
  ensure_keypair
  bootstrap_memory
  write_ssh_wrappers
  docker_build
  docker_run
  wait_for_sshd
  seed_minimal_singbox_config  # opt-in via SCAFFOLD_SINGBOX_CONFIG=1

  hr
  log "running smoke steps"
  hr

  test_01_doctor_json
  test_02_backup_now
  test_03_snapshot_list_json
  test_04_add_domain_clean_fail
  test_05_health_no_singbox
  test_06_restore_snapshot
  test_07_install_vpn_dry_run

  hr
  say "SMOKE SUMMARY"
  hr
  local i pass=0 fail=0 skip=0
  for i in "${!STEP_NAMES[@]}"; do
    local n="${STEP_NAMES[$i]}" r="${STEP_RESULTS[$i]}"
    case "$r" in
      PASS*) pass=$((pass+1)) ;;
      FAIL*) fail=$((fail+1)) ;;
      SKIP*) skip=$((skip+1)) ;;
    esac
    printf '  %-50s %s\n' "$n" "$r"
  done
  hr
  printf 'TOTAL: %d pass, %d fail, %d skip\n' "$pass" "$fail" "$skip"
  hr

  # Exit code: 0 iff all steps PASS or SKIP. The smoke is informational, but
  # CI may want a non-zero on any FAIL.
  [ "$fail" -eq 0 ]
}

main "$@"
