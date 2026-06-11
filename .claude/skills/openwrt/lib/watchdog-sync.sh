#!/bin/sh
# lib/watchdog-sync.sh — обновляет NODES= в vpn-nodes-watchdog.sh на роутере.
#
# Вызывается из bin/add-vpn.sh и bin/remove-vpn.sh после успешного restart.
# Использует ssh_run (определён в lib/ssh-runner.sh).
#
# Логика: берём все vless-outbound из /etc/sing-box/config.json через jq,
# собираем строку вида "tag1:ip1 tag2:ip2 ...", заменяем NODES= в watchdog.
# Пулы (type=urltest) и direct/http — игнорируются (не имеют server).
#
# Не-критичная операция: провал — WARN в stderr, не rollback.

sync_vpn_nodes_watchdog() {
  local router_alias="$1"
  local wdog_path="${2:-/usr/bin/vpn-nodes-watchdog.sh}"

  ssh_run "
    set -e
    cfg=/etc/sing-box/config.json
    wdog='$wdog_path'

    if [ ! -f \"\$cfg\" ]; then
      echo 'watchdog-sync: config.json not found, skip' >&2
      exit 0
    fi
    if [ ! -f \"\$wdog\" ]; then
      echo 'watchdog-sync: watchdog not found at '\$wdog', skip' >&2
      exit 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo 'watchdog-sync: jq not available, skip' >&2
      exit 0
    fi

    nodes=\$(jq -r '.outbounds[] | select(.type==\"vless\") | select(.server != null and .server != \"\") | .tag + \":\" + .server' \"\$cfg\" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*\$//')

    if [ -z \"\$nodes\" ]; then
      echo 'watchdog-sync: no vless outbounds found in config.json, skip' >&2
      exit 0
    fi

    sed -i \"s|^NODES=.*|NODES=\\\"\$nodes\\\"|\" \"\$wdog\"
    echo \"watchdog-sync: NODES updated -> \$nodes\"
  " 2>&1 | sed 's/^/watchdog-sync: /' >&2 || \
    echo "add/remove-vpn: WARN — обновление vpn-nodes-watchdog не удалось (не критично)" >&2
}
