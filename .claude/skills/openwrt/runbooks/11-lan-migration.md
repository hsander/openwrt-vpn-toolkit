# LAN migration with autonomous rollback

## Workflow map

- Transaction model and invariants: `Lifecycle` below.
- First move to the new LAN: `Home migration launch sequence`.
- Home-server gateway/DNS transaction: `Home-server transaction`.
- Removal of the compatibility subnet: `Final legacy-subnet cleanup`.
- Recovery-only/internal commands: `Internal helpers`.

Use `bin/migrate-lan.sh` only with a reviewed, pre-rendered bundle. `prepare`
uploads and validates the bundle, snapshots every target and prints the exact
recovery commands. It does not change network state.

The bundle layout is:

```text
manifest.json
files/<candidate files>
scripts/apply.sh
scripts/verify.sh
scripts/rollback.sh
```

`manifest.json` schema version 1 contains a migration ID and an allowlist of
absolute target paths, relative staged paths, SHA-256 values for both the
current and staged files, and checksums for all lifecycle scripts. A mismatch
or symlink fails closed. Each file also carries an allowlisted Unix mode;
snapshots preserve the original mode via `cp -p` and rollback restores it.

Lifecycle:

1. `prepare` → `prepared`, no rollback timer and no network change.
2. Save both printed recovery commands.
3. `cutover` starts detached on the router, arms the timer first, installs only
   allowlisted staged files, runs `apply.sh`, then `verify.sh`.
4. A successful apply remains `applied_unconfirmed`; the timer stays armed.
5. An external supervisor validates both LAN addresses, home-server, DNS and
   internet, then calls `confirm`.
6. Any failed apply/verify, explicit rollback, or expired timer restores the
   snapshot and runs `rollback.sh`.

Never call `confirm` from router-local probes. Do not use a full network restart
in bundle scripts; apply only LAN-scoped address, DHCP, firewall, proxy and pin
changes in dependency order. The home bundle adds the new address directly to
`br-lan`, persists both addresses in UCI, and fails closed if WAN uptime resets.

## Home migration launch sequence

Run these only during the agreed maintenance window:

```bash
# 0. Read-only baseline; save the output with both reachable addresses.
bin/inspect-lan-migration.sh --router home

# 1. Installs rollback tooling only; takes a router snapshot and does not reload LAN.
bin/install-lan-migration-runtime.sh --router home

# 1b. Uses only temporary files; proves actual BusyBox setsid/flock/timer restore.
bin/test-lan-migration-runtime.sh --router home

# 2. Builds the secret-bearing bundle on the router and prepares a snapshot.
#    Save the printed MIGRATION_ID and both rollback commands.
bin/prepare-home-lan-migration.sh --router home

# 3. Start the Mac-side verifier before cutover.
bin/supervise-home-lan-migration.sh --router home \
  --migration-id <MIGRATION_ID>

# 4. Start the detached router transaction. This is the live stop-gate.
bin/migrate-lan.sh --router home --phase cutover \
  --migration-id <MIGRATION_ID> --timeout-seconds 900
```

The supervisor confirms only after three consecutive successful checks of both
router addresses, both home-server addresses, SSH/HTTPS, DNS, direct internet,
and the `192.168.99.1:4002` proxy. Otherwise it does not confirm and the router
timer rolls back.

Emergency rollback from the Mac:

```bash
bin/migrate-lan.sh --router home --phase rollback \
  --migration-id <MIGRATION_ID> \
  --recovery-host 192.168.99.1 --recovery-host 192.168.1.1
```

Emergency rollback from the router console:

```bash
/usr/sbin/vpn-kit-lan-migrate rollback --migration-id <MIGRATION_ID>
```

Use `verify-ssh-endpoint.sh` and `verify-router-core-via-ssh.sh` only as
read-only evidence inside the supervisor/recovery workflow. Do not treat one
successful SSH connection as proof that DHCP, DNS, proxy, WAN, and rollback are
all healthy.

## Home-server transaction

After the router has committed the new LAN and the server is reachable through
both recovery paths, move the home-server gateway/DNS with its independent
systemd rollback timer:

```bash
bin/migrate-home-server-lan.sh --phase prepare
bin/migrate-home-server-lan.sh --phase cutover
bin/migrate-home-server-lan.sh --phase status
# Confirm only after SSH/HTTPS, DNS and internet work through the new gateway.
bin/migrate-home-server-lan.sh --phase confirm
```

If validation fails, run `bin/migrate-home-server-lan.sh --phase rollback` or
leave its rollback timer armed. These home-server scripts are intentionally
environment-specific; review their host, interface, address, and NetworkManager
connection constants before reuse. Passwords and private keys must still remain
outside tracked files.

After clients have received the new subnet, `bin/renew-legacy-lan-clients.sh
--router home` may force only the remaining legacy DHCP clients to reconnect.
Run it only after the new LAN and rollback paths are already proven.

## Final legacy-subnet cleanup

Do not remove `192.168.1.0/24` compatibility in the same transaction as the
initial cutover. First run the secret-safe audit and resolve every reported
reference:

```bash
bin/audit-lan99-cleanup.sh --router home
```

Finalize the home-server compatibility address with its own rollback timer:

```bash
bin/finalize-home-server-lan99.sh --phase prepare
bin/finalize-home-server-lan99.sh --phase cutover
bin/finalize-home-server-lan99.sh --phase status
bin/finalize-home-server-lan99.sh --phase confirm
```

Then prepare the router cleanup, start the external supervisor before cutover,
and save the printed migration ID and rollback commands:

```bash
bin/prepare-home-lan-cleanup.sh --router home
bin/supervise-home-lan-cleanup.sh --router home --migration-id <MIGRATION_ID>
bin/migrate-lan.sh --router home --phase cutover \
  --migration-id <MIGRATION_ID> --timeout-seconds 900
```

After confirmation, remove only stale non-routing metadata and abandoned,
unprepared `/tmp` builds:

```bash
bin/finalize-lan99-metadata.sh --router home
bin/cleanup-lan-migration-builds.sh --router home
bin/audit-lan99-cleanup.sh --router home
```

## Internal helpers

Do not call these directly unless a public script prints an explicit recovery
instruction:

- `build-home-lan-cleanup-bundle-remote.sh` and
  `lib/build-home-lan-bundle-remote.sh` render validated bundles;
- `home-server-lan99-rollback.sh`, `home-server-lan99-finalize-remote.sh`, and
  `home-server-lan99-finalize-rollback.sh` are installed server payloads;
- `lan99-reconcile-rollback-remote.sh`, `reconcile-home-lan-runtime.sh`, and
  `reconcile-home-lan-final-runtime.sh` protect narrowly scoped netifd reloads;
- `lib/lan-migrate-runtime.sh` is the router-local transaction engine.

Every `prepare`, `cutover`, `confirm`, and cleanup phase is a separate claim.
Keep its snapshot/timer evidence and do not call the migration complete until a
fresh final audit reports no legacy routing references.
