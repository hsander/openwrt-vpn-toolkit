#!/usr/bin/env bash
# Install pinned AWG2 packages for SmartBox TURBO+ on OpenWrt 25.12.5.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/ssh-runner.sh
. "$SKILL_HOME/lib/ssh-runner.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"

usage() {
  echo "Usage: bin/install-awg2-packages.sh --router <alias> --package-dir <dir>" >&2
  exit 64
}

router=""
package_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --package-dir) package_dir="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "install-awg2-packages: unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$router" ] && [ -n "$package_dir" ] || usage

tools_name="amneziawg-tools_v25.12.5_mipsel_24kc_ramips_mt7621.apk"
kmod_name="kmod-amneziawg_v25.12.5_mipsel_24kc_ramips_mt7621.apk"
luci_name="luci-proto-amneziawg_v25.12.5_mipsel_24kc_ramips_mt7621.apk"
tools_sha="10325f7550ed9fee19c06d31bd21db0280ec09ca1afc3a8326d9f66d9da77ff3"
kmod_sha="c545adb37d8b367d7d30235074fa71aa5363958a63c74d8ed3d8166dae2edad5"
luci_sha="9dd2eda9fcdc30c3daa5db54cb4a5c7694d3b96e29121e628befd64005f2e297"

for name in "$tools_name" "$kmod_name" "$luci_name"; do
  [ -f "$package_dir/$name" ] || { echo "install-awg2-packages: missing $name" >&2; exit 13; }
done
printf '%s  %s\n' \
  "$tools_sha" "$package_dir/$tools_name" \
  "$kmod_sha" "$package_dir/$kmod_name" \
  "$luci_sha" "$package_dir/$luci_name" | shasum -a 256 -c - >/dev/null

resolve_router_config "$router"
ssh_check_alive 5 || { echo "install-awg2-packages: router is unreachable" >&2; exit 2; }

preflight="$(ssh_run_remote <<'REMOTE_SH'
set -eu
. /etc/openwrt_release
echo "release=$DISTRIB_RELEASE"
echo "target=$DISTRIB_TARGET"
echo "arch=$DISTRIB_ARCH"
echo "kernel=$(uname -r)"
command -v apk >/dev/null
for pkg in amneziawg-tools kmod-amneziawg luci-proto-amneziawg; do
  apk info -e "$pkg" >/dev/null 2>&1 && { echo "already_installed=$pkg"; exit 13; } || true
done
REMOTE_SH
)"
printf '%s\n' "$preflight"
printf '%s\n' "$preflight" | grep -qx 'release=25.12.5'
printf '%s\n' "$preflight" | grep -qx 'target=ramips/mt7621'
printf '%s\n' "$preflight" | grep -qx 'arch=mipsel_24kc'
printf '%s\n' "$preflight" | grep -qx 'kernel=6.12.94'

snapshot_id="$($SCRIPT_DIR/backup-now.sh --router "$router" --label "before awg2 packages" --quiet)"
remote_dir="/tmp/skill-awg2-packages"
ssh_run "rm -rf '$remote_dir' && mkdir -p '$remote_dir' && chmod 700 '$remote_dir'"

cleanup() { ssh_run "rm -rf '$remote_dir'" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
for name in "$tools_name" "$kmod_name" "$luci_name"; do
  ssh_run "umask 077 && cat > '$remote_dir/$name'" < "$package_dir/$name"
done

ssh_run_remote_with_args /dev/stdin "$remote_dir" "$tools_name" "$tools_sha" "$kmod_name" "$kmod_sha" "$luci_name" "$luci_sha" <<'REMOTE_SH'
set -eu
dir="$1"; tools="$2"; tools_sha="$3"; kmod="$4"; kmod_sha="$5"; luci="$6"; luci_sha="$7"
printf '%s  %s\n' "$tools_sha" "$dir/$tools" "$kmod_sha" "$dir/$kmod" "$luci_sha" "$dir/$luci" | sha256sum -c -
REMOTE_SH

set +e
install_out="$(ssh_run_remote_with_args /dev/stdin "$remote_dir/$kmod_name" "$remote_dir/$tools_name" "$remote_dir/$luci_name" <<'REMOTE_SH' 2>&1
set -eu
apk add --allow-untrusted "$1" "$2" "$3"
modprobe amneziawg
command -v awg >/dev/null
test -d /sys/module/amneziawg
proto=/lib/netifd/proto/amneziawg.sh
test -f "$proto"
grep -q 'awg_s3' "$proto"
grep -q 'awg_s4' "$proto"
grep -q 'awg_i1' "$proto"
apk info -e amneziawg-tools
apk info -e kmod-amneziawg
apk info -e luci-proto-amneziawg
REMOTE_SH
)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$install_out" >&2
  ssh_run "apk del luci-proto-amneziawg amneziawg-tools kmod-amneziawg >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  echo "install-awg2-packages: install failed; newly added AWG packages were removed (snapshot=$snapshot_id)" >&2
  exit 20
fi

printf '%s\n' "$install_out"
memory_journal_append "$router" "awg2_packages_installed"
echo "install-awg2-packages: success (snapshot=$snapshot_id)"
