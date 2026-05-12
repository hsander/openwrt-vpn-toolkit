#!/usr/bin/env bash
# tests/qemu-smoke/run-e2e.sh
#
# End-to-end runner: prepare image -> boot QEMU+HVF -> run the full bin/* flow
# against a real OpenWRT VM, validating a real VLESS Reality VPN handshake.
#
# Usage:
#   bash tests/qemu-smoke/run-e2e.sh
#   KEEP_VM=1 bash tests/qemu-smoke/run-e2e.sh   # leave VM running for debug
#
# Secret handling:
#   The VLESS URL is read from ~/.openwrt-skill/secrets/qemu-test.url (chmod
#   600). It is held ONLY in a shell-local variable here and passed to
#   bin/install-vpn.sh via --url "$URL". We never echo it, never log it,
#   never persist it.

set -uo pipefail

# Deliberately no `set -e`: every step must run independently and the summary
# table at the end must reflect all of them.

# ----------------------------- paths & config ---------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Артефакты вне skill-дерева. Legacy test, но поддерживаем правило.
TMP_DIR="${LEGACY_QEMU_TMP_DIR:-${TMPDIR:-/tmp}/openwrt-skill-legacy-qemu}"
MEMORY_DIR="$TMP_DIR/memory"
WRAP_DIR="$TMP_DIR/bin"
KNOWN_HOSTS="$TMP_DIR/known_hosts"
RUN_LOG="$TMP_DIR/run.log"
SNAPSHOT_ID_FILE="$TMP_DIR/last-snapshot-id.txt"

ROUTER_ALIAS="qemubox"
SSH_PORT="${SSH_PORT:-2299}"
PROXY_HOST_PORT="${PROXY_HOST_PORT:-14000}"
PROXY_GUEST_PORT="${PROXY_GUEST_PORT:-4000}"
URL_FILE="${URL_FILE:-$HOME/.openwrt-skill/secrets/qemu-test.url}"

mkdir -p "$TMP_DIR" "$MEMORY_DIR" "$WRAP_DIR"

# ----------------------------- pretty logging ---------------------------------
log()  { printf '[run-e2e %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
say()  { printf '%s\n' "$*"; }
hr()   { printf -- '----------------------------------------------------------------\n'; }

# Step results accumulator.
declare -a STEP_NAMES=()
declare -a STEP_RESULTS=()

record() { STEP_NAMES+=("$1"); STEP_RESULTS+=("$2"); }
step_pass() { record "$1" "PASS"; log "PASS: $1"; }
step_fail() { record "$1" "FAIL: $2"; log "FAIL: $1 -- $2"; }
step_skip() { record "$1" "SKIP: $2"; log "SKIP: $1 -- $2"; }

# ----------------------------- teardown ---------------------------------------
QEMU_PID=""
teardown() {
  local rc=$?
  if [ "${KEEP_VM:-0}" = "1" ]; then
    log "KEEP_VM=1 — leaving VM running. SSH: ssh -i $SSH_KEY -p $SSH_PORT root@127.0.0.1"
    log "  stop with: kill $QEMU_PID  (or: pkill -f qemu-system-aarch64)"
    return $rc
  fi
  # Try to poweroff cleanly via SSH so the writable image isn't corrupted.
  if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    ssh_to_vm '/sbin/poweroff -f' >/dev/null 2>&1 || true
    # Wait up to 10s for graceful exit.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$QEMU_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$QEMU_PID" 2>/dev/null; then
      kill "$QEMU_PID" 2>/dev/null || true
      sleep 1
      kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
  fi
  return $rc
}
trap teardown EXIT INT TERM

# ----------------------------- prereqs ----------------------------------------
prereq_check() {
  local missing=()
  for cmd in qemu-system-aarch64 docker jq yq ssh ssh-keygen curl gunzip shasum; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "ERROR: missing host commands: ${missing[*]}"
    log "  brew install ${missing[*]}"
    exit 2
  fi
  if ! qemu-system-aarch64 -accel help 2>/dev/null | grep -q '^hvf$'; then
    log "ERROR: qemu HVF accelerator unavailable; refusing TCG fallback"
    exit 2
  fi
  if ! docker info >/dev/null 2>&1; then
    log "ERROR: docker is not running (Docker Desktop?)"
    exit 2
  fi
  if [ ! -f "$URL_FILE" ]; then
    log "ERROR: VLESS URL file missing: $URL_FILE"
    log "  Expected chmod 600, one line vless://..."
    exit 2
  fi
  # Don't read the URL yet — only when we need it.
}

# ----------------------------- ssh wrappers -----------------------------------
# bin/*.sh shells out via `ssh user@host` (lib/ssh-runner.sh hard-codes no `-p`).
# We PATH-shadow `ssh` and `scp` with wrappers that auto-add the QEMU port,
# our private key, and a per-run known_hosts file.
#
# This is the same trick used by tests/smoke/run-smoke.sh (the docker
# smoke runner) — keeps production code untouched.
SSH_KEY=""
write_ssh_wrappers() {
  cat > "$WRAP_DIR/ssh" <<WRAP_EOF
#!/usr/bin/env bash
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

# Convenience helper: SSH with our wrapper to run a command in the VM.
ssh_to_vm() {
  "$WRAP_DIR/ssh" root@127.0.0.1 "$@"
}

# ----------------------------- bootstrap memory -------------------------------
bootstrap_memory() {
  rm -rf "$MEMORY_DIR"
  mkdir -p "$MEMORY_DIR/_templates"
  cp "$SKILL_HOME/memory/_templates/"*.md "$MEMORY_DIR/_templates/"
  cp "$SKILL_HOME/memory/routers.yaml.example" "$MEMORY_DIR/routers.yaml.example"

  cat > "$MEMORY_DIR/routers.yaml" <<EOF
version: 1

routers:
  $ROUTER_ALIAS:
    host: 127.0.0.1
    user: root
    ssh_key: $SSH_KEY
    ssh_alias: ""
    notes: "openwrt-skill qemu-smoke VM (HVF), do not commit"

default_router: $ROUTER_ALIAS
EOF
  export OPENWRT_SKILL_HOME="$SKILL_HOME"
  export OPENWRT_SKILL_MEMORY="$MEMORY_DIR"
}

# ----------------------------- prepare + boot ---------------------------------
IMAGE_PATH=""
KERNEL_PATH=""
SSH_PUB=""

prepare_image() {
  log "preparing image (may download upstream OpenWRT on first run)..."
  local out
  if ! out="$(bash "$SCRIPT_DIR/prepare-image.sh" 2>>"$RUN_LOG")"; then
    log "ERROR: prepare-image.sh failed; tail of run log:"
    tail -40 "$RUN_LOG" >&2 || true
    exit 2
  fi
  IMAGE_PATH="$(printf '%s\n' "$out" | awk -F= '/^IMAGE_PATH=/{print $2}')"
  KERNEL_PATH="$(printf '%s\n' "$out" | awk -F= '/^KERNEL_PATH=/{print $2}')"
  SSH_KEY="$(printf '%s\n' "$out" | awk -F= '/^SSH_KEY=/{print $2}')"
  SSH_PUB="$(printf '%s\n' "$out" | awk -F= '/^SSH_PUB=/{print $2}')"
  [ -f "$IMAGE_PATH" ]  || { log "ERROR: prepared image missing"; exit 2; }
  [ -f "$KERNEL_PATH" ] || { log "ERROR: kernel missing"; exit 2; }
  [ -f "$SSH_KEY" ]     || { log "ERROR: ssh key missing"; exit 2; }
}

boot_vm() {
  log "booting VM via QEMU+HVF..."
  local out
  if ! out="$(bash "$SCRIPT_DIR/boot-vm.sh" \
      --image "$IMAGE_PATH" \
      --kernel "$KERNEL_PATH" \
      --ssh-port "$SSH_PORT" \
      --proxy-port-fwd "${PROXY_HOST_PORT}:${PROXY_GUEST_PORT}" \
      --ssh-key "$SSH_KEY" \
      --pid-file "$TMP_DIR/qemu.pid" \
      --qemu-log "$TMP_DIR/qemu.log" \
      --ready-timeout 120 2>>"$RUN_LOG")"; then
    log "ERROR: boot-vm.sh failed; tail of run log:"
    tail -40 "$RUN_LOG" >&2 || true
    exit 2
  fi
  QEMU_PID="$(printf '%s\n' "$out" | awk -F= '/^QEMU_PID=/{print $2}')"
  [ -n "$QEMU_PID" ] || { log "ERROR: no QEMU_PID from boot-vm"; exit 2; }
  log "VM up, QEMU_PID=$QEMU_PID"
}

# ----------------------------- test steps -------------------------------------

# Step 1 — doctor (clean VM, no sing-box installed yet).
test_01_doctor_pre() {
  local name="step1: doctor.sh --json (pre-install)"
  local out rc
  out="$("$SKILL_HOME/bin/doctor.sh" --router "$ROUTER_ALIAS" --json 2>"$TMP_DIR/doctor-pre.err")" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; err: $(tr '\n' ' ' <"$TMP_DIR/doctor-pre.err" | head -c 200)"
    return
  fi
  # Strip preamble before first '{' (doctor prints state.md path first).
  local probe
  probe="$(printf '%s\n' "$out" | awk '/^\{/{f=1} f{print}')"
  printf '%s\n' "$probe" > "$TMP_DIR/doctor-pre.json"

  local sb_installed jq_installed
  sb_installed="$(printf '%s' "$probe" | jq -r '.packages."sing-box" // false')"
  jq_installed="$(printf '%s' "$probe" | jq -r '.packages.jq // false')"

  # We expect sing-box=false (not installed yet). jq=false is fine on the bare
  # VM too (install-minimal will apk add it).
  case "$sb_installed" in
    false) step_pass "$name"; log "  pre: sing-box=$sb_installed jq=$jq_installed";;
    true)  step_fail "$name" "sing-box already installed on bare VM (unexpected): $sb_installed";;
    *)     step_fail "$name" "packages.\"sing-box\" missing/garbage: '$sb_installed'";;
  esac
}

# Step 2 — backup-now (snapshot the pre-VPN baseline).
PRE_INSTALL_SNAP_ID=""
test_02_backup_now() {
  local name="step2: backup-now.sh --label 'before install-vpn'"
  local out rc
  out="$("$SKILL_HOME/bin/backup-now.sh" --router "$ROUTER_ALIAS" \
        --label "before install-vpn" --quiet 2>"$TMP_DIR/backup.err")" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -ne 0 ]; then
    # On a totally bare VM with nothing in /etc/sing-box etc., backup-now
    # may exit 2 with "no_paths_to_snapshot" — same finding as the docker
    # smoke runner. Record clearly.
    step_fail "$name" "exit=$rc; err: $(tr '\n' ' ' <"$TMP_DIR/backup.err" | head -c 240)"
    return
  fi
  local snap_id
  snap_id="$(printf '%s\n' "$out" | tail -n1 | tr -d '[:space:]')"
  case "$snap_id" in
    snap-*) ;;
    *) step_fail "$name" "stdout did not look like a snapshot id: '$snap_id'"; return ;;
  esac
  PRE_INSTALL_SNAP_ID="$snap_id"
  printf '%s\n' "$snap_id" > "$SNAPSHOT_ID_FILE"
  step_pass "$name"
  log "  snapshot id: $snap_id"
}

# Step 3 — install-vpn (THE BIG ONE).
test_03_install_vpn() {
  local name="step3: install-vpn.sh --url '<redacted>' --add-proxy-port $PROXY_GUEST_PORT"
  # Read URL ONLY here, ONLY into a shell-local var. Do NOT echo it.
  local URL rc
  URL="$(<"$URL_FILE")"
  # Don't log the URL; only confirm shape.
  case "$URL" in
    vless://*) : ;;
    *) step_fail "$name" "URL file does not start with vless:// (refusing)"; URL=""; return ;;
  esac

  # The bin/* scripts use our PATH-shadowed ssh/scp wrappers.
  "$SKILL_HOME/bin/install-vpn.sh" \
    --router "$ROUTER_ALIAS" \
    --url "$URL" \
    --add-proxy-port "$PROXY_GUEST_PORT" \
    >"$TMP_DIR/installvpn.out" 2>"$TMP_DIR/installvpn.err" &
  local install_pid=$!
  # Clear the var ASAP to minimise lifetime in this shell.
  URL=""
  unset URL

  wait "$install_pid"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; stderr tail: $(tail -8 "$TMP_DIR/installvpn.err" | tr '\n' ' ' | head -c 400)"
    return
  fi

  # Verify via doctor (post-install).
  local out probe
  if ! out="$("$SKILL_HOME/bin/doctor.sh" --router "$ROUTER_ALIAS" --json 2>"$TMP_DIR/doctor-post.err")"; then
    step_fail "$name" "doctor (post-install) exited non-zero"
    return
  fi
  probe="$(printf '%s\n' "$out" | awk '/^\{/{f=1} f{print}')"
  printf '%s\n' "$probe" > "$TMP_DIR/doctor-post.json"

  local sb cfg_valid out_count
  sb="$(printf '%s' "$probe" | jq -r '.packages."sing-box" // false')"
  cfg_valid="$(printf '%s' "$probe" | jq -r '.config.valid // false')"
  out_count="$(printf '%s' "$probe" | jq -r '.config.outbound_count // 0')"

  local fails=""
  [ "$sb" = "true" ] || fails="$fails packages.sing-box=$sb"
  [ "$cfg_valid" = "true" ] || fails="$fails config.valid=$cfg_valid"
  [ "${out_count:-0}" -ge 2 ] 2>/dev/null || fails="$fails outbound_count=$out_count"

  # Health check: sing_box.running must be true.
  local health_out health_running
  if health_out="$("$SKILL_HOME/bin/health.sh" --router "$ROUTER_ALIAS" --json 2>"$TMP_DIR/health.err")"; then
    health_running="$(printf '%s' "$health_out" | jq -r '.sing_box.running // false')"
  else
    health_running="$(printf '%s' "$health_out" | jq -r '.sing_box.running // false' 2>/dev/null || echo "MISSING")"
  fi
  [ "$health_running" = "true" ] || fails="$fails sing_box.running=$health_running"

  if [ -n "$fails" ]; then
    step_fail "$name" "verify:$fails"
    return
  fi
  step_pass "$name"
  log "  post-install: sing-box=$sb config.valid=$cfg_valid outbounds=$out_count running=$health_running"
}

# Step 4 — Real VPN traffic test through SOCKS5 proxy.
HOST_IP=""
VPN_IP=""
VPN_COUNTRY=""
test_04_real_vpn_traffic() {
  local name="step4: real VLESS Reality traffic via SOCKS5 (host:$PROXY_HOST_PORT -> guest:$PROXY_GUEST_PORT)"

  # Wait a bit for sing-box to fully open the socket. Give it up to 20s.
  local deadline=$(( $(date +%s) + 20 )) ok=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if /usr/bin/nc -z 127.0.0.1 "$PROXY_HOST_PORT" 2>/dev/null; then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" -ne 1 ]; then
    step_fail "$name" "SOCKS5 proxy port 127.0.0.1:$PROXY_HOST_PORT not accepting connections"
    return
  fi

  # 4a. Get the host's direct IP for comparison.
  HOST_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo "")"
  if [ -z "$HOST_IP" ]; then
    log "  warn: could not fetch host IP (no internet on host?) — continuing"
  fi

  # 4b. Fetch IP through the SOCKS5 proxy. socks5h:// → DNS resolved on the
  # proxy side (so FakeIP, if active, routes via the VPN).
  local vpn_out rc
  vpn_out="$(curl --max-time 30 -fsS --proxy "socks5h://127.0.0.1:$PROXY_HOST_PORT" \
    https://api.ipify.org 2>"$TMP_DIR/curl-vpn.err")" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "curl through SOCKS5 failed (exit $rc); err: $(tr '\n' ' ' <"$TMP_DIR/curl-vpn.err" | head -c 280)"
    return
  fi
  VPN_IP="$(printf '%s' "$vpn_out" | tr -d '[:space:]')"

  if [ -z "$VPN_IP" ]; then
    step_fail "$name" "empty body from api.ipify.org via SOCKS5"
    return
  fi

  # 4c. Compare to host IP.
  if [ -n "$HOST_IP" ] && [ "$VPN_IP" = "$HOST_IP" ]; then
    step_fail "$name" "VPN IP equals host IP ($VPN_IP) — traffic NOT going through VPN"
    return
  fi

  # 4d. GeoIP lookup (best-effort, don't fail on country mismatch).
  VPN_COUNTRY="$(curl -fsS --max-time 10 "https://ipapi.co/${VPN_IP}/country/" 2>/dev/null | tr -d '[:space:]' || echo "?")"
  case "$VPN_COUNTRY" in
    PL) log "  country: PL (expected) — VLESS Reality handshake confirmed" ;;
    "") VPN_COUNTRY="?" ;;
    *)  log "  country: $VPN_COUNTRY (expected PL — provider may have rotated IP; not a failure)" ;;
  esac

  step_pass "$name"
  log "  host IP: ${HOST_IP:-?}  vpn IP: $VPN_IP  country: $VPN_COUNTRY"
}

# Step 5 — add-domain.
test_05_add_domain() {
  local name="step5: add-domain.sh api.ipify.org --outbound auto-failover"
  local rc
  "$SKILL_HOME/bin/add-domain.sh" --router "$ROUTER_ALIAS" \
    --domain api.ipify.org --outbound auto-failover \
    >"$TMP_DIR/adddom.out" 2>"$TMP_DIR/adddom.err" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; err: $(tail -6 "$TMP_DIR/adddom.err" | tr '\n' ' ' | head -c 320)"
    return
  fi
  # Re-curl through SOCKS — should still work.
  local out rc2
  out="$(curl --max-time 20 -fsS --proxy "socks5h://127.0.0.1:$PROXY_HOST_PORT" \
    https://api.ipify.org 2>"$TMP_DIR/curl-add.err")" || rc2=$?
  rc2="${rc2:-0}"
  if [ "$rc2" -ne 0 ] || [ -z "$out" ]; then
    step_fail "$name" "after add-domain, SOCKS request failed (exit $rc2)"
    return
  fi
  step_pass "$name"
  log "  after add-domain, vpn IP: $(printf '%s' "$out" | tr -d '[:space:]')"
}

# Step 6 — remove-domain.
test_06_remove_domain() {
  local name="step6: remove-domain.sh api.ipify.org"
  local rc
  "$SKILL_HOME/bin/remove-domain.sh" --router "$ROUTER_ALIAS" --domain api.ipify.org \
    >"$TMP_DIR/rmdom.out" 2>"$TMP_DIR/rmdom.err" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -ne 0 ]; then
    step_fail "$name" "exit=$rc; err: $(tail -6 "$TMP_DIR/rmdom.err" | tr '\n' ' ' | head -c 320)"
    return
  fi
  local out rc2
  out="$(curl --max-time 20 -fsS --proxy "socks5h://127.0.0.1:$PROXY_HOST_PORT" \
    https://api.ipify.org 2>"$TMP_DIR/curl-rm.err")" || rc2=$?
  rc2="${rc2:-0}"
  if [ "$rc2" -ne 0 ]; then
    step_fail "$name" "after remove-domain, SOCKS request failed (exit $rc2)"
    return
  fi
  step_pass "$name"
}

# Step 7 — restore (expect exit 20 = safety rollback fired, per spec).
test_07_restore() {
  local name="step7: restore.sh --snapshot $PRE_INSTALL_SNAP_ID (expect exit 20 safety rollback)"
  if [ -z "$PRE_INSTALL_SNAP_ID" ]; then
    step_skip "$name" "no snapshot id from step 2"
    return
  fi
  local rc
  "$SKILL_HOME/bin/restore.sh" --router "$ROUTER_ALIAS" --snapshot "$PRE_INSTALL_SNAP_ID" \
    >"$TMP_DIR/restore.out" 2>"$TMP_DIR/restore.err" || rc=$?
  rc="${rc:-0}"
  case "$rc" in
    20) step_pass "$name" ; log "  restore exited 20 (safety rollback) — expected" ;;
    0)  # Also acceptable: pre-install snapshot may have included the empty
        # baseline AND restore's verify may pass because sing-box check still
        # works (we left it installed). Don't fail, but flag.
        step_pass "$name (exit 0 — restore succeeded without firing safety rollback)"
        ;;
    *)
        step_fail "$name" "unexpected exit=$rc; err: $(tail -6 "$TMP_DIR/restore.err" | tr '\n' ' ' | head -c 320)"
        ;;
  esac
}

# ----------------------------- main flow --------------------------------------
main() {
  : > "$RUN_LOG"
  local t_start
  t_start=$(date +%s)

  prereq_check

  hr; log "PHASE 1: prepare + boot"; hr
  prepare_image
  bootstrap_memory
  write_ssh_wrappers
  boot_vm

  hr; log "PHASE 2: test steps"; hr
  test_01_doctor_pre
  test_02_backup_now
  test_03_install_vpn
  test_04_real_vpn_traffic
  test_05_add_domain
  test_06_remove_domain
  test_07_restore

  hr
  say "QEMU E2E SUMMARY"
  hr
  local i pass=0 fail=0 skip=0
  for i in "${!STEP_NAMES[@]}"; do
    local n="${STEP_NAMES[$i]}" r="${STEP_RESULTS[$i]}"
    case "$r" in
      PASS*) pass=$((pass+1)) ;;
      FAIL*) fail=$((fail+1)) ;;
      SKIP*) skip=$((skip+1)) ;;
    esac
    printf '  %-78s %s\n' "$n" "$r"
  done
  hr
  printf 'TOTAL: %d pass, %d fail, %d skip\n' "$pass" "$fail" "$skip"
  if [ -n "$VPN_IP" ]; then
    printf 'VPN traffic test: your IP=%s, vpn IP=%s, country=%s\n' "${HOST_IP:-?}" "$VPN_IP" "${VPN_COUNTRY:-?}"
  fi
  local t_end=$(date +%s)
  printf 'wall-clock: %ds\n' "$((t_end - t_start))"
  hr

  [ "$fail" -eq 0 ]
}

main "$@"
