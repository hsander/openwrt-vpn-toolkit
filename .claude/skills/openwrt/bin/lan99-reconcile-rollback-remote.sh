#!/bin/sh
# Router-local emergency handler for a failed netifd reconciliation.

set -eu

snapshot_id="${1:-}"
case "$snapshot_id" in snap-[0-9]*Z) ;; *) exit 13 ;; esac

snapshot_dir='/etc/vpn-kit/snapshots'
tar_path="$snapshot_dir/$snapshot_id.tar.gz"
meta_path="$snapshot_dir/$snapshot_id.meta.json"
timer_path='/etc/vpn-kit/rollback.d/lan99-reconcile.timer'
final_timer_path='/etc/vpn-kit/rollback.d/lan99-final-reconcile.timer'

[ -f "$tar_path" ]
[ -f "$meta_path" ]
expected="$(jq -r '.sha256 // ""' "$meta_path")"
actual="$(sha256sum "$tar_path" | awk '{print $1}')"
[ -n "$expected" ]
[ "$actual" = "$expected" ]

tar -xzf "$tar_path" -C /
printf 'rollback_snapshot=%s\n' "$snapshot_id" > /etc/vpn-kit/lan99-reconcile-rollback-fired
rm -f "$timer_path"
rm -f "$final_timer_path"
sync
reboot
