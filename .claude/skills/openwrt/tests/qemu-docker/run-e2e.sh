#!/usr/bin/env bash
# tests/qemu-docker/run-e2e.sh
#
# Orchestrator -- runs on the macOS host.
#
# 1. Build the openwrt-skill-qemu image (linux/amd64, contains qemu + the
#    pre-downloaded OpenWRT combined image).
# 2. docker run a container with /data mounted from tests/qemu-docker/.tmp/
#    so the ssh key + decompressed image persist across runs.
# 3. Wait for sshd on the host-mapped port.
# 4. PATH-shadow `ssh`/`scp` with wrappers that auto-inject -p, -i, etc., so
#    the production bin/*.sh scripts don't need to change.
# 5. Run the full test sequence against the VM (doctor, backup, install-vpn,
#    real-VPN traffic, add/remove-domain, restore).
# 6. Teardown: poweroff the VM via SSH, then docker stop.
#
# Usage:
#   bash tests/qemu-docker/run-e2e.sh
#   KEEP_VM=1 bash tests/qemu-docker/run-e2e.sh   # leave container running
#   IMAGE_ONLY=1 bash tests/qemu-docker/run-e2e.sh # just docker build
#
# Secret handling:
#   The VLESS URL lives at ~/.openwrt-skill/secrets/qemu-test.url (chmod 600).
#   We read it ONLY when about to pass --url, never echo / never log / never
#   persist beyond the install-vpn invocation.

# We intentionally do NOT `set -e`: every step must run independently so the
# summary table at the end reflects what actually happened.
set -uo pipefail

# ----------------------------- paths & config --------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Артефакты qemu-docker (логи, sandbox memory, бинды) — ВНЕ skill-дерева, чтобы
# не попасть в дистрибутив при cp -R / tar. Переопредели через QEMU_TMP_DIR.
TMP_DIR="${QEMU_TMP_DIR:-${TMPDIR:-/tmp}/openwrt-skill-qemu-docker}"
MEMORY_DIR="$TMP_DIR/memory"
WRAP_DIR="$TMP_DIR/bin"
KNOWN_HOSTS="$TMP_DIR/known_hosts"
RUN_LOG="$TMP_DIR/run.log"
SNAPSHOT_ID_FILE="$TMP_DIR/last-snapshot-id.txt"

IMAGE_TAG="${IMAGE_TAG:-openwrt-skill-qemu:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-openwrt-skill-qemu}"
ROUTER_ALIAS="qemubox"
SSH_PORT="${SSH_PORT:-2299}"
PROXY_HOST_PORT="${PROXY_HOST_PORT:-14000}"
PROXY_GUEST_PORT="${PROXY_GUEST_PORT:-4000}"
URL_FILE="${URL_FILE:-$HOME/.openwrt-skill/secrets/qemu-test.url}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"   # 10 minutes; TCG x86 на ARM-Mac через Rosetta — медленно

mkdir -p "$TMP_DIR" "$MEMORY_DIR" "$WRAP_DIR"

# Bin scripts derive SKILL_HOME from their own location; we still set these so
# memory lookups land in our sandbox dir.
export OPENWRT_SKILL_HOME="$SKILL_HOME"
export OPENWRT_SKILL_MEMORY="$MEMORY_DIR"

# ----------------------------- pretty logging --------------------------------
log()  { printf '[run-e2e %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
say()  { printf '%s\n' "$*"; }
hr()   { printf -- '----------------------------------------------------------------\n'; }

declare -a STEP_NAMES=()
declare -a STEP_RESULTS=()

record()    { STEP_NAMES+=("$1"); STEP_RESULTS+=("$2"); }
step_pass() { record "$1" "PASS";          log "PASS: $1"; }
step_fail() { record "$1" "FAIL: $2";      log "FAIL: $1 -- $2"; }
step_skip() { record "$1" "SKIP: $2";      log "SKIP: $1 -- $2"; }

# Result accumulators used by main() summary.
HOST_IP=""
VPN_IP=""
VPN_COUNTRY=""
PRE_INSTALL_SNAP_ID=""

# ----------------------------- teardown --------------------------------------
teardown() {
  local rc=$?
  if [ "${KEEP_VM:-0}" = "1" ]; then
    log "KEEP_VM=1 -- leaving container '$CONTAINER_NAME' running."
    log "  SSH:    ssh -i $TMP_DIR/id_ed25519 -p $SSH_PORT root@127.0.0.1"
    log "  Shell:  docker exec -it $CONTAINER_NAME bash"
    log "  Stop:   docker stop $CONTAINER_NAME"
    return $rc
  fi
  # Best-effort graceful shutdown so the ext4 image isn't dirty next run.
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    "$WRAP_DIR/ssh" root@127.0.0.1 '/sbin/poweroff -f' >/dev/null 2>&1 || true
    # Give the VM up to 10s to power down; then stop the container.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME" || break
      sleep 1
    done
    docker stop -t 5 "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  return $rc
}
trap teardown EXIT INT TERM

# ----------------------------- prereqs ---------------------------------------
prereq_check() {
  local missing=()
  for cmd in docker jq ssh ssh-keygen curl yq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "ERROR: missing host commands: ${missing[*]}"
    log "  brew install ${missing[*]}"
    exit 2
  fi
  if ! docker info >/dev/null 2>&1; then
    log "ERROR: 'docker info' failed -- Docker Desktop running?"
    exit 2
  fi
  if [ ! -f "$URL_FILE" ]; then
    log "ERROR: VLESS URL secret missing: $URL_FILE (expected chmod 600 single-line vless://...)"
    exit 2
  fi
  # Don't read it now; only when install-vpn needs it.
}

# ----------------------------- docker build ----------------------------------
docker_build() {
  log "building $IMAGE_TAG (first build ~3-5 min for apt + OpenWRT download)"
  if ! docker build \
        --platform linux/amd64 \
        -t "$IMAGE_TAG" \
        -f "$SCRIPT_DIR/Dockerfile" \
        "$SCRIPT_DIR" >>"$RUN_LOG" 2>&1; then
    log "ERROR: docker build failed; tail of $RUN_LOG:"
    tail -50 "$RUN_LOG" >&2
    exit 2
  fi
  log "built $IMAGE_TAG"
}

# ----------------------------- docker run ------------------------------------
docker_run() {
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm   "$CONTAINER_NAME" >/dev/null 2>&1 || true

  # --cap-add SYS_ADMIN + --device /dev/loop-control + bind /dev for loop
  # devices is the minimum surface needed for losetup -fP to work inside the
  # container. We use --privileged here because Docker Desktop on macOS doesn't
  # expose /dev/loop-control in a way that --device handles cleanly across
  # versions; --privileged is the documented "just works" path for QEMU+ext4.
  # It's a test-only container, host kernel is locked-down VM in Linux Kit.
  log "starting $CONTAINER_NAME (host 127.0.0.1:$SSH_PORT->22, 127.0.0.1:$PROXY_HOST_PORT->$PROXY_GUEST_PORT)"
  if ! docker run -d --rm \
        --platform linux/amd64 \
        --name "$CONTAINER_NAME" \
        --privileged \
        -p "127.0.0.1:${SSH_PORT}:22" \
        -p "127.0.0.1:${PROXY_HOST_PORT}:${PROXY_GUEST_PORT}" \
        -v "$TMP_DIR:/data" \
        "$IMAGE_TAG" >>"$RUN_LOG" 2>&1; then
    log "ERROR: docker run failed; tail of $RUN_LOG:"
    tail -30 "$RUN_LOG" >&2
    exit 2
  fi
}

# ----------------------------- wait for VM ssh -------------------------------
wait_for_sshd() {
  log "waiting up to ${BOOT_TIMEOUT}s for sshd on 127.0.0.1:$SSH_PORT (TCG boot is slow)"
  local deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  # Use the wrapper ssh -- it already knows port/key/known_hosts.
  local consecutive=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      log "ERROR: container '$CONTAINER_NAME' exited during boot. Last 60 log lines:"
      docker logs "$CONTAINER_NAME" 2>&1 | tail -60 >&2 || true
      exit 2
    fi
    if "$WRAP_DIR/ssh" -o BatchMode=yes -o ConnectTimeout=3 \
          root@127.0.0.1 'echo ok' >/dev/null 2>&1; then
      consecutive=$(( consecutive + 1 ))
      if [ "$consecutive" -ge 2 ]; then
        log "sshd up + stable"
        return 0
      fi
    else
      consecutive=0
    fi
    sleep 3
  done
  log "ERROR: sshd not reachable within ${BOOT_TIMEOUT}s. Last 60 container log lines:"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -60 >&2 || true
  exit 2
}

# ----------------------------- ssh wrappers ----------------------------------
# bin/*.sh -> lib/ssh-runner.sh issues `ssh user@host` with no -p / no -i.
# We PATH-shadow ssh/scp with wrappers that auto-add what production omits.
# Same pattern as tests/smoke/run-smoke.sh.
#
# Why we resolve the key path *here*: the keypair lives in the container's
# /data volume, which is our tests/qemu-docker/.tmp/. On first run the
# container generates it; on subsequent runs we reuse it.
SSH_KEY=""
write_ssh_wrappers() {
  # The container's entrypoint generated /data/id_ed25519 -- on this host that
  # path is $TMP_DIR/id_ed25519. We wait briefly for it to appear (race
  # between docker_run -> entrypoint creating the key -> our wrapper using it).
  local key_path="$TMP_DIR/id_ed25519"
  local deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -f "$key_path" ] && break
    sleep 1
  done
  if [ ! -f "$key_path" ]; then
    log "ERROR: container did not create $key_path within 30s -- entrypoint failure?"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -40 >&2 || true
    exit 2
  fi
  # Permissions can be off when the container writes via root: ensure we can
  # read it (we own the file on macOS via volume mount).
  chmod 600 "$key_path" 2>/dev/null || true
  SSH_KEY="$key_path"

  cat > "$WRAP_DIR/ssh" <<WRAP_EOF
#!/usr/bin/env bash
# auto-generated by tests/qemu-docker/run-e2e.sh -- injects port + key.
exec /usr/bin/ssh -p "${SSH_PORT}" \\
  -i "${SSH_KEY}" \\
  -o "UserKnownHostsFile=${KNOWN_HOSTS}" \\
  -o StrictHostKeyChecking=no \\
  -o LogLevel=ERROR \\
  "\$@"
WRAP_EOF

  cat > "$WRAP_DIR/scp" <<WRAP_EOF
#!/usr/bin/env bash
exec /usr/bin/scp -P "${SSH_PORT}" \\
  -i "${SSH_KEY}" \\
  -o "UserKnownHostsFile=${KNOWN_HOSTS}" \\
  -o StrictHostKeyChecking=no \\
  -o LogLevel=ERROR \\
  "\$@"
WRAP_EOF

  chmod +x "$WRAP_DIR/ssh" "$WRAP_DIR/scp"
  export PATH="$WRAP_DIR:$PATH"
  : > "$KNOWN_HOSTS"
}

# ----------------------------- bootstrap memory ------------------------------
bootstrap_memory() {
  rm -rf "$MEMORY_DIR"
  mkdir -p "$MEMORY_DIR/_templates"
  cp "$SKILL_HOME/memory/_templates/"*.md "$MEMORY_DIR/_templates/" 2>/dev/null || true
  [ -f "$SKILL_HOME/memory/routers.yaml.example" ] && \
    cp "$SKILL_HOME/memory/routers.yaml.example" "$MEMORY_DIR/routers.yaml.example"

  cat > "$MEMORY_DIR/routers.yaml" <<EOF
version: 1

routers:
  $ROUTER_ALIAS:
    host: 127.0.0.1
    user: root
    ssh_key: $SSH_KEY
    ssh_alias: ""
    notes: "openwrt-skill qemu-docker VM, do not commit"

default_router: $ROUTER_ALIAS
EOF
}

# ============================== TEST STEPS ===================================

# Step 1 -- doctor on a clean VM. Expects sing-box=false, openwrt_version 24.x.
test_01_doctor_pre() {
  local name="step1: doctor.sh (pre-install, no sing-box)"
  local out rc
  out="$("$SKILL_HOME/bin/doctor.sh" --router "$ROUTER_ALIAS" --json 2>"$TMP_DIR/doctor-pre.err")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; err: $(tr '\n' ' ' <"$TMP_DIR/doctor-pre.err" | head -c 240)"
    return
  fi
  local probe
  probe="$(printf '%s\n' "$out" | awk '/^\{/{f=1} f{print}')"
  printf '%s\n' "$probe" > "$TMP_DIR/doctor-pre.json"
  if [ -z "$probe" ]; then
    step_fail "$name" "no JSON object in doctor stdout"
    return
  fi
  local ver sb_installed
  ver="$(printf '%s' "$probe" | jq -r '.openwrt_version // ""')"
  sb_installed="$(printf '%s' "$probe" | jq -r '.packages."sing-box" // false')"
  local fails=""
  case "$ver" in
    24.*|SNAPSHOT|*snapshot*) : ;;
    "") fails="$fails openwrt_version=empty" ;;
    *)  fails="$fails openwrt_version=$ver(want-24.x-or-SNAPSHOT)" ;;
  esac
  [ "$sb_installed" = "false" ] || fails="$fails packages.sing-box=$sb_installed(want-false)"

  if [ -n "$fails" ]; then
    step_fail "$name" "asserts:$fails"
    return
  fi
  step_pass "$name"
  log "  pre: openwrt_version=$ver sing-box=$sb_installed"
}

# Step 2 -- backup-now (snapshot the pre-VPN state).
test_02_backup_now() {
  local name="step2: backup-now.sh --label 'before install-vpn'"
  local out rc
  out="$("$SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
        --label "before install-vpn" --quiet 2>"$TMP_DIR/backup.err")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; err: $(tr '\n' ' ' <"$TMP_DIR/backup.err" | head -c 280)"
    return
  fi
  local snap_id
  snap_id="$(printf '%s\n' "$out" | tail -n1 | tr -d '[:space:]')"
  case "$snap_id" in
    snap-*) ;;
    *) step_fail "$name" "stdout did not look like snapshot id: '$snap_id'"; return ;;
  esac
  PRE_INSTALL_SNAP_ID="$snap_id"
  printf '%s\n' "$snap_id" > "$SNAPSHOT_ID_FILE"
  step_pass "$name"
  log "  snapshot: $snap_id"
}

# Step 3 -- install-vpn (THE big one): real apk install of sing-box + render
# config from the real VLESS URL.
test_03_install_vpn() {
  local name="step3: install-vpn.sh --url '<redacted>' --add-proxy-port $PROXY_GUEST_PORT"
  local URL rc
  URL="$(<"$URL_FILE")"
  case "$URL" in
    vless://*) : ;;
    *) step_fail "$name" "URL file is not vless://... (refusing)"; URL=""; return ;;
  esac
  # Pass via --url; never echo. Run synchronously (this is a long step).
  "$SKILL_HOME/bin/install-vpn.sh" \
    --router "$ROUTER_ALIAS" \
    --url "$URL" \
    --add-proxy-port "$PROXY_GUEST_PORT" \
    >"$TMP_DIR/installvpn.out" 2>"$TMP_DIR/installvpn.err"
  rc=$?
  URL=""; unset URL
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; stderr tail: $(tail -10 "$TMP_DIR/installvpn.err" | tr '\n' ' ' | head -c 400)"
    return
  fi
  step_pass "$name"
}

# Step 4 -- doctor again, must show sing-box installed + config.valid + tproxy.
test_04_doctor_post() {
  local name="step4: doctor.sh (post-install) -- sing-box=true, config.valid=true, tproxy.running=true"
  local out rc
  out="$("$SKILL_HOME/bin/doctor.sh" --router "$ROUTER_ALIAS" --json 2>"$TMP_DIR/doctor-post.err")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; err: $(tr '\n' ' ' <"$TMP_DIR/doctor-post.err" | head -c 240)"
    return
  fi
  local probe
  probe="$(printf '%s\n' "$out" | awk '/^\{/{f=1} f{print}')"
  printf '%s\n' "$probe" > "$TMP_DIR/doctor-post.json"
  local sb cfg tproxy fails=""
  sb="$(printf '%s' "$probe" | jq -r '.packages."sing-box" // false')"
  cfg="$(printf '%s' "$probe" | jq -r '.config.valid // false')"
  tproxy="$(printf '%s' "$probe" | jq -r '.tproxy.running // false')"
  [ "$sb" = "true" ]      || fails="$fails sing-box=$sb"
  [ "$cfg" = "true" ]     || fails="$fails config.valid=$cfg"
  [ "$tproxy" = "true" ]  || fails="$fails tproxy.running=$tproxy"
  if [ -n "$fails" ]; then
    step_fail "$name" "asserts:$fails"
    return
  fi
  step_pass "$name"
  log "  post: sing-box=$sb config.valid=$cfg tproxy.running=$tproxy"
}

# Step 5 -- health.sh must report sing_box.running=true.
test_05_health() {
  local name="step5: health.sh -- sing_box.running=true"
  local out rc
  out="$("$SKILL_HOME/bin/health.sh" --router "$ROUTER_ALIAS" --json 2>"$TMP_DIR/health.err")"
  rc=$?
  # health.sh may exit non-zero if other checks fail; we only assert the
  # specific field requested by the spec.
  if [ -z "$out" ]; then
    step_fail "$name" "empty stdout; exit=$rc; err: $(tr '\n' ' ' <"$TMP_DIR/health.err" | head -c 240)"
    return
  fi
  if ! printf '%s\n' "$out" | jq -e '.' >/dev/null 2>&1; then
    step_fail "$name" "stdout not valid JSON; head: $(printf '%s' "$out" | head -c 200)"
    return
  fi
  local sb
  sb="$(printf '%s\n' "$out" | jq -r '
    if (.sing_box.running != null) then .sing_box.running
    elif (.sb_running != null) then .sb_running
    else "MISSING" end')"
  case "$sb" in
    true) step_pass "$name"; log "  sing_box.running=$sb (health exit=$rc)" ;;
    MISSING) step_fail "$name" "sing_box.running missing from JSON" ;;
    *)   step_fail "$name" "sing_box.running=$sb (want true); health exit=$rc" ;;
  esac
}

# Step 6 -- THE big test: real VLESS Reality traffic through SOCKS5 proxy.
test_06_real_vpn_traffic() {
  local name="step6: real VLESS Reality via SOCKS5 (host:$PROXY_HOST_PORT -> guest:$PROXY_GUEST_PORT)"

  # Wait briefly for sing-box's mixed inbound to bind.
  local deadline=$(( $(date +%s) + 20 ))
  local ok=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if /usr/bin/nc -z 127.0.0.1 "$PROXY_HOST_PORT" 2>/dev/null; then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" -ne 1 ]; then
    step_fail "$name" "SOCKS port 127.0.0.1:$PROXY_HOST_PORT not accepting after 20s"
    return
  fi

  # Host-direct IP for comparison.
  HOST_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo "")"

  local vpn_out rc
  vpn_out="$(curl --max-time 30 -fsS --proxy "socks5h://127.0.0.1:$PROXY_HOST_PORT" \
    https://api.ipify.org 2>"$TMP_DIR/curl-vpn.err")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "curl-via-socks5 failed (exit $rc); err: $(tr '\n' ' ' <"$TMP_DIR/curl-vpn.err" | head -c 320)"
    return
  fi
  VPN_IP="$(printf '%s' "$vpn_out" | tr -d '[:space:]')"
  if [ -z "$VPN_IP" ]; then
    step_fail "$name" "empty body from api.ipify.org via SOCKS"
    return
  fi
  if [ -n "$HOST_IP" ] && [ "$VPN_IP" = "$HOST_IP" ]; then
    step_fail "$name" "VPN IP equals host IP ($VPN_IP) -- traffic NOT going through VPN"
    return
  fi
  VPN_COUNTRY="$(curl -fsS --max-time 10 "https://ipapi.co/${VPN_IP}/country/" 2>/dev/null | tr -d '[:space:]' || echo "?")"
  [ -n "$VPN_COUNTRY" ] || VPN_COUNTRY="?"

  step_pass "$name"
  log "  host=$HOST_IP vpn=$VPN_IP country=$VPN_COUNTRY"
  case "$VPN_COUNTRY" in
    PL) log "  country=PL (expected)" ;;
    \?) log "  country lookup failed (lookup service rate-limit?)" ;;
    *)  log "  country=$VPN_COUNTRY (note: expected PL; provider may have rotated)" ;;
  esac
}

# Step 7 -- add-domain + retest.
test_07_add_domain() {
  local name="step7: add-domain.sh api.ipify.org --outbound auto-failover"
  local rc
  "$SKILL_HOME/bin/add-domain.sh" --router "$ROUTER_ALIAS" \
    --domain api.ipify.org --outbound auto-failover \
    >"$TMP_DIR/adddom.out" 2>"$TMP_DIR/adddom.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; err: $(tail -8 "$TMP_DIR/adddom.err" | tr '\n' ' ' | head -c 360)"
    return
  fi
  # Re-test SOCKS still works.
  local out rc2
  out="$(curl --max-time 25 -fsS --proxy "socks5h://127.0.0.1:$PROXY_HOST_PORT" \
    https://api.ipify.org 2>"$TMP_DIR/curl-add.err")"
  rc2=$?
  if [ "$rc2" -ne 0 ] || [ -z "$out" ]; then
    step_fail "$name" "SOCKS request post-add-domain failed (exit $rc2)"
    return
  fi
  step_pass "$name"
  log "  post-add-domain vpn IP: $(printf '%s' "$out" | tr -d '[:space:]')"
}

# Step 8 -- remove-domain + retest.
test_08_remove_domain() {
  local name="step8: remove-domain.sh api.ipify.org"
  local rc
  "$SKILL_HOME/bin/remove-domain.sh" --router "$ROUTER_ALIAS" --domain api.ipify.org \
    >"$TMP_DIR/rmdom.out" 2>"$TMP_DIR/rmdom.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; err: $(tail -8 "$TMP_DIR/rmdom.err" | tr '\n' ' ' | head -c 360)"
    return
  fi
  local out rc2
  out="$(curl --max-time 25 -fsS --proxy "socks5h://127.0.0.1:$PROXY_HOST_PORT" \
    https://api.ipify.org 2>"$TMP_DIR/curl-rm.err")"
  rc2=$?
  if [ "$rc2" -ne 0 ]; then
    # FakeIP cache may have stale entries -- info, not fail. But spec says we
    # should still pass through.
    step_fail "$name" "SOCKS request post-remove-domain failed (exit $rc2); FakeIP cache?"
    return
  fi
  step_pass "$name"
}

# Step 9 -- restore the pre-install snapshot. We *expect* exit 20 (safety
# rollback) because the snapshot predates sing-box installation; restoring it
# would remove sing-box config; the post-restore sing-box health check fails;
# restore.sh rolls forward to the latest auto-snapshot to keep the box safe.
test_09_restore() {
  local snap_id="$PRE_INSTALL_SNAP_ID"
  local name="step9: restore.sh --snapshot $snap_id  (expect exit 20 = safety rollback)"
  if [ -z "$snap_id" ]; then
    step_skip "$name" "no snapshot id from step 2"
    return
  fi
  local rc
  "$SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" --snapshot "$snap_id" \
    >"$TMP_DIR/restore.out" 2>"$TMP_DIR/restore.err"
  rc=$?
  case "$rc" in
    20)
      step_pass "$name"
      log "  restore exited 20 (safety rollback) -- documented behavior on pre-install snapshot" ;;
    0)
      # Also acceptable; some restore paths self-heal.
      step_pass "$name"
      log "  restore exited 0 (no safety rollback needed)" ;;
    *)
      step_fail "$name" "unexpected exit=$rc; err: $(tail -8 "$TMP_DIR/restore.err" | tr '\n' ' ' | head -c 360)" ;;
  esac
}

# ----------------------------- main flow -------------------------------------
main() {
  : > "$RUN_LOG"
  local t_start
  t_start=$(date +%s)

  prereq_check
  docker_build

  if [ "${IMAGE_ONLY:-0}" = "1" ]; then
    log "IMAGE_ONLY=1 -- exiting after build."
    exit 0
  fi

  hr; log "PHASE 1: boot VM"; hr
  docker_run
  write_ssh_wrappers   # blocks until /data/id_ed25519 appears
  bootstrap_memory
  wait_for_sshd

  hr; log "PHASE 2: test steps"; hr
  test_01_doctor_pre
  test_02_backup_now
  test_03_install_vpn
  test_04_doctor_post
  test_05_health
  test_06_real_vpn_traffic
  test_07_add_domain
  test_08_remove_domain
  test_09_restore

  hr
  say "QEMU-DOCKER E2E SUMMARY"
  hr
  local i pass=0 fail=0 skip=0
  for i in "${!STEP_NAMES[@]}"; do
    local n="${STEP_NAMES[$i]}" r="${STEP_RESULTS[$i]}"
    case "$r" in
      PASS*) pass=$((pass+1)) ;;
      FAIL*) fail=$((fail+1)) ;;
      SKIP*) skip=$((skip+1)) ;;
    esac
    printf '  %-82s %s\n' "$n" "$r"
  done
  hr
  printf 'TOTAL: %d pass, %d fail, %d skip\n' "$pass" "$fail" "$skip"
  if [ -n "$VPN_IP" ] || [ -n "$HOST_IP" ]; then
    printf 'VPN traffic: host=%s vpn=%s country=%s\n' "${HOST_IP:-?}" "${VPN_IP:-?}" "${VPN_COUNTRY:-?}"
  fi
  local t_end=$(date +%s)
  printf 'wall-clock: %ds\n' "$((t_end - t_start))"
  hr

  [ "$fail" -eq 0 ]
}

main "$@"
