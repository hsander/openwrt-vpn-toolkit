# openwrt-skill smoke tests

Exercises the production `bin/*.sh` scripts against a real OpenWRT rootfs
running in a Docker container. Finds concrete bugs, doesn't patch them.

## How to run

```sh
bash tests/smoke/run-smoke.sh
```

First run builds the image (`openwrt-skill-smoke:latest`) and downloads ~20 MB
of apk packages. Subsequent runs reuse the build cache and the generated
keypair (`tests/smoke/.tmp/smoke_ed25519`).

Time budget: ~60-90s end-to-end on first run, ~25-40s warm.

### Tunables

| Env var | Default | Effect |
|---|---|---|
| `KEEP_CONTAINER=1` | unset | Leave the container running after the script exits, so you can `docker exec -it openwrt-skill-smoke sh`. |
| `IMAGE_TAG=...` | `openwrt-skill-smoke:latest` | Override the built image tag. |
| `SSH_PORT=...` | `2222` | Host port mapping for sshd. Useful if 2222 is busy. |
| `SCAFFOLD_SINGBOX_CONFIG=1` | unset | Pre-seed `/etc/sing-box/config.json` on the container so `add-domain.sh` can progress past the "no config" branch. |

## What it tests

| # | Script | Asserts |
|---|---|---|
| 1 | `bin/doctor.sh --json` | exit 0, JSON has `openwrt_version`, `arch`, `ram_mb>0`, `packages.jq=true`. |
| 2 | `bin/backup-now.sh` | exit 0, prints `snap-...` id, tarball + meta land in `/etc/vpn-kit/snapshots/`. |
| 3 | `bin/snapshot-list.sh --json` | exit 0, JSON array contains step-2 id. |
| 4 | `bin/add-domain.sh example.com` | non-zero exit (expected, no real sing-box config), no existing snapshot tarballs destroyed. |
| 5 | `bin/health.sh --json` | non-zero exit (no sing-box process), but stdout is valid JSON with `sing_box.running=false`. |
| 6 | `bin/restore.sh --snapshot <id-from-step-2>` | exit 0 or a clean error (2/13/20/30); no bash trace, no exit 127. |
| 7 | `bin/install-vpn.sh --dry-run` | exit 0 or a clean error (2/13/20). |

## What it does NOT test

The container is missing what only a real router / VM can provide:

- `nft`/`tproxy` rules -- the container has no `nftables` kernel module loaded
  and `tproxy` kmods cannot be loaded inside a stock Docker container.
- `kmod-nft-tproxy`, `kmod-nft-queue` install -- the snapshot kmod feed is
  pinned to the rootfs's specific kernel hash; apk has no matching kmod
  packages because the container reuses the host kernel.
- DNS chain (`dnsmasq` -> `https-dns-proxy` -> upstream DoH) end-to-end -- the
  container has no `dnsmasq`/`https-dns-proxy` running and `uci` only has
  stubs.
- Real VLESS Reality connection (`install-vpn.sh` without `--dry-run`,
  `bin/health.sh` SOCKS exit IP path).
- Hot reload of a running `sing-box-tproxy` init.d service.

For those you need a QEMU VM build (see `tests/legacy/with-openwrt-qemu.sh`
which used to drive a full OpenWRT VM). That path is slower and out of scope
for this smoke.

## How to debug

```sh
# Keep the container alive after smoke exits.
KEEP_CONTAINER=1 bash tests/smoke/run-smoke.sh

# Get a shell inside the container.
docker exec -it openwrt-skill-smoke sh

# Or ssh in directly using the smoke keypair.
ssh -i tests/smoke/.tmp/smoke_ed25519 \
    -o UserKnownHostsFile=tests/smoke/.tmp/known_hosts \
    -o StrictHostKeyChecking=no \
    -p 2222 root@127.0.0.1

# Stop / clean up.
docker stop openwrt-skill-smoke
```

Useful container paths:

- `/etc/vpn-kit/snapshots/` -- tarballs + meta.json from `backup-now.sh`.
- `/etc/sing-box/` -- created if `SCAFFOLD_SINGBOX_CONFIG=1` or after a real install.
- `/etc/openwrt_release` -- container reports `DISTRIB_RELEASE='SNAPSHOT'`, so
  `doctor.sh` row 3 ("OpenWRT 24.10+") will always be FAIL inside the smoke.

## Layout

```
tests/smoke/
├── Dockerfile.openwrt-sshd   # rootfs + sshd + tools image
├── README.md                 # this file
├── run-smoke.sh              # orchestrator
└── .tmp/                     # generated keypair, sandboxed memory, logs (gitignored)
    ├── smoke_ed25519{,.pub}
    ├── known_hosts
    ├── memory/               # OPENWRT_SKILL_MEMORY override
    │   ├── routers.yaml
    │   └── _templates/
    ├── run.log               # docker build/run output
    └── *.err / *.out / *.json  # per-step artefacts
```
