# tests/qemu-smoke — real-VLESS end-to-end QEMU runner

Spin up a real OpenWRT aarch64 VM under QEMU+HVF on macOS (Apple Silicon),
run the full `bin/*` flow against it, and confirm a real VLESS Reality VPN
handshake by routing traffic through a SOCKS5 proxy and checking that the
exit IP is **not** the host's IP.

This is the highest-fidelity test in the repo — it exercises the same install
path a real router would go through (apk install sing-box, render config from
a real Reality URL, start `sing-box-tproxy`, accept SOCKS5 traffic).

## Quick start

```bash
# First run downloads ~25MB of OpenWRT artifacts into ~/.openwrt-skill/cache/
# and prepares the rootfs image. Subsequent runs reuse the cache.
bash tests/qemu-smoke/run-e2e.sh

# Leave the VM running for poking around afterwards:
KEEP_VM=1 bash tests/qemu-smoke/run-e2e.sh
# (use the printed `ssh -i ... -p 2299 root@127.0.0.1` line to attach)
```

## Prerequisites

| tool                    | install                              |
|-------------------------|--------------------------------------|
| `qemu-system-aarch64`   | `brew install qemu` (≥ v8)           |
| HVF accelerator         | macOS, Apple Silicon, default ON     |
| Docker Desktop          | https://www.docker.com               |
| `jq`, `yq`, `curl`      | `brew install jq yq curl`            |

`qemu-system-aarch64 -accel help` must list `hvf`. TCG fallback is refused;
boots take 5+ minutes under TCG which is unusable.

## What gets tested

1. **doctor.sh (pre-install)** — JSON probe of a clean VM. Expects
   `packages.sing-box == false`.
2. **backup-now.sh** — captures the pre-VPN baseline as a snapshot.
3. **install-vpn.sh** — the big one. Installs `sing-box` + DNS chain +
   `/etc/init.d/sing-box-tproxy` and renders `/etc/sing-box/config.json`
   from a real Reality URL. Verifies via doctor JSON
   (`config.valid == true`, `outbound_count >= 2`) and `health.sh`
   (`sing_box.running == true`).
4. **Real VPN traffic test**:
   ```
   curl --proxy socks5h://127.0.0.1:14000 https://api.ipify.org
   ```
   The QEMU `hostfwd` forwards host:14000 → guest:4000, where sing-box's
   mixed inbound is bound. Traffic exits via the VLESS Reality outbound.
   The returned IP must differ from the host's own IP (geoip lookup
   confirms PL when the provider hasn't rotated).
5. **add-domain.sh** — adds `api.ipify.org` to the rule_set; re-tests SOCKS.
6. **remove-domain.sh** — removes the rule; re-tests SOCKS.
7. **restore.sh** — restores the pre-install snapshot. Spec-accepted exit
   codes are `0` (clean restore) or `20` (safety rollback fired because the
   restored config invalidates sing-box check; restore.sh's auto-rollback to
   the current safety state is the correct safety behaviour).

## Files

| script                | what it does                                                   |
|-----------------------|----------------------------------------------------------------|
| `prepare-image.sh`    | downloads OpenWRT 24.10.6 armsr/armv8 ext4 rootfs + kernel,    |
|                       | injects SSH key + uci-defaults via `debugfs` (Docker)          |
| `boot-vm.sh`          | launches `qemu-system-aarch64 -accel hvf` w/ hostfwd, waits SSH |
| `run-e2e.sh`          | orchestrates all of the above, runs the 7 test steps           |

## Image preparation: why Docker for debugfs?

macOS cannot natively mount ext4 read-write. We use a tiny Alpine container
with `e2fsprogs-extra` (which ships `debugfs`) to write into the rootfs
image **without** mounting it. The container only runs for a few seconds at
prep time; once the prepared image is cached in
`~/.openwrt-skill/cache/qemu-aarch64/rootfs.ext4.prepared.img`, no further
Docker work is needed for subsequent runs.

Alternatives considered:
- **initramfs-kernel.bin** (single-file kernel+rootfs): can't easily inject
  a key file because it's a ramdisk baked at build time.
- **guestfish/libguestfs**: heavy (200MB+ container), slow.
- **genext2fs**: works but rebuilds the whole FS from a tar — more steps,
  more drift from upstream's exact layout.

## Networking layout

QEMU user-mode networking with `net=192.168.1.0/24,host=192.168.1.2`:

- Guest gets `192.168.1.1` on `br-lan` via uci-defaults — matches
  `install-vpn.sh`'s hard-coded `--listen 192.168.1.1` (see "Known caveats").
- QEMU gateway `192.168.1.2` does NAT to the host's real interface.
- `hostfwd=tcp:127.0.0.1:2299-:22` exposes guest sshd.
- `hostfwd=tcp:127.0.0.1:14000-:4000` exposes the sing-box SOCKS5 inbound.

## Caveats and reproducibility notes

- **OpenWRT version is pinned** to 24.10.6 in `prepare-image.sh` with SHA256
  hashes verified against `downloads.openwrt.org/.../sha256sums`. Bump both
  the version string and hashes together.
- **`apk` feed** is fetched live from the OpenWRT mirror at install time
  (inside install-minimal.sh, on the VM). The exact `sing-box` package
  version is whatever 24.10.6's feed currently serves. If sing-box's package
  version drifts, the `config.valid` check may need adjusting.
- **VPN dependency**: step 4 exercises a real Reality handshake. It needs:
  - Internet from your Mac (the VM uses user-mode NAT, so host internet is
    required).
  - The VPN server in `~/.openwrt-skill/secrets/qemu-test.url` to be up.
  - If step 4 fails with a network error, first sanity-check the server
    (e.g. `ping <ip>`) and the URL file.
- **VLESS URL handling**: the URL is read into a shell-local variable in
  `run-e2e.sh`, passed via `--url "$URL"` to `install-vpn.sh`, then unset.
  It is never echoed, never logged, never copied to a file by the runner.
- **First-run downloads** ~25 MB and decompresses the rootfs (+256 MB
  padding for apk headroom) → cached prepared image is ~360 MB. Re-runs
  reuse `rootfs.ext4.prepared.img`.

## Debugging a failed run

```bash
# Keep the VM up after a failed run:
KEEP_VM=1 bash tests/qemu-smoke/run-e2e.sh

# SSH in:
ssh -i ~/.openwrt-skill/cache/qemu-aarch64/id_ed25519 -p 2299 \
    -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    root@127.0.0.1

# Inspect logs:
ls tests/qemu-smoke/.tmp/   # qemu.log, run.log, *.err, doctor-*.json
tail -200 tests/qemu-smoke/.tmp/qemu.log

# Stop the VM:
kill "$(cat tests/qemu-smoke/.tmp/qemu.pid)"

# Nuke the cached image (next run re-downloads):
rm -rf ~/.openwrt-skill/cache/qemu-aarch64/
```
