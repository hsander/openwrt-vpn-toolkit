#!/bin/sh
# install-safety.sh — install Stage 0 safety runtime onto an OpenWrt filesystem.
#
# Usage:
#   install-safety.sh [--root <target-root>] [--writer <id>]
#
# With --root /tmp/router-root this performs an offline install into that root.
# Without --root it installs to the live router filesystem.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_SRC="$ROOT_DIR/lib"
INIT_SRC="$ROOT_DIR/openwrt/init.d/vpn-kit-rollback"

target_root="${VPN_KIT_TARGET_ROOT:-}"
writer="claude-code@install-safety"

while [ $# -gt 0 ]; do
  case "$1" in
    --root) target_root="${2:-}"; shift 2 ;;
    --writer) writer="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "install-safety: unknown arg: $1" >&2; exit 13 ;;
  esac
done

export VPN_KIT_TARGET_ROOT="$target_root"
# shellcheck source=../lib/vpn-kit-common.sh
. "$LIB_SRC/vpn-kit-common.sh"

vpn_kit_validate_writer_id "$writer" || {
  echo "install-safety: invalid writer: $writer" >&2
  exit "$VPN_KIT_EXIT_VALIDATION"
}

lib_dst="$(vpn_kit_target_path /usr/lib/vpn-kit)"
usr_sbin="$(vpn_kit_target_path /usr/sbin)"
init_dst="$(vpn_kit_target_path /etc/init.d/vpn-kit-rollback)"
state_dir="$(vpn_kit_target_path /etc/vpn-kit)"

mkdir -p "$lib_dst" "$usr_sbin" "$(dirname "$init_dst")" "$state_dir/journal" "$state_dir/rollback.d" "$state_dir/snapshots"

for file in "$LIB_SRC"/*.sh; do
  cp "$file" "$lib_dst/$(basename "$file")"
  chmod 0755 "$lib_dst/$(basename "$file")"
done

cp "$INIT_SRC" "$init_dst"
chmod 0755 "$init_dst"

cat > "$usr_sbin/vpn-kit-rollback" <<'SH'
#!/bin/sh
exec /usr/lib/vpn-kit/vpn-kit-rollback.sh "$@"
SH
chmod 0755 "$usr_sbin/vpn-kit-rollback"

cat > "$usr_sbin/vpn-kit-staged-apply" <<'SH'
#!/bin/sh
exec /usr/lib/vpn-kit/staged-apply.sh "$@"
SH
chmod 0755 "$usr_sbin/vpn-kit-staged-apply"

cat > "$usr_sbin/vpn-kit-preflight-safety" <<'SH'
#!/bin/sh
exec /usr/lib/vpn-kit/preflight-safety.sh "$@"
SH
chmod 0755 "$usr_sbin/vpn-kit-preflight-safety"

installed_at="$(vpn_kit_now_iso8601)"

sha_file() {
  _file="$1"
  if [ -f "$_file" ]; then
    vpn_kit_sha256 < "$_file"
  else
    printf ''
  fi
}

rollback_sha="$(sha_file "$lib_dst/vpn-kit-rollback.sh")"
init_sha="$(sha_file "$init_dst")"

files_json="$(jq -n \
  --arg lib "$lib_dst/vpn-kit-rollback.sh" \
  --arg init "$init_dst" \
  --arg wrapper "$usr_sbin/vpn-kit-rollback" \
  '[$lib, $init, $wrapper]')"
checksums_json="$(jq -n \
  --arg rollback "$lib_dst/vpn-kit-rollback.sh" \
  --arg rollback_sha "$rollback_sha" \
  --arg init "$init_dst" \
  --arg init_sha "$init_sha" \
  '{($rollback):$rollback_sha, ($init):$init_sha}')"

state_payload="$(jq -n \
  --arg installed_at "$installed_at" \
  --arg rollback_sha "$rollback_sha" \
  --arg init "$init_dst" \
  --arg binary "$usr_sbin/vpn-kit-rollback" \
  --argjson files "$files_json" \
  --argjson checksums "$checksums_json" \
  '{
    version: 1,
    installed_at: $installed_at,
    skill_version: "0.1.0",
    profile: "minimal",
    router_identity: {name: "unknown", openwrt_version: "unknown", arch: "x86_64"},
    committed_steps: [],
    components: {
      rollback_daemon: {
        version: "0.1.0",
        init: $init,
        binary: $binary,
        binary_sha256: $rollback_sha
      }
    },
    files_owned_by_skill: $files,
    owned_file_checksums: $checksums
  }')"

state_file="$(vpn_kit_target_path /etc/vpn-kit/install-state.json)"
if [ ! -f "$state_file" ]; then
  printf '%s\n' "$state_payload" | env VPN_KIT_STATE_FILE="$state_file" "$lib_dst/state-write.sh" \
    --expected-revision 0 \
    --writer "$writer" >/dev/null
fi

if [ -z "$target_root" ] && [ -x "$init_dst" ]; then
  "$init_dst" enable >/dev/null 2>&1 || true
  "$init_dst" start >/dev/null 2>&1 || true
fi

jq -n --arg status ok --arg root "${target_root:-/}" --arg lib "$lib_dst" '{status:$status, root:$root, lib:$lib}'
