# The network item

The network item shows the interface macOS routes traffic through: Wi-Fi by its signal,
Ethernet by a wired glyph, and a dim icon when nothing routes. A click opens a panel listing
every connected interface. This doc records what Zenith, an unbundled binary run from a
LaunchAgent, can read for it on macOS 27, and what that costs. Probe: `zenith-probe network`
(`Sources/zenith-probe/Network.swift`). Measured on Steve's M3 Pro, macOS 27.0.1 (26A434),
2026-10-07, with release builds and the probe run as a LaunchAgent through `zenith-probe
network launchd`. Wi-Fi was en0 on channel 44, Tailscale was up without an exit node on utun6,
and the UGreen hub's Ethernet, en10, was present with no cable. No Ethernet was connected.

## 1. The primary interface

- SystemConfiguration's dynamic store names it in `State:/Network/Global/IPv4`'s
  `PrimaryInterface`, en0, read in 0.03 ms. Each network service's `State:/Network/Service/<id>/IPv4`
  holds its interface, address and router, all read in 0.14 ms: en0 192.168.1.50 with router
  192.168.1.1, and Tailscale's utun6 100.64.0.1 with itself as router.
- An `NWPathMonitor`'s first path came in 1.5 ms: satisfied, interfaces en0 (wifi, listed
  twice) then utun6 (other), gateway 192.168.1.1. It gives types and no addresses.
- Both named en0 with Tailscale up: utun6 does not hide the real interface while Tailscale
  routes only its own 100.64.0.0/10. Tailscale adds a second default route, scoped to utun6
  (`UCSIg` in `netstat -rn`), which neither source takes as primary.
- In 90 s and 180 s of steady Wi-Fi the store notified nothing, while the path monitor sent
  an update at 86.8 s with nothing changed.
- `SCNetworkInterfaceCopyAll` gives each hardware interface's type in 2.1 ms: en0 IEEE80211,
  en10 Ethernet ("AX88179A"), en1 to en3 Ethernet ("Thunderbolt 1" to "3", the Thunderbolt
  Bridge's members), bridge0 Bridge. Tunnels are not listed.

Zenith takes the store: one source gives the primary interface, every service's address and
router, and notifications on the main run loop, and it stayed silent while nothing changed.
The path monitor would still need the store for addresses. When the primary interface is not
hardware, as a Tailscale exit node or a full tunnel VPN would make it (Steve has WireGuard and
ProtonVPN services), Zenith shows the first hardware service with a router in the user's
service order, `Setup:/Network/Global/IPv4`'s `ServiceOrder`, since the tunnel's own traffic
leaves through it. That case is untested.

## 2. What CoreWLAN gives

`CWWiFiClient.shared().interface()` answered the probe, from the terminal and from launchd:
interface en0, power on, mode station, RSSI -44 dBm, noise -93 dBm, transmit rate 1200 Mb/s,
channel 44, and the 44 known networks. airportd logged `MISSING ENTITLEMENT, but allowing
anyway` for `com.apple.developer.networking.wifi-info` and its private entitlements: it
answers an unentitled process. Reads, median of 50:

| Read | Time |
|---|---|
| `CWWiFiClient.shared()`, the first time | 0.8 to 1.7 ms |
| `powerOn()`, `noiseMeasurement()`, `transmitRate()`, `ssid()` | 0.2 to 0.46 ms each |
| `rssiValue()` | 2.4 to 2.5 ms |

## 3. The Wi-Fi network's name

- `ssid()` and `bssid()` give nil. airportd asks locationd for the caller's authorization by
  its audit token and logs "Filtering BSSID, country code, and SSID from scan results because
  location services not authorized for pid ...". The store's
  `State:/Network/Interface/en0/AirPort` holds an empty `SSID_STR`, and `ipconfig getsummary
  en0` prints `<redacted>`.
- locationd keys a bare executable by its path: client key
  `com.apple.locationd.executable-<path>`, status `kCLClientAuthorizationStatusNotDetermined`,
  the same from the terminal and from launchd. A copy linked with an Info.plist embedded by
  `-sectcreate __TEXT __info_plist`, with a `CFBundleIdentifier` and
  `NSLocationUsageDescription`, reported that identifier through `Bundle.main`, and locationd
  still keyed it by path, not determined.
- Not determined means nobody has been asked. The name needs Zenith to call
  `requestWhenInUseAuthorization()` and Steve to allow it at the prompt. The probe asked for
  nothing, so whether macOS shows that prompt for a client keyed by path, and whether the
  grant survives `script/install.sh` replacing the binary at the same path, is untested.
- Creating a `CLLocationManager` and reading its `authorizationStatus` registered the
  executable as a locationd client without a prompt. Whether that lists it in System
  Settings' Location Services was not checked.
- `configuration().networkProfiles` gave all 44 known networks' names without authorization,
  with nothing marking the joined one. Zenith does not guess from them.

## 4. Events

- CoreWLAN's link quality events reached the LaunchAgent on CoreWLAN's own queue, off the
  main thread, on a 5.02 s grid and only when the RSSI changed: 16 in 180 s, 6 in 90 s, 4 in
  60 s. No power, link, SSID, BSSID or mode event came, as nothing changed.
- An event's RSSI read -36 to -38 dBm while `rssiValue()` in the same handler read -43 to
  -44, so Zenith reads `rssiValue()` on each event and shows one scale. The read took 3.7 to
  5.7 ms there.
- Sleep and wake did not happen during the runs.

`zenith-probe network cost`, three runs of 60 to 90 s a mode, the modes taking turns in 5 s
stretches. CPU a second:

| Mode | Probe | airportd |
|---|---|---|
| Idle, its first stretch holding the probe's start | 1.9 to 3.4 ms | 3.9 to 5.3 ms |
| Every CoreWLAN event but link quality | 0.7 to 1.0 ms | 3.8 to 6.7 ms |
| Link quality events | 0.64 to 0.72 ms | 3.1 to 7.2 ms |
| `rssiValue()` once a second | 1.1 to 1.2 ms | 5.4 to 6.2 ms |
| The store's notifications | 0.70 ms | 4.0 ms |
| An `NWPathMonitor` | 0.70 ms | 5.2 ms |

airportd runs as root, so the probe reads it through `ps`, to 10 ms; its swings of 3 ms a
second between runs of the same mode are its own noise, and no mode cost it measurably more.
Watching costs the probe nothing above its event loop, and polling the RSSI once a second
costs it 0.5 ms a second more.

## 5. The item

- **State** (`Network`, `Sources/zenith/Network.swift`): the store's notifications for
  `State:/Network/Global/IPv4` and every service's IPv4 key read the services, their hardware
  kinds and the primary interface again; CoreWLAN's power, link and link quality events read
  the Wi-Fi's power and RSSI again, about 3 ms an event, at most one every 5 s. A wake reads
  both, and an interrupted connection to airportd monitors again. Nothing polls. Installed, Zenith
  spent 150 ms of CPU in 120 s with everything else it runs, 1.25 ms a second, and logged no
  error.
- **Icon** (`networkIcon`, `Sources/ZenithCore/Network.swift`). On Wi-Fi, the SF Symbol `wifi`
  as the native menu bar draws it, its arcs filled by level, in Android's five steps from -100
  to -55 dBm (`wifiLevel`), drawn at 14 pt, about 12 pt tall as the battery (16 pt outweighed the speaker), and cropped to its ink
  (`Sources/zenith/Symbols.swift`). On Ethernet, Material Design's `ethernet` from Nerd Fonts,
  Omarchy 4's glyph, as SF Symbols has no Ethernet port. With nothing routing, all dim:
  `wifi.slash` when Wi-Fi is off, `wifi.exclamationmark` when it is on, and `lan_disconnect`
  on a Mac without Wi-Fi. Any interface of Ethernet type counts as Ethernet, USB and
  Thunderbolt adapters included. Omarchy 4's own Wi-Fi glyphs, Material's `wifi_strength`
  wedges, looked wrong beside the SF speaker; Steve chose the SF arcs on 2026-10-07.
- **Redraws:** the bar renders only when the icon or its color changes. The RSSI moves every
  few seconds and the level rarely.
- **Place:** from the bar's right end, the calendar, the battery, the network, then the
  volume, the native menu bar's order with the network in Wi-Fi's place.
- **Panel:** a left click opens the plugin panel (`Popup`) with every service that has an
  address on hardware, the primary first and marked "primary", each under its service name and
  interface, as "Wi-Fi · en0 · primary": Wi-Fi with its signal as a meter labelled with the
  network's name, or "Signal" without it, and each with its address and router. It reads
  when it opens and again at each change while open. It changes nothing.

## 6. Untested

Steve's machine was in use on Wi-Fi alone, so the probe changed nothing. Untested: Ethernet
connected, alone or with Wi-Fi; a cable unplugged; Wi-Fi off, or on and joined to nothing;
changing or roaming networks; sleep and wake; airportd restarting; a Tailscale exit node or a
full tunnel VPN as primary; iPhone USB tethering, which the item would show as Ethernet if
its interface is of Ethernet type. `zenith-probe network watch` logs all of these as they
happen.
