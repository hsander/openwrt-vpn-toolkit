# Tests

Unit tests for `lib/*.sh` (Срез A + Stage 0 safety helpers + first minimal-profile
installer/activation).

## Requirements (macOS)

```
brew install jq yq bats-core flock
```

- `jq` — JSON manipulation (already in the OpenWrt busybox target, just needs `jq` pkg)
- `yq` — YAML ↔ JSON bridge used by `quirks-update.sh`
- `bats-core` — test runner
- `flock` — advisory locking (absent on stock macOS; OpenWrt busybox has it). `lib/vpn-kit-common.sh` falls back to a mkdir-based lock if `flock` is not found, so tests still run without it — install it only if you want to exercise the production path.

## Running

```
cd openwrt-vpn-kit
bats tests/*.bats
```

Each test gets a fresh `$TEST_TMPDIR` via `setup_test_env` in `helpers.bash`, so runs are isolated.

OpenWrt rootfs smoke:

```
tests/run-openwrt-container-tests.sh
```

The runner uses `openwrt/rootfs:x86-64` by default and installs `jq` inside the
temporary container if needed.

OpenWrt QEMU SSH-loss fault test, against an already running VM:

```
OPENWRT_SSH_KEY=/tmp/openwrt-vpn-kit-vm/id_ed25519 \
OPENWRT_SSH_PORT=2299 \
tests/run-openwrt-qemu-ssh-fault-test.sh
```

This copies the skill to the VM, installs the safety runtime, intentionally
breaks SSH by moving `/usr/sbin/dropbear`, and verifies that the rollback timer
restores SSH access. By default the runner powers off the VM at exit; set
`OPENWRT_POWEROFF_AFTER_TEST=0` only for manual debugging.

OpenWrt QEMU minimal activation dry-run, against an already running VM:

```
OPENWRT_SSH_KEY=/tmp/openwrt-vpn-kit-vm/id_ed25519 \
OPENWRT_SSH_PORT=2299 \
tests/run-openwrt-qemu-minimal-dry-test.sh
```

OpenWrt QEMU minimal live activation e2e, with automatic VM start/stop:

```
tests/with-openwrt-qemu.sh tests/run-openwrt-qemu-minimal-live-test.sh
```

This installs packages in the VM, activates `sing-box-tproxy`, applies the LAN
proxy firewall rule, verifies HTTP traffic through `127.0.0.1:4000`, then injects
a broken `sing-box` config and verifies staged rollback.

For the x86 OpenWrt image used here, start QEMU with user networking in the LAN
subnet and a virtio RNG device:

```
qemu-system-x86_64 -m 256 -smp 1 -nographic \
  -drive file=/tmp/openwrt-vpn-kit-vm/openwrt.img,format=raw,if=virtio \
  -netdev user,id=net0,net=192.168.1.0/24,host=192.168.1.2,hostfwd=tcp:127.0.0.1:2299-192.168.1.1:22 \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci
```

Without `net=192.168.1.0/24`, QEMU user-mode host forwarding targets the wrong
guest address for this image. Without `virtio-rng-pci`, dropbear may wait for
kernel randomness and SSH can hang during banner exchange.

## What is covered (Срез A scope)

- `state-read.sh` / `state-write.sh` — CAS contract: 0 / 11 STALE / 12 LOCK / 13 VALIDATION, CAS field enforcement (caller cannot poison `_revision`/`_last_writer`).
- `notes-read.sh` / `notes-write.sh` — frontmatter revision CAS, `append-section` / `update-section` / `full-overwrite` modes, secret filter.
- `quirks-update.sh` — YAML-backed CAS with `set` / `set-json` / `unset` / `init`, numeric/bool type inference, secret filter.
- `journal-append.sh` — append-only JSONL with rotation, secret filter, `kv` / `--json` / `--stdin` input modes, locking.
- `preflight-safety.sh`, `staged-apply.sh`, `vpn-kit-rollback.sh`, `rollback-snapshot.sh`, `snapshot-gc.sh`, `reachability-check.sh` — Stage 0 safety contract: preflight, snapshot, rollback timer, commit detection, failed-verify rollback, committed-snapshot GC.
- `detect-system.sh`, `detect-lan.sh`, `check-conflicts.sh`, `preflight-minimal.sh` — profile preflight: OpenWrt facts, UCI-derived LAN info, conflict detection and aggregate install gating.
- `render-minimal-config.sh`, `install-minimal.sh` — first `minimal` install layer: VLESS Reality URL parsing, `sing-box` config rendering, init/watchdog/firewall/dns file layout, state ownership/checksum recording, `--activate` command-plan/state dry-run, and QEMU live activation through a test-only direct outbound.

## What is NOT covered here (future срезы)

- Multi-writer contention under real concurrency on a target that supports timeout-capable `flock`; OpenWrt BusyBox `flock` falls back to mkdir-lock in current code.
- Firewall/DNS-specific QEMU fault injection. Current QEMU coverage verifies SSH
  loss/recovery through `dropbear` binary removal and rollback timer restore.
- Real VPN-node traffic: QEMU live coverage uses `--test-direct-outbound` so it
  does not need real VLESS credentials. A future test still needs a controlled
  VLESS Reality node.
- zapret/DNS live activation: no test yet installs zapret packages/assets or
  validates the final DNS chain.
