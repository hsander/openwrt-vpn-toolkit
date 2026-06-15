# tests/qemu-docker — QEMU-in-Docker e2e runner

End-to-end test runner for `openwrt-skill`. Boots a real OpenWRT VM inside a
Linux Docker container (so we get native ext4 mount + edit on macOS), then
drives the full `bin/*` flow against it, including a real VLESS Reality VPN
handshake.

## Why a container?

The prior native `qemu-system-aarch64 + HVF` runner couldn't inject an SSH key
into the OpenWRT ext4 rootfs from macOS (no native ext4 r/w). The pivot puts
QEMU itself inside a Debian container: the container's Linux kernel mounts
ext4 trivially, then runs QEMU in TCG mode. Trade-off: ~1–3 min first boot
instead of ~20 s with HVF — but it works reliably without OS gymnastics.

## How to run

```sh
# 1. Place the secret VLESS URL (chmod 600, one line) at:
#    ~/.openwrt-skill/secrets/qemu-test.url

# 2. Run the orchestrator.
bash tests/qemu-docker/run-e2e.sh
```

Knobs:

| env var               | default                          | purpose                       |
| --------------------- | -------------------------------- | ----------------------------- |
| `KEEP_VM=1`           | off                              | leave container running       |
| `IMAGE_ONLY=1`        | off                              | just build the docker image   |
| `SSH_PORT`            | `2299`                           | host port -> guest 22         |
| `PROXY_HOST_PORT`     | `14000`                          | host port -> guest 4000       |
| `PROXY_GUEST_PORT`    | `4000`                           | sing-box mixed inbound port   |
| `BOOT_TIMEOUT`        | `300` s                          | wait for sshd                 |
| `URL_FILE`            | `~/.openwrt-skill/secrets/...`   | VLESS URL secret path         |
| `IMAGE_TAG`           | `openwrt-skill-qemu:latest`      | docker tag                    |

## Expected duration

| run               | wall clock                               |
| ----------------- | ---------------------------------------- |
| first run         | ~5 min (apt + ~5–15 MB OpenWRT download + first TCG boot) |
| subsequent runs   | ~2–3 min (Docker layers cached, image cached in `.tmp/`)  |

## What it covers

- `bin/doctor.sh` against a clean OpenWRT 24.10.6 VM
- `bin/backup-now.sh` snapshot capture
- `bin/install-vpn.sh` with a **real** VLESS Reality URL (apk install of
  sing-box, render config, start service)
- `bin/health.sh` post-install
- Real outbound VPN traffic via SOCKS5: fetches `api.ipify.org` through
  the proxy, prints host IP vs VPN IP vs country
- `bin/add-domain.sh` + re-test
- `bin/remove-domain.sh` + re-test (FakeIP-cache caveat)
- `bin/restore.sh` of the pre-install snapshot — expects exit 20 (safety
  rollback fires; documented behavior)

## What it does NOT cover

- `zapret2` bootstrap (no equivalent on x86_64 generic; would need
  build-with-zapret2 OpenWRT or custom kmod)
- Multi-router scenarios
- Persistent reboot-then-recheck cycle
- Wireguard / OpenVPN paths (only VLESS Reality is exercised here)

## Debugging

```sh
# Keep the container alive after the test exits:
KEEP_VM=1 bash tests/qemu-docker/run-e2e.sh

# Then poke around:
docker exec -it openwrt-skill-qemu bash      # container shell
docker logs -f openwrt-skill-qemu             # serial console of the VM
ssh -i tests/qemu-docker/.tmp/id_ed25519 -p 2299 root@127.0.0.1   # straight into VM

# Stop when done:
docker stop openwrt-skill-qemu
```

If the image-prep stage fails (`losetup -fP` errors), the container needs
`--privileged` — Docker Desktop on macOS doesn't expose `/dev/loop-control`
cleanly via `--device`, and the run script already passes `--privileged`. If
you somehow strip that, re-add it.

## Pinned upstream

- OpenWRT **24.10.6**, target `x86/64`, image
  `openwrt-24.10.6-x86-64-generic-ext4-combined.img.gz`
- SHA256
  `23dc6904ede514e37e9938604c9951a0601c375efdaf093c0d191d12e463f9b2`
  (verified against the official `sha256sums` index).

Bump together in `Dockerfile` (the `ARG OPENWRT_VERSION` / `OPENWRT_IMG_URL`
/ `OPENWRT_IMG_SHA256` block) and re-build.

## Layout

```
tests/qemu-docker/
├── Dockerfile          # debian:bookworm-slim + qemu + pre-downloaded OpenWRT img
├── entrypoint.sh       # container PID 1: mount, inject key, run QEMU
├── run-e2e.sh          # host orchestrator (this is what you call)
├── README.md           # ← you are here
└── .tmp/               # gitignored: ssh key, decompressed image, logs
```
