# Travel router: Travelmate + AWG2 site-to-site

This runbook configures one dual-radio OpenWrt device as a travel router that:

- exposes a permanent WPA2 private AP for a phone/tablet;
- lets the user add hotel uplinks in LuCI under `Services -> Travelmate`;
- keeps ordinary internet on the hotel/hotspot uplink;
- routes only the home LAN through the existing AWG2 tunnel;
- remains manageable through the AWG tunnel after its LAN address changes.

## Workflow map

- User connection steps: `Connect to a new external Wi-Fi`.
- First AWG2/uplink onboarding: `AWG2 prerequisite onboarding`.
- Travel profile and button rollout: `Required order`.
- Acceptance criteria: `Proof required before cloning to another router`.

## Connect to a new external Wi-Fi / Подключение к новой внешней Wi-Fi сети

### English — phone or tablet

1. Power on the travel router. If MobileHub is hidden, briefly press the physical
   `Wireless Pairing` button. Both bands become visible for 600 seconds.
2. Connect the phone/tablet to the router's private SSID. Do not join the hotel
   network directly.
3. Open LuCI at the router's travel-LAN address. Examples: router 001 is
   `http://172.27.1.1` (or HTTPS if explicitly configured); router 002 should use
   its own unique address after its travel profile is configured.
4. Open `Services -> Travelmate`, scan for networks, select the hotel/hotspot
   SSID, enter its password, then choose `Save & Apply`.
5. If the network has a captive portal, stay connected to the private SSID and
   open a plain HTTP page such as `http://neverssl.com`; complete the hotel login.
6. Confirm that a normal website opens. Travelmate remembers the uplink and
   reconnects to it automatically after the next boot.

Use 2.4 GHz for better range and 5 GHz for speed. Add open networks explicitly;
never enable automatic enrollment of unknown open Wi-Fi. Do not change the LAN,
private AP, AWG2, or firewall settings while adding an uplink.

If MobileHub is already visible, a short Wireless Pairing press hides both bands
immediately and cancels the pending auto-hide window. Hidden SSIDs remain
detectable and are not a security boundary; WPA2 is still mandatory.

### Русский — телефон или планшет

1. Включите travel router. Если MobileHub скрыт, коротко нажмите физическую
   кнопку `Wireless Pairing`: обе точки станут видимыми на 600 секунд.
2. Подключите телефон/планшет к приватной сети роутера. Напрямую к Wi-Fi
   гостиницы подключаться не нужно.
3. Откройте LuCI по travel-LAN адресу роутера. Например, для роутера 001 это
   `http://172.27.1.1` (или HTTPS, если он настроен отдельно); роутер 002 получит
   собственный уникальный адрес после настройки travel-профиля.
4. Откройте `Службы (Services) -> Travelmate`, запустите поиск сетей, выберите
   Wi-Fi гостиницы или точку телефона, введите пароль и нажмите
   `Сохранить и применить (Save & Apply)`.
5. Если гостиница показывает страницу авторизации, оставайтесь подключены к
   приватной сети роутера, откройте обычную HTTP-страницу, например
   `http://neverssl.com`, и завершите вход.
6. Проверьте открытие обычного сайта. Travelmate запомнит сеть и будет
   подключаться к ней автоматически после следующих включений.

Для дальности выбирайте 2.4 ГГц, для скорости — 5 ГГц. Открытые сети добавляйте
только вручную; автоматическое добавление неизвестных открытых Wi-Fi должно
оставаться выключенным. При добавлении uplink не меняйте LAN, приватную точку,
AWG2 и firewall.

Если MobileHub уже видим, короткое нажатие Wireless Pairing сразу скрывает обе
точки и отменяет отложенное автоскрытие. Скрытый SSID можно обнаружить, поэтому
это не защита; WPA2 остаётся обязательным.

## Safety invariants

1. Use only `bin/*`; never compensate with raw SSH commands.
2. Verify the AWG management alias before changing the LAN address.
3. Take a snapshot through that stable alias. `backup-now.sh --ssh-alias` exists
   specifically for the period after the registry/bench address becomes stale.
4. Never place the private AP password in argv, memory, journal, Markdown, or
   repository files. Supply it with `--password-stdin`.
5. Keep Travelmate VPN handling disabled (`trm_vpn=0`). AWG2 is independent and
   must recover through ordinary netifd boot handling.
6. Keep `trm_autoadd=0`. Add unknown/open hotel networks explicitly from LuCI.
7. Do not hide the private SSID during initial rollout. First prove the visible
   AP, DHCP, LuCI, uplink, and AWG2 path. Enable hidden-by-default mode only
   after the physical Wireless Pairing button is identified and tested.
8. A generated software button event proves handler logic only. It does not
   prove the physical button, so require one real short press on every router.
9. Hidden SSID is not a security control. Keep WPA2 enabled and never weaken the
   private AP password because the network is hidden.

## Address plan

Avoid common upstream subnets such as `192.168.0.0/24` and `192.168.1.0/24`.
Give every travel router a unique subnet, for example:

- router 001: `172.27.1.1/24`, routed subnet `172.27.1.0/24`;
- router 002: `172.27.2.1/24`, routed subnet `172.27.2.0/24`.

Never reuse the same routed LAN subnet on two simultaneously connected peers.

## AWG2 prerequisite onboarding

Skip this section only when the client already has a verified `awg1` management
link and a saved Wi-Fi uplink. Do not expose private keys: generate the client
key on the router and transfer only public keys.

1. Capture read-only inventories before modifying anything:

   ```bash
   bin/inspect-management-access.sh --router <router>
   bin/inspect-awg2.sh --router <router> --scan-wifi
   ```

2. On the supported SmartBox/OpenWrt target, install the pinned AWG2 packages:

   ```bash
   bin/install-awg2-packages.sh --router <router> --package-dir <verified-dir>
   ```

3. Establish an ordinary Wi-Fi WAN. Supply the Wi-Fi password only through
   stdin; never put it in argv or Markdown:

   ```bash
   bin/setup-wifi-uplink.sh --password-stdin --router <router> \
     --ssid <known-uplink-ssid> --radio <radio>
   bin/verify-wifi-uplink.sh --router <router> \
     --expected-ssid <known-uplink-ssid>
   ```

   `clone-wifi-uplink.sh` may copy a known credential between two trusted SSH
   aliases without revealing it, but it must not become the only recovery path.

4. Obtain the home public key, configure a unique client tunnel IP, then add the
   returned client public key to home:

   ```bash
   bin/awg2-public-key.sh --router home --interface awg1
   bin/configure-awg2-client.sh --router <router> \
     --endpoint <home-public-ip> --server-public-key <home-public-key> \
     --tunnel-ip <unique-10.67.0.x>
   bin/add-awg2-home-peer.sh --router home \
     --peer-public-key <client-public-key> --peer-ip <unique-10.67.0.x> \
     --section <unique-peer-section>
   ```

5. Create a stable SSH alias for the tunnel endpoint and prove the link with
   `verify-awg2-link.sh`. Do not change the travel LAN until this path works.

## Required order

1. Read-only baseline:

   ```bash
   bin/inspect-travel-router.sh --router <router> --ssh-alias <vpn-alias>
   bin/verify-awg2-link.sh --router <router> --ssh-alias <vpn-alias> \
     --interface awg1 --local-ip <client-awg-ip> \
     --peer-ip <home-awg-ip> --peer-allowed <current-peer-cidr>
   ```

2. Install official packages. This step deliberately leaves Travelmate stopped
   and disabled:

   ```bash
   bin/install-travelmate.sh --router <router> --ssh-alias <vpn-alias>
   ```

3. Configure the client profile. The operation has a router-local rollback
   timer and updates the live AWG peer with `awg set`; `network reload` alone is
   not enough to apply changed AllowedIPs to an already running peer:

   ```bash
   bin/configure-travel-router.sh --password-stdin \
     --router <router> --ssh-alias <vpn-alias> --ssid <private-ssid> \
     --lan-cidr <travel-router-ip/24> --home-lan <home-cidr> \
     --uplink-ssid <known-fallback-ssid> --peer-section <home-peer-section>
   ```

4. Add the reverse route on home. This persists UCI state and updates the live
   peer without restarting the AWG interface or WAN:

   ```bash
   bin/configure-home-travel-route.sh --router home \
     --interface awg1 --peer-section <travel-peer-section> \
     --travel-subnet <travel-cidr> --route-section <unique-route-section> \
     --client-tunnel-ip <client-awg-ip> --home-lan-ip <home-lan-ip>
   ```

5. Run end-to-end verification. Bind source-address tests to the actual LAN IP,
   not to `br-lan`: `ping -I br-lan` forces the wrong egress interface and is
   not a site-to-site test.

   ```bash
   bin/verify-travel-router.sh --router <router> --ssh-alias <vpn-alias> \
     --expected-lan <travel-router-ip/24> --expected-ssid <private-ssid> \
     --expected-uplink <known-fallback-ssid> --home-lan-cidr <home-cidr> \
     --home-lan-ip <home-lan-ip> --require-dhcp-client
   ```

6. Only after the visible profile passes, inspect and install the physical
   visibility toggle:

   ```bash
   bin/inspect-router-buttons.sh --router <router> --ssh-alias <vpn-alias>
   bin/install-travel-ap-button.sh --router <router> \
     --ssh-alias <vpn-alias> --lan-ip <travel-router-ip> \
     --home-lan-ip <home-lan-ip> --visible-seconds 600
   bin/verify-travel-ap-button.sh --ssh-alias <vpn-alias> \
     --visible-seconds 600 --expected-hidden 1
   ```

   Prove on the actual device: hidden → one short press → both MobileHub bands
   visible; a second short press → both hidden immediately. Long presses must
   remain ignored by this handler.

7. Reboot through the stable alias and repeat the full verifier with
   `--expected-hidden 1`:

   ```bash
   bin/reboot-router.sh --router <router> --ssh-alias <vpn-alias>
   bin/verify-travel-router.sh --router <router> --ssh-alias <vpn-alias> \
     --expected-lan <travel-router-ip/24> --expected-ssid <private-ssid> \
     --expected-hidden 1 --expected-uplink <known-fallback-ssid> \
     --home-lan-cidr <home-cidr> --home-lan-ip <home-lan-ip>
   bin/verify-travel-ap-button.sh --ssh-alias <vpn-alias> \
     --visible-seconds 600 --expected-hidden 1
   ```

   Also reboot once while the 600-second visibility window is active. The AP
   must return hidden after boot; otherwise the button feature is incomplete and
   must not be recorded as verified.

## Proof required before cloning to another router

- two active private AP interfaces;
- physical short-press proof on that router: hidden → visible → hidden;
- both bands auto-hide after 600 seconds and return hidden after a reboot during
  the visibility window;
- at least one DHCP client when a phone/tablet is available;
- LuCI answers on the travel LAN address;
- default internet route uses the Wi-Fi station;
- home LAN route uses `awg1`;
- both runtime peers contain the routed subnet in AllowedIPs;
- pings with 16, 512, and 1200-byte payloads pass from the travel LAN source;
- Travelmate, Wi-Fi WAN, DNS, AWG handshake, SSH, and site-to-site routing all
  recover after a full reboot.

## Known implementation traps

- Minimal OpenWrt images may not include `base64`; portable parameter transport
  uses `od` plus a BusyBox-compatible hex decoder.
- `wg` is the wrong CLI for AmneziaWG packages used here; use `awg`.
- `awg show <iface> allowed-ips` can return multiple comma-separated prefixes
  for one peer. Verifiers must search the list, not compare only field 2.
- After changing the LAN address, registry-host operations may be unreachable;
  pass `--ssh-alias` to backup, verify, install, and reboot operations.
- A successful handshake proves only the tunnel control plane. Site-to-site
  success additionally requires source-address pings and route/firewall checks.
