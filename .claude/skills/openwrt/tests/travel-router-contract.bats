#!/usr/bin/env bats

setup() {
  SKILL_HOME="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "travel-router scripts are syntactically valid" {
  for script in \
    backup-now.sh \
    install-travelmate.sh \
    configure-travel-router.sh \
    configure-home-travel-route.sh \
    inspect-travel-router.sh \
    inspect-router-buttons.sh \
    install-travel-ap-button.sh \
    verify-travel-ap-button.sh \
    verify-travel-router.sh \
    verify-awg2-link.sh \
    verify-wifi-uplink.sh \
    inspect-scheduled-reboot.sh \
    configure-scheduled-reboot.sh \
    audit-vps-awg-hub.sh \
    reboot-router.sh; do
    run bash -n "$SKILL_HOME/bin/$script"
    [ "$status" -eq 0 ]
  done
}

@test "scheduled reboot keeps unrelated cron entries and has safety guards" {
  installer="$SKILL_HOME/bin/configure-scheduled-reboot.sh"
  helper="$SKILL_HOME/openwrt/travel-daily-reboot"

  run grep -F 'index($0, marker) == 0 { print }' "$installer"
  [ "$status" -eq 0 ]
  run grep -F 'grep -c "$marker" "$cron_file"' "$installer"
  [ "$status" -eq 0 ]
  run grep -F 'TRAVEL_DAILY_REBOOT_DRY_RUN=1 "$helper"' "$installer"
  [ "$status" -eq 0 ]
  run grep -F 'result="$(ssh_run_remote_with_args /dev/stdin' "$installer"
  [ "$status" -eq 1 ]
  run grep -F 'trap on_signal INT TERM HUP' "$installer"
  [ "$status" -eq 0 ]
  run grep -F '[ "$now_epoch" -lt 1704067200 ]' "$helper"
  [ "$status" -eq 0 ]
  run grep -F '[ "$uptime_seconds" -lt "$minimum_uptime_seconds" ]' "$helper"
  [ "$status" -eq 0 ]
}

@test "travel AP button contract is bounded and toggles both bands" {
  installer="$SKILL_HOME/bin/install-travel-ap-button.sh"
  handler="$SKILL_HOME/openwrt/travel-ap-button"

  run grep -F 'visible_seconds=600' "$installer"
  [ "$status" -eq 0 ]

  run grep -F '[ "$SEEN" -le 3 ]' "$handler"
  [ "$status" -eq 0 ]

  for section in travel_ap_24 travel_ap_5; do
    run grep -F "wireless.$section.hidden='0'" "$handler"
    [ "$status" -eq 0 ]
    run grep -F "wireless.$section.hidden='1'" "$handler"
    [ "$status" -eq 0 ]
  done

  run grep -F 'rm -f "$token_file"' "$handler"
  [ "$status" -eq 0 ]

  run sed -n '/if \[ "$hidden_24"/,/^else$/p' "$handler"
  [ "$status" -eq 0 ]
  [[ "$output" != *"uci commit wireless"* ]]
}

@test "portable transport does not depend on base64 or expose password in ssh argv" {
  script="$SKILL_HOME/bin/configure-travel-router.sh"
  run grep -n 'base64' "$script"
  [ "$status" -eq 1 ]

  run grep -F "sh -s -- '\$ssid_hex' '\$password_hex'" "$script"
  [ "$status" -eq 1 ]

  run grep -F "printf \"password_hex='%s'" "$script"
  [ "$status" -eq 0 ]
}

@test "live AmneziaWG AllowedIPs changes use awg set" {
  run grep -F 'awg set "$interface" peer' "$SKILL_HOME/bin/configure-home-travel-route.sh"
  [ "$status" -eq 0 ]

  run grep -F 'awg set awg1 peer' "$SKILL_HOME/bin/configure-travel-router.sh"
  [ "$status" -eq 0 ]

  run grep -E -n '(^|[^[:alnum:]_])wg[[:space:]]+(show|set)' \
    "$SKILL_HOME/bin/configure-home-travel-route.sh" \
    "$SKILL_HOME/bin/configure-travel-router.sh" \
    "$SKILL_HOME/bin/verify-travel-router.sh"
  [ "$status" -eq 1 ]
}

@test "site-to-site proof binds a source address and never br-lan" {
  run grep -R -n 'ping -I br-lan' \
    "$SKILL_HOME/bin/configure-home-travel-route.sh" \
    "$SKILL_HOME/bin/verify-travel-router.sh"
  [ "$status" -eq 1 ]

  run grep -F 'ping -I "$home_lan_ip"' "$SKILL_HOME/bin/configure-home-travel-route.sh"
  [ "$status" -eq 0 ]

  run grep -F 'ping -I "$lan_ip"' "$SKILL_HOME/bin/verify-travel-router.sh"
  [ "$status" -eq 0 ]
}

@test "home route heredoc is not wrapped in an expanding command substitution" {
  script="$SKILL_HOME/bin/configure-home-travel-route.sh"

  run grep -F 'result="$(ssh_run_remote_with_args /dev/stdin' "$script"
  [ "$status" -eq 1 ]

  run grep -F 'ssh_run_remote_with_args /dev/stdin \' "$script"
  [ "$status" -eq 0 ]
}

@test "peer lookup supports comma-separated AllowedIPs" {
  sample='peer-key 10.67.0.0/24,192.168.99.0/24'
  run awk -v target='192.168.99.0/24' '
    {
      key=$1
      for (i=2; i<=NF; i++) {
        count=split($i, allowed, ",")
        for (j=1; j<=count; j++) {
          if (allowed[j] == target) { print key; exit }
        }
      }
    }
  ' <<<"$sample"
  [ "$status" -eq 0 ]
  [ "$output" = peer-key ]

  run grep -F 'split($i, allowed, ",")' "$SKILL_HOME/bin/verify-awg2-link.sh"
  [ "$status" -eq 0 ]
}

@test "post-migration operations accept stable ssh aliases" {
  for script in backup-now.sh install-travelmate.sh verify-awg2-link.sh verify-wifi-uplink.sh reboot-router.sh; do
    run grep -F -- '--ssh-alias' "$SKILL_HOME/bin/$script"
    [ "$status" -eq 0 ]
  done

  run grep -F 'backup_args+=(--ssh-alias "$ssh_alias")' "$SKILL_HOME/bin/install-travelmate.sh"
  [ "$status" -eq 0 ]
}

@test "idempotent install and rollback preserve Travelmate service state" {
  run grep -F 'if [ "$already_installed" = 0 ]' "$SKILL_HOME/bin/install-travelmate.sh"
  [ "$status" -eq 0 ]

  run grep -F 'service_was_enabled' "$SKILL_HOME/bin/configure-travel-router.sh"
  [ "$status" -eq 0 ]

  run grep -F 'service_was_running' "$SKILL_HOME/bin/configure-travel-router.sh"
  [ "$status" -eq 0 ]
}
