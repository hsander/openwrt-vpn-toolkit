#!/usr/bin/env bash
# bin/setup-ssh.sh — bootstrap SSH key-based access to an OpenWRT router.
#
# Two-phase:
#   1) Generate ed25519 key (if missing), register the router in memory/routers.yaml,
#      add a Host block to ~/.ssh/config.
#   2) Try a BatchMode SSH probe. If it fails — print instructions for the user
#      to run `ssh-copy-id` manually and re-run this script.
#
# Usage:
#   bin/setup-ssh.sh --router <alias> --host <host> [--user root] [--port 22] [--alias <ssh-host-alias>]
#
# Exit codes:
#   0   ok — SSH key auth works
#   2   internal error (e.g. ssh-keygen failed)
#  13   validation error (bad args)
#  64   bad CLI args OR user action needed (run ssh-copy-id and retry)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OPENWRT_SKILL_HOME="${OPENWRT_SKILL_HOME:-$SKILL_HOME}"
export OPENWRT_SKILL_MEMORY="${OPENWRT_SKILL_MEMORY:-$OPENWRT_SKILL_HOME/memory}"

# shellcheck source=../lib/router-config.sh
. "$SKILL_HOME/lib/router-config.sh"
# shellcheck source=../lib/memory-journal.sh
. "$SKILL_HOME/lib/memory-journal.sh"
# shellcheck source=../lib/template-render.sh
. "$SKILL_HOME/lib/template-render.sh"

usage() {
  cat >&2 <<'EOF'
Usage: bin/setup-ssh.sh --router <alias> --host <host> [--user root] [--port 22] [--alias <ssh-host-alias>]

Готовит SSH-доступ к роутеру по ключу:
  1) генерирует ed25519 ключ ~/.ssh/openwrt_<alias>_ed25519 (если нет)
  2) добавляет Host-блок в ~/.ssh/config
  3) регистрирует роутер в memory/routers.yaml
  4) проверяет BatchMode SSH; если не работает — печатает инструкцию для ssh-copy-id

Options:
  --router <alias>   alias для memory/routers.yaml (обяз.)
  --host <host>      IP или DNS-имя роутера (обяз.)
  --user <user>      SSH юзер (по умолчанию root)
  --port <port>      SSH порт (по умолчанию 22)
  --alias <name>     имя Host-блока в ~/.ssh/config (по умолчанию openwrt-<alias>)
EOF
  exit 64
}

router=""
host=""
user="root"
port="22"
ssh_alias=""

while [ $# -gt 0 ]; do
  case "$1" in
    --router) router="${2:-}"; shift 2 ;;
    --host) host="${2:-}"; shift 2 ;;
    --user) user="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --alias) ssh_alias="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "setup-ssh: неизвестный аргумент: $1" >&2; usage ;;
  esac
done

[ -z "$router" ] && { echo "setup-ssh: --router обязателен" >&2; usage; }
[ -z "$host" ]   && { echo "setup-ssh: --host обязателен" >&2; usage; }

# Validate alias shape — used in filenames + yq key paths.
if ! printf '%s' "$router" | grep -qE '^[a-zA-Z0-9_-]+$'; then
  echo "setup-ssh: невалидный --router='$router' (только a-zA-Z0-9_-)" >&2
  exit 13
fi

# Validate port is numeric.
if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
  echo "setup-ssh: невалидный --port='$port' (должно быть число)" >&2
  exit 13
fi

# Default ssh_alias.
if [ -z "$ssh_alias" ]; then
  ssh_alias="openwrt-$router"
fi

key_path="$HOME/.ssh/openwrt_${router}_ed25519"
ssh_config="$HOME/.ssh/config"
marker="# openwrt-skill: $router"

# --- 1. Generate key if missing -------------------------------------------------

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh" 2>/dev/null || true

if [ -f "$key_path" ]; then
  echo "setup-ssh: ключ уже существует: $key_path (используем его)" >&2
else
  echo "setup-ssh: генерирую ed25519 ключ → $key_path" >&2
  # No passphrase: agent automation. Comment includes alias + local hostname.
  if ! ssh-keygen -t ed25519 -f "$key_path" -N "" \
      -C "openwrt-skill:$router@$(hostname -s 2>/dev/null || hostname)" >/dev/null; then
    echo "setup-ssh: ssh-keygen упал" >&2
    exit 2
  fi
  chmod 600 "$key_path"
  chmod 644 "${key_path}.pub"
fi

# --- 2. Register router in memory/routers.yaml ---------------------------------

# register_router writes via yq. If routers.yaml doesn't exist yet, it copies
# from routers.yaml.example. We pass the registry path inside OPENWRT_SKILL_MEMORY.
if ! register_router "$router" "$host" "$user" "$key_path" "$ssh_alias" \
     "added by setup-ssh.sh"; then
  echo "setup-ssh: register_router упал" >&2
  exit 2
fi

# --- 3. Add Host block to ~/.ssh/config (idempotent, atomic) -------------------

# We want an idempotent update. If a block with exactly this Host name already
# exists, leave it alone (warn). Otherwise append a fresh marked block.
host_block=$(cat <<EOF
$marker
Host $ssh_alias
  HostName $host
  User $user
  Port $port
  IdentityFile $key_path
  IdentitiesOnly yes
EOF
)

block_exists=0
if [ -f "$ssh_config" ]; then
  # Match a Host line whose first non-comment token is exactly $ssh_alias.
  if awk -v target="$ssh_alias" '
      /^[[:space:]]*#/ { next }
      tolower($1) == "host" {
        for (i = 2; i <= NF; i++) {
          if ($i == target) { found = 1; exit }
        }
      }
      END { exit (found ? 0 : 1) }
    ' "$ssh_config"; then
    block_exists=1
  fi
fi

if [ "$block_exists" = "1" ]; then
  echo "setup-ssh: Host-блок '$ssh_alias' уже есть в ~/.ssh/config — не трогаю" >&2
else
  tmp_cfg="$ssh_config.tmp.$$"
  if [ -f "$ssh_config" ]; then
    cp "$ssh_config" "$tmp_cfg"
    # Make sure file ends with a newline before appending.
    if [ -s "$tmp_cfg" ] && [ -n "$(tail -c 1 "$tmp_cfg")" ]; then
      printf '\n' >> "$tmp_cfg"
    fi
  else
    : > "$tmp_cfg"
  fi
  printf '\n%s\n' "$host_block" >> "$tmp_cfg"
  chmod 600 "$tmp_cfg"
  mv "$tmp_cfg" "$ssh_config"
  echo "setup-ssh: добавлен Host-блок '$ssh_alias' в ~/.ssh/config" >&2
fi

# --- 4. Probe SSH (BatchMode, no password) -------------------------------------

if ssh -o BatchMode=yes -o ConnectTimeout=5 \
       -o StrictHostKeyChecking=accept-new \
       "$ssh_alias" true 2>/dev/null; then
  # Success: ensure memory/<alias>/ exists so journal works, then write a journal entry.
  render_first_time_memory "$router" "$host"

  if memory_journal_append "$router" "ssh_setup_completed" \
        "host=$host" "user=$user" "port=$port" "ssh_alias=$ssh_alias"; then
    :
  else
    echo "setup-ssh: не смог записать journal (не критично)" >&2
  fi

  cat >&2 <<EOF

setup-ssh: успех — SSH работает по ключу.
  alias:    $ssh_alias
  host:     $user@$host:$port
  key:      $key_path

Следующий шаг:
  bin/doctor.sh --router $router
EOF
  exit 0
fi

# --- 4b. BatchMode failed: instruct user -------------------------------------

pub_key="${key_path}.pub"

cat >&2 <<EOF

setup-ssh: SSH-ключ ещё не установлен на роутере '$ssh_alias' ($user@$host:$port).
BatchMode-проверка не прошла — нужен один ручной шаг от тебя.

Выполни в своём терминале (Claude не может ввести пароль за тебя):

  ssh-copy-id -i $pub_key -p $port $user@$host

Если ssh-copy-id недоступен — скопируй ключ руками:

  cat $pub_key
  # затем на роутере:
  #   mkdir -p /etc/dropbear && cat >> /etc/dropbear/authorized_keys
  #   (вставь содержимое, Ctrl-D)
  #   chmod 600 /etc/dropbear/authorized_keys

После того как ssh-copy-id отработает, перезапусти эту команду:

  bin/setup-ssh.sh --router $router --host $host --user $user --port $port

Тогда мы проверим, что доступ по ключу заработал, и обновим memory.
EOF
exit 64
