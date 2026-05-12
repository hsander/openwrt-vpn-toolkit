#!/bin/sh
# OpenWrt rootfs smoke tests for the Stage 0 safety scripts.
# Runs without bash/bats. Intended for `openwrt/rootfs:x86-64`.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/lib"

fail() {
  echo "not ok - $1" >&2
  exit 1
}

ok() {
  echo "ok - $1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

require_cmd jq
require_cmd flock
require_cmd procd
require_cmd start-stop-daemon

PRECHECK="$("$LIB/preflight-safety.sh")"
echo "$PRECHECK" | jq -e '.status == "ok"' >/dev/null || fail "preflight-safety did not report ok"
ok "safety preflight passes on OpenWrt"

sh -n "$ROOT/openwrt/init.d/vpn-kit-rollback" || fail "init.d wrapper syntax is invalid"
ok "procd init.d wrapper parses on OpenWrt"

SYSTEM_JSON="$("$ROOT/scripts/detect-system.sh")"
echo "$SYSTEM_JSON" | jq -e '.package_manager == "apk" and .openwrt_major >= 24 and .commands.procd == true' >/dev/null \
  || fail "detect-system did not report expected OpenWrt facts"
ok "detect-system works on OpenWrt"

LAN_JSON="$("$ROOT/scripts/detect-lan.sh")"
echo "$LAN_JSON" | jq -e '.zones | type == "array"' >/dev/null || fail "detect-lan did not return zones"
ok "detect-lan works on OpenWrt"

PREFLIGHT_JSON="$("$ROOT/scripts/preflight-minimal.sh")"
echo "$PREFLIGHT_JSON" | jq -e '.profile == "minimal" and (.status == "ok" or .status == "warnings" or .status == "blocked")' >/dev/null \
  || fail "preflight-minimal did not return valid aggregate status"
ok "preflight-minimal aggregates OpenWrt facts"

TMPDIR="${TMPDIR:-/tmp}"
TEST_ROOT="$(mktemp -d "$TMPDIR/vpnkit-openwrt.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

ROUTER_ROOT="$TEST_ROOT/router-root"
"$ROOT/scripts/install-safety.sh" --root "$ROUTER_ROOT" --writer claude-code@openwrt-smoke >/tmp/vpnkit-install-safety.out
jq -e '.status == "ok"' /tmp/vpnkit-install-safety.out >/dev/null || fail "install-safety did not report ok"
[ -x "$ROUTER_ROOT/usr/lib/vpn-kit/staged-apply.sh" ] || fail "installed staged-apply missing"
[ -x "$ROUTER_ROOT/usr/sbin/vpn-kit-rollback" ] || fail "installed rollback wrapper missing"
[ -f "$ROUTER_ROOT/etc/vpn-kit/install-state.json" ] || fail "installed state missing"
ok "safety installer lays out runtime on OpenWrt"

env \
  VPN_KIT_STATE_FILE="$ROUTER_ROOT/etc/vpn-kit/install-state.json" \
  VPN_KIT_LOCK_DIR="$ROUTER_ROOT/var/lock" \
  "$ROOT/scripts/session-sync.sh" check-owned-files |
  jq -e '.status == "ok"' >/dev/null || fail "owned file check failed after install"
ok "session sync owned-file check is clean after install"

echo "# drift" >> "$ROUTER_ROOT/usr/lib/vpn-kit/vpn-kit-rollback.sh"
env \
  VPN_KIT_STATE_FILE="$ROUTER_ROOT/etc/vpn-kit/install-state.json" \
  VPN_KIT_LOCK_DIR="$ROUTER_ROOT/var/lock" \
  "$ROOT/scripts/session-sync.sh" check-owned-files |
  jq -e '.status == "drift"' >/dev/null || fail "owned file drift was not detected"
ok "session sync detects manual intervention drift"

rm -f "$ROUTER_ROOT/etc/vpn-kit/install-state.json"
"$ROOT/scripts/adopt-safety-state.sh" --root "$ROUTER_ROOT" --writer claude-code@openwrt-adopt >/tmp/vpnkit-adopt.out
jq -e '.status == "adopted"' /tmp/vpnkit-adopt.out >/dev/null || fail "adopt did not report adopted"
[ -f "$ROUTER_ROOT/etc/vpn-kit/install-state.json" ] || fail "adopted state missing"
ok "adopt reconstructs safety state on OpenWrt"

SAMPLE_VLESS='vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxyzABCDEFGH&sid=abcd&type=tcp&flow=xtls-rprx-vision#node'
"$ROOT/scripts/install-minimal.sh" --root "$ROUTER_ROOT" --activate --writer claude-code@openwrt-minimal --vless-url "$SAMPLE_VLESS" --node-name openwrt-node --port 4000 >/tmp/vpnkit-install-minimal.out
jq -e '.status == "ok" and .profile == "minimal" and .activated == 1' /tmp/vpnkit-install-minimal.out >/dev/null || fail "install-minimal did not report ok"
[ -s "$ROUTER_ROOT/etc/sing-box/config.json" ] || fail "minimal sing-box config missing"
[ -x "$ROUTER_ROOT/etc/init.d/sing-box-tproxy" ] || fail "minimal sing-box init missing"
[ -f "$ROUTER_ROOT/etc/vpn-kit/activation/minimal.commands.log" ] || fail "minimal activation plan missing"
jq -e '.proxy_ports[] | select(.port == 4000 and .type == "mixed")' "$ROUTER_ROOT/etc/vpn-kit/install-state.json" >/dev/null \
  || fail "minimal proxy port missing from state"
jq -e '.components["sing-box"].activated == true and .activation.mode == "rootfs-simulated"' "$ROUTER_ROOT/etc/vpn-kit/install-state.json" >/dev/null \
  || fail "minimal activation state missing"
ok "minimal installer lays out and activation-plans profile files on OpenWrt"

export VPN_KIT_STATE_FILE="$TEST_ROOT/etc/vpn-kit/install-state.json"
export VPN_KIT_JOURNAL_FILE="$TEST_ROOT/etc/vpn-kit/journal/events.jsonl"
export VPN_KIT_ROLLBACK_DIR="$TEST_ROOT/etc/vpn-kit/rollback.d"
export VPN_KIT_SNAPSHOT_DIR="$TEST_ROOT/etc/vpn-kit/snapshots"
export VPN_KIT_LOCK_DIR="$TEST_ROOT/var/lock"
export VPN_KIT_LOCK_TIMEOUT=2
export VPN_KIT_JOURNAL_MAX_BYTES=4096
export VPN_KIT_JOURNAL_ROTATE_KEEP=3

mkdir -p \
  "$(dirname "$VPN_KIT_STATE_FILE")" \
  "$(dirname "$VPN_KIT_JOURNAL_FILE")" \
  "$VPN_KIT_ROLLBACK_DIR" \
  "$VPN_KIT_SNAPSHOT_DIR" \
  "$VPN_KIT_LOCK_DIR"

write_state_payload() {
  cat <<'JSON'
{
  "version": 1,
  "installed_at": "2026-04-21T14:00:00Z",
  "skill_version": "0.1.0",
  "profile": "minimal",
  "router_identity": {"name": "openwrt-smoke", "openwrt_version": "24.10.0", "arch": "x86_64"},
  "committed_steps": [],
  "components": {},
  "files_owned_by_skill": []
}
JSON
}

write_state_payload | "$LIB/state-write.sh" --expected-revision 0 --writer claude-code@openwrt-smoke >/dev/null
rev="$("$LIB/state-read.sh" --revision)"
[ "$rev" = "1" ] || fail "initial state revision expected 1, got $rev"
ok "state CAS works on OpenWrt"

CONFIG="$TEST_ROOT/etc/config/sing-box"
mkdir -p "$(dirname "$CONFIG")"
echo "old" > "$CONFIG"
NEW_STATE="$TEST_ROOT/new-state.json"
write_state_payload > "$NEW_STATE"

new_rev="$("$LIB/staged-apply.sh" \
  --step-id openwrt-good \
  --expected-revision 1 \
  --writer claude-code@openwrt-smoke \
  --new-state "$NEW_STATE" \
  --snapshot-path "$CONFIG" \
  --apply "printf '%s\n' new > '$CONFIG'" \
  --verify "grep -q '^new$' '$CONFIG'" \
  --timeout-seconds 30)"

[ "$new_rev" = "2" ] || fail "staged apply revision expected 2, got $new_rev"
[ "$(cat "$CONFIG")" = "new" ] || fail "staged apply did not write config"
jq -e '(.committed_steps // []) | any(.step_id == "openwrt-good")' "$VPN_KIT_STATE_FILE" >/dev/null \
  || fail "committed step missing from state"
ok "staged apply commits on OpenWrt"

TIMER="$VPN_KIT_ROLLBACK_DIR/openwrt-good.timer"
[ -f "$TIMER" ] || fail "commit timer missing before daemon tick"
SNAPSHOT="$(jq -r '.snapshot_path' "$TIMER")"
"$LIB/vpn-kit-rollback.sh" --once
[ ! -f "$TIMER" ] || fail "daemon did not remove committed timer"
[ ! -d "$SNAPSHOT" ] || fail "snapshot-gc did not remove committed snapshot"
ok "rollback daemon recognizes committed state and GC cleans snapshot"

echo "old-again" > "$CONFIG"
write_state_payload > "$NEW_STATE"

if "$LIB/staged-apply.sh" \
  --step-id openwrt-bad \
  --expected-revision 2 \
  --writer claude-code@openwrt-smoke \
  --new-state "$NEW_STATE" \
  --snapshot-path "$CONFIG" \
  --apply "printf '%s\n' broken > '$CONFIG'" \
  --verify "grep -q '^new$' '$CONFIG'" \
  --timeout-seconds 1 >/tmp/vpnkit-openwrt-bad.out 2>/tmp/vpnkit-openwrt-bad.err; then
  fail "bad staged apply unexpectedly succeeded"
fi

[ "$(cat "$CONFIG")" = "old-again" ] || fail "failed verify did not restore config"
jq -e '(.committed_steps // []) | any(.step_id == "openwrt-bad") | not' "$VPN_KIT_STATE_FILE" >/dev/null \
  || fail "failed step was committed"
grep -q '"type":"staged_apply_rolled_back"' "$VPN_KIT_JOURNAL_FILE" \
  || fail "rollback event missing"
ok "failed verify rolls back on OpenWrt"

EXPIRED="$VPN_KIT_SNAPSHOT_DIR/openwrt-expired"
mkdir -p "$EXPIRED/files"
echo "expired-old" > "$CONFIG"
cp "$CONFIG" "$EXPIRED/files/0-config"
cp "$VPN_KIT_STATE_FILE" "$EXPIRED/state-before.json"
cat > "$EXPIRED/meta.json" <<JSON
{"step_id":"openwrt-expired","created_at":"2026-04-21T14:00:00Z","state_revision_before":2,"files":[{"path":"$CONFIG","backup":"files/0-config","existed":true}]}
JSON
echo "expired-new" > "$CONFIG"
cat > "$VPN_KIT_ROLLBACK_DIR/openwrt-expired.timer" <<JSON
{"step_id":"openwrt-expired","deadline_unix":0,"snapshot_path":"$EXPIRED","state_revision_before":2}
JSON
"$LIB/vpn-kit-rollback.sh" --once
[ "$(cat "$CONFIG")" = "expired-old" ] || fail "expired timer did not restore config"
[ -d "$VPN_KIT_SNAPSHOT_DIR/rolled-back/openwrt-expired" ] || fail "rolled-back snapshot missing"
ok "expired timer rolls back on OpenWrt"

echo "OpenWrt safety smoke tests passed"
