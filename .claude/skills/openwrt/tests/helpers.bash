# Shared helpers for bats tests.
# Sets up isolated env under a per-test tmpdir.

setup_test_env() {
  TEST_TMPDIR="$(mktemp -d -t vpnkit-bats.XXXXXX)"
  export TEST_TMPDIR
  export VPN_KIT_STATE_FILE="$TEST_TMPDIR/install-state.json"
  export VPN_KIT_NOTES_FILE="$TEST_TMPDIR/router-notes.md"
  export VPN_KIT_QUIRKS_FILE="$TEST_TMPDIR/learned-quirks.yaml"
  export VPN_KIT_JOURNAL_FILE="$TEST_TMPDIR/events.jsonl"
  export VPN_KIT_ROLLBACK_DIR="$TEST_TMPDIR/rollback.d"
  export VPN_KIT_SNAPSHOT_DIR="$TEST_TMPDIR/snapshots"
  export VPN_KIT_LOCK_DIR="$TEST_TMPDIR/lock"
  export VPN_KIT_LOCK_TIMEOUT=2
  export VPN_KIT_JOURNAL_MAX_BYTES=1024      # small for rotation test
  export VPN_KIT_JOURNAL_ROTATE_KEEP=3
  mkdir -p "$VPN_KIT_LOCK_DIR" "$VPN_KIT_ROLLBACK_DIR" "$VPN_KIT_SNAPSHOT_DIR"

  # Path to the project lib/
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SKILL_DIR
  export LIB="$SKILL_DIR/lib"
}

write_minimal_state() {
  cat <<'JSON' | "$LIB/state-write.sh" --expected-revision 0 --writer claude-code@test >/dev/null
{
  "version": 1,
  "installed_at": "2026-04-21T14:00:00Z",
  "skill_version": "0.1.0",
  "profile": "minimal",
  "router_identity": {"name": "test", "openwrt_version": "24.10.0", "arch": "aarch64"},
  "committed_steps": [],
  "components": {},
  "files_owned_by_skill": []
}
JSON
}

minimal_state_payload() {
  cat <<'JSON'
{
  "version": 1,
  "installed_at": "2026-04-21T14:00:00Z",
  "skill_version": "0.1.0",
  "profile": "minimal",
  "router_identity": {"name": "test", "openwrt_version": "24.10.0", "arch": "aarch64"},
  "committed_steps": [],
  "components": {},
  "files_owned_by_skill": []
}
JSON
}

setup_fake_openwrt_bin() {
  FAKE_BIN="$TEST_TMPDIR/fake-bin"
  export FAKE_BIN
  mkdir -p "$FAKE_BIN"

  cat > "$FAKE_BIN/jq" <<SH
#!/bin/sh
exec "$(command -v jq)" "\$@"
SH
  cat > "$FAKE_BIN/awk" <<SH
#!/bin/sh
exec "$(command -v awk)" "\$@"
SH
  cat > "$FAKE_BIN/sed" <<SH
#!/bin/sh
exec "$(command -v sed)" "\$@"
SH
  cat > "$FAKE_BIN/grep" <<SH
#!/bin/sh
exec "$(command -v grep)" "\$@"
SH
  cat > "$FAKE_BIN/head" <<SH
#!/bin/sh
exec "$(command -v head)" "\$@"
SH
  cat > "$FAKE_BIN/sort" <<SH
#!/bin/sh
exec "$(command -v sort)" "\$@"
SH
  cat > "$FAKE_BIN/tr" <<SH
#!/bin/sh
exec "$(command -v tr)" "\$@"
SH
  cat > "$FAKE_BIN/df" <<'SH'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "/dev/root 32768 20480 12288 63% /"
SH
  cat > "$FAKE_BIN/uname" <<'SH'
#!/bin/sh
echo x86_64
SH
  cat > "$FAKE_BIN/procd" <<'SH'
#!/bin/sh
exit 0
SH
  cat > "$FAKE_BIN/start-stop-daemon" <<'SH'
#!/bin/sh
exit 0
SH
  cat > "$FAKE_BIN/apk" <<'SH'
#!/bin/sh
exit 0
SH
  cat > "$FAKE_BIN/nft" <<'SH'
#!/bin/sh
exit 0
SH
  cat > "$FAKE_BIN/ip" <<'SH'
#!/bin/sh
if [ "$1" = "-4" ]; then
  echo "3: br-lan    inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan"
fi
SH
  cat > "$FAKE_BIN/uci" <<'SH'
#!/bin/sh
if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "wireless" ]; then
  echo "wireless.radio0=wifi-device"
  echo "wireless.radio0.type='mac80211'"
  echo "wireless.radio1=wifi-device"
  echo "wireless.radio1.type='mac80211'"
  exit 0
fi
if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "firewall" ]; then
  echo "firewall.@zone[0]=zone"
  echo "firewall.@zone[0].name='lan'"
  echo "firewall.@zone[0].network='lan'"
  echo "firewall.@zone[1]=zone"
  echo "firewall.@zone[1].name='wan'"
  echo "firewall.@zone[1].network='wan wan6'"
  exit 0
fi
if [ "$1" = "-q" ] && [ "$2" = "get" ]; then
  case "$3" in
    network.lan.device) echo "br-lan"; exit 0 ;;
    network.lan.ifname) echo "eth0"; exit 0 ;;
    network.lan.ipaddr) echo "192.168.1.1"; exit 0 ;;
    network.lan.netmask) echo "255.255.255.0"; exit 0 ;;
  esac
fi
exit 1
SH
  chmod +x "$FAKE_BIN"/*
}

teardown_test_env() {
  if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}
