# openwrt-skill

**AI-powered OpenWrt router management** — configure VPN and routing, migrate a
LAN safely, or build a travel router that joins hotel Wi-Fi while preserving
private Wi-Fi and access to your home network.

> [Документация на русском →](./README.ru.md)

---

## What it does

You open this project in Claude Code and simply say:

> *"Set up VPN on my router"*  
> *"YouTube stopped working, fix it"*  
> *"Route my TV through the US server"*  
> *"Add Instagram to the bypass list"*
> *"Turn my router into a travel router and connect it to my phone hotspot"*

Claude handles everything: connects to the router over SSH, makes a backup, applies the change safely, and rolls back automatically if something goes wrong.

---

## Who is this for

- People in countries with internet censorship (Russia, Iran, China, Belarus, UAE, ...)
- Anyone who wants **YouTube, Instagram, Telegram, Twitter** to just work
- People who want a **VPN on the router level** — so every device at home is covered without installing anything
- Travellers who want one trusted private Wi-Fi network in hotels and remote access to their home LAN
- Developers and sysadmins who manage OpenWrt routers and want AI automation

**No networking knowledge required.** You don't need to know what sing-box, VLESS, Reality, tproxy, or nftables are. Claude knows.

---

## What you need

| | |
|---|---|
| Router | OpenWrt 23.05+ (tested on 24.10 / 25.x) |
| VPN (optional) | A VLESS/Reality server for policy routing; an existing AWG2 endpoint for home-to-travel access |
| Agent machine | macOS or Linux with Claude Code installed |
| Claude | Claude Code CLI ([claude.ai/code](https://claude.ai/code)) |

---

## What works out of the box

| Goal | What Claude does |
|------|-----------------|
| YouTube / Instagram / Twitter / Telegram unblocked | Routes those domains through VPN automatically |
| Full router VPN (all devices covered) | Installs sing-box with tproxy — every device on Wi-Fi uses VPN |
| Pin one device to a specific server | e.g. your TV always goes through the US server |
| Multiple VPN servers with auto-failover | If one server is down, traffic switches to the next one instantly |
| LAN proxy (manual per-app VPN) | HTTP/SOCKS5 proxy port for apps that support it |
| Telegram watchdog alerts | Get notified if the router loses internet or VPN breaks |
| Safe config changes with auto-rollback | Every change is snapshotted; if SSH drops after a restart, it rolls back |
| Add/remove domains from VPN list | Without restarting sing-box |
| Travel router profile | Creates an uncommon private LAN, dual-band private AP, Travelmate uplinks, and persistent LuCI access |
| Join hotel Wi-Fi from a phone/tablet | Add or change the external Wi-Fi in LuCI without a laptop |
| Hidden private Wi-Fi with physical recovery | A short Wireless Pairing press exposes MobileHub for 10 minutes; press again to hide it now |
| Home ↔ travel access over AWG2 | Routes only the home LAN through the tunnel; ordinary internet stays on the local uplink |
| Resilient home-LAN access for travel routers (pilot) | Keeps direct AWG primary and can fail private routes over a separate AWG relay on VPS UDP/443 |
| Guarded scheduled reboot | Installs one daily reboot job without replacing unrelated cron entries; skips reboot when time is unsynchronised or uptime is under one hour |
| Safe LAN subnet migration | Uses prepare/cutover/confirm/rollback with recovery endpoints instead of a one-shot address change |

The safe API starts after OpenWrt is installed. Flashing vendor firmware,
bootloader recovery, and model-specific rescue procedures are not yet automated
and must not be inferred from the travel-router workflow.

---

## Travel router: connect to a new Wi-Fi

1. Power on the router. If MobileHub is hidden, briefly press the physical
   `Wireless Pairing` button: both bands become visible for 10 minutes.
2. Connect your phone/tablet to MobileHub, then open LuCI at the travel address
   configured for your router (or HTTPS if it was configured explicitly).
3. Open `Services -> Travelmate`, scan, choose the hotel or hotspot SSID, enter
   its password, and select `Save & Apply`.
4. If the hotel has a captive portal, remain on the private Wi-Fi and open a
   plain HTTP page such as `http://neverssl.com` to complete the login.
5. Open a normal website. The saved uplink will reconnect automatically after
   reboot while access to the home LAN continues through AWG2.

If MobileHub is already visible, another short Wireless Pairing press hides both
bands immediately. A hidden SSID is only a convenience/visibility feature, not
a security boundary; WPA2 and its password remain the actual protection.

Use 2.4 GHz for range and 5 GHz for speed. Unknown open networks are never added
automatically. Full setup and verification procedure:
[`12-travel-router.md`](./.claude/skills/openwrt/runbooks/12-travel-router.md).

## Resilient travel routing (pilot)

The optional resilient workflow keeps the existing direct AWG path as primary
and adds a separate AWG relay through a trusted Ubuntu VPS on **UDP/443**. It
fails over only the configured private home/travel LAN routes; it never gives
the backup AWG client `0.0.0.0/0` and never replaces the router's default
internet route. Existing VLESS/Xray on **TCP/443** remains a separate service.

The pilot has a fixed startup order: connect to the home router through the
direct AmneziaWG2 interface first; if that path is unavailable, try the backup
interface through a configured VPS relay on UDP/443. Ordinary internet stays on
the current uplink and is never moved through the VPS. After recovery, the route
returns to the direct link. Configure additional travel routers only after the
first pilot passes.

Faster failover startup requires a separate measured change: early `awg2`
readiness checks after `ifup`, shorter probe/keepalive intervals, removal of a
stale `awg1` route, and the existing hysteresis protection against flapping.
Those optimizations are not enabled yet.

Use this workflow only after the ordinary travel profile and direct AWG link
are verified. The safe sequence is VPS audit → relay hub → router clients and
VPS peers → route watchdogs on both ends → handshake, MTU, route, internet/DNS,
memory, reboot, outage, and recovery tests. Every mutating step creates a
snapshot or prints its rollback command. Removing a live VPS peer may require a
planned VPS reboot because the workflow deliberately avoids unsafe live DKMS
peer/interface teardown.

A VLESS reserve can provide backup internet, but it does **not** prove access to
the home LAN when UDP is blocked. Private keys, VLESS URLs/UUIDs, Reality keys,
and passwords must never be written to the repository, logs, or memory files.
The current implementation is contract-tested but remains a pilot until the
full physical/VPS acceptance matrix is completed. See
[`13-resilient-travel-failover.md`](./.claude/skills/openwrt/runbooks/13-resilient-travel-failover.md).

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/your-org/openwrt-skill
cd openwrt-skill

# 2. Install dependencies (macOS)
brew install jq yq openssh

# 3. Add your router
cp .claude/skills/openwrt/memory/routers.yaml.example \
   .claude/skills/openwrt/memory/routers.yaml
# Edit routers.yaml: set alias, host IP, ssh user

# 4. Open in Claude Code
claude .

# 5. Say what you want
# >>> set up VPN on my home router
# >>> add youtube.com to the bypass list
# >>> check why Instagram is not working
```

---

## How it works (for the curious)

```
You (chat) → Claude → bin/*.sh scripts → SSH → OpenWrt router
                           ↓
                    snapshot before change
                    validate config
                    staged apply
                    reachability check → auto-rollback if SSH drops
                    update local memory files
```

Routine operations go through scripts in `bin/` that perform backup, validation,
apply, verification, and memory updates. Direct SSH is available only through the
audited `raw-ssh.sh` escape hatch after explicit user confirmation. If the router
becomes unreachable after a staged restart, the previous snapshot is restored.

The VPN stack:
- **sing-box** (VLESS + Reality) — the actual VPN tunnel
- **tproxy + nftables** — intercepts traffic at the router level, no client config needed
- **sing-box FakeIP DNS** — routes domains to VPN without leaking DNS queries
- **zapret** (optional) — deep packet inspection bypass for extra stubborn blocks

The travel stack:
- **Travelmate + LuCI** — select and remember hotel/hotspot uplinks from a phone or tablet
- **Permanent private AP** — client devices keep using one trusted SSID
- **AmneziaWG 2 site-to-site** — management and home-LAN access over a separate tunnel
- **Split routing** — only home-LAN traffic uses AWG2; ordinary internet uses the local uplink
- **Optional resilient AWG relay** — hysteretic private-route failover through a VPS on UDP/443, without changing the default route
- **Guarded daily reboot** — preserves unrelated cron jobs and refuses unsafe early/unsynchronised reboot

---

## Security

- SSH key is generated per-router (`~/.ssh/openwrt_<alias>_ed25519`), never reused
- VPN secrets (UUID, private keys) stay **only on the router** — never written to chat, memory files, or logs
- Snapshots stored on the router in `/etc/vpn-kit/snapshots/` (chmod 700, root only)
- `memory/routers.yaml` is gitignored — your router IPs never end up in the repo

**If your laptop is stolen:** change your VPN keys, rotate the Telegram bot token, remove the SSH key from each router's `authorized_keys`. See [README.ru.md](./README.ru.md#если-ноутбук-украли) for the full checklist.

### Commit-time privacy guard

This repository includes a versioned pre-commit hook that scans **staged added
lines** for known project-specific infrastructure markers and secret-shaped
values (private keys, bot tokens, and complete `vless://` URLs). Enable it once
after cloning:

```bash
git config core.hooksPath .githooks
```

The hook is a safety net, not a replacement for review. Replace real router
aliases, endpoints, SSIDs, usernames, UUIDs, and keys with placeholders before
staging public documentation. Run the checker manually with
`.claude/skills/openwrt/bin/check-public-data.sh --staged`.

---

## Project layout

```
.claude/skills/openwrt/
├── SKILL.md          # Claude's instructions — what to call when
├── bin/              # Safe API: atomic operations (Claude calls only these)
│   ├── doctor.sh     # 20-point health check → state.md
│   ├── setup-ssh.sh  # First-time SSH key setup
│   ├── install-vpn.sh# Full VPN bootstrap (parses vless://)
│   ├── add-domain.sh # Add domain to VPN bypass list
│   ├── set-rule-set-outbound.sh # Move existing service rule_set to another outbound
│   ├── add-vpn.sh    # Add VPN server node
│   ├── pin-device.sh # Pin LAN device to specific server
│   ├── add-ip.sh     # Add IP subnet route
│   ├── backup-now.sh # Manual snapshot
│   ├── restore.sh    # Rollback to snapshot
│   ├── install-travelmate.sh       # Install Travelmate and its LuCI application
│   ├── configure-travel-router.sh  # Private AP, unique LAN and split route
│   ├── configure-home-travel-route.sh # Reverse route on the home router
│   ├── verify-travel-router.sh     # End-to-end and post-reboot proof
│   ├── configure-scheduled-reboot.sh # Guarded daily reboot without replacing cron
│   ├── install-vps-awg-hub.sh      # Isolated AWG relay on VPS UDP/443
│   ├── install-awg-route-failover.sh # Private-route failover/failback watchdog
│   ├── verify-resilient-awg.sh     # Secret-free relay, route, MTU and resource proof
│   └── ...
├── lib/              # Shared helpers (sourced by bin/, not called directly)
├── memory/           # Per-router state: routers.yaml + <alias>/*.md
├── runbooks/         # Step-by-step guides for each scenario
└── templates/        # sing-box config templates
```

---

## Related

- [sing-box](https://sing-box.sagernet.org/) — the VPN core
- [OpenWrt](https://openwrt.org/) — the router OS
- [Claude Code](https://claude.ai/code) — the AI agent that drives this skill
- [zapret](https://github.com/bol-van/zapret) — DPI bypass for Russia and similar networks

---

## License

MIT
