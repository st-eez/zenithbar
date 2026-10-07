# The network item

The network item shows the interface macOS routes traffic through: Wi-Fi by its signal,
Ethernet by a wired glyph, and a dim icon when nothing routes. A click opens the network
panel, modelled on Omarchy 4's, so Steve needs the native menu bar for nothing on Wi-Fi. This
doc records what ZenithBar, an unbundled binary run from a LaunchAgent, can read and do for
them on macOS 27, and what that costs. Probes: `zenithbar-probe network`
(`Sources/zenithbar-probe/Network.swift`, `Sources/zenithbar-probe/NetworkPanel.swift`) and
`zenithbar-probe focus` (`Sources/zenithbar-probe/Focus.swift`). Sections 1 to 5: Measured on Steve's M3 Pro, macOS 27.0.1
(26A434), 2026-10-07, with release builds and the probe run as a LaunchAgent through
`zenithbar-probe network launchd`. Wi-Fi was en0 on channel 44, Tailscale was up without an
exit node on utun6, and the UGreen hub's Ethernet, en10, was present with no cable. No
Ethernet was connected.

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

ZenithBar takes the store: one source gives the primary interface, every service's address
and router, and notifications on the main run loop, and it stayed silent while nothing
changed. The path monitor would still need the store for addresses. When the primary
interface is not hardware, as a Tailscale exit node or a full tunnel VPN would make it
(Steve has WireGuard and ProtonVPN services), ZenithBar shows the first hardware service
with a router in the user's service order, `Setup:/Network/Global/IPv4`'s `ServiceOrder`,
since the tunnel's own traffic leaves through it. That case is untested.

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
- Not determined means nobody has been asked. The name needs ZenithBar to call
  `requestWhenInUseAuthorization()` and Steve to allow it at the prompt. The probe asked for
  nothing, so whether macOS shows that prompt for a client keyed by path, and whether the
  grant survives `script/install.sh` replacing the binary at the same path, is untested.
- ZenithBar asks (`requestWhenInUseAuthorization()`) only when Steve clicks Allow beside the
  panel's "NETWORK NAMES NEED LOCATION SERVICES", which shows while nobody has answered.
  From the bare executable with that Info.plist linked in, on 2026-10-07, Steve clicked Allow
  in the installed panel and macOS showed no prompt. So `script/install.sh` now installs a
  signed `/Applications/ZenithBar.app` with `Resources/Info.plist`
  (`NSLocationUsageDescription`, `LSUIElement`), which Location Services can name and
  remember, as it does Kosmos's bundle for Accessibility. Whether that prompts, and whether
  the grant survives a reinstall signed with the same certificate, is next.
- Creating a `CLLocationManager` and reading its `authorizationStatus` registered the
  executable as a locationd client without a prompt. Whether that lists it in System
  Settings' Location Services was not checked.
- `configuration().networkProfiles` gave all 44 known networks' names without authorization,
  with nothing marking the joined one. ZenithBar does not guess from them.

## 4. Events

- CoreWLAN's link quality events reached the LaunchAgent on CoreWLAN's own queue, off the
  main thread, on a 5.02 s grid and only when the RSSI changed: 16 in 180 s, 6 in 90 s, 4 in
  60 s. No power, link, SSID, BSSID or mode event came, as nothing changed.
- An event's RSSI read -36 to -38 dBm while `rssiValue()` in the same handler read -43 to
  -44, so ZenithBar reads `rssiValue()` on each event and shows one scale. The read took 3.7
  to 5.7 ms there.
- Sleep and wake did not happen during the runs.

`zenithbar-probe network cost`, three runs of 60 to 90 s a mode, the modes taking turns in 5
s stretches. CPU a second:

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

- **State** (`Network`, `Sources/zenithbar/Network.swift`): the store's notifications for
  `State:/Network/Global/IPv4` and every service's IPv4 key read the services, their
  hardware kinds and the primary interface again; CoreWLAN's power, link and link quality
  events read the Wi-Fi's power and RSSI again, about 3 ms an event, at most one every 5 s.
  A wake reads both, and an interrupted connection to airportd monitors again. Nothing
  polls. Installed, ZenithBar spent 150 ms of CPU in 120 s with everything else it runs,
  1.25 ms a second, and logged no error.
- **Icon** (`networkIcon`, `Sources/ZenithBarCore/Network.swift`), solid as the bar's other
  icons (overview.md, icons). On Wi-Fi, the SF Symbol `wifi` as the native menu bar draws
  it, its arcs filled by level, in Android's five steps from -100 to -55 dBm (`wifiLevel`),
  at 14 pt, about 12 pt tall as the battery (16 pt outweighed the speaker). On Ethernet,
  Material Design's solid `ethernet` from Nerd Fonts at 16 pt, Omarchy 4's glyph, as SF
  Symbols has no Ethernet port. With nothing routing, all dim: `wifi.slash` when Wi-Fi is
  off, `wifi.exclamationmark` when it is on, and `network.slash` on a Mac without Wi-Fi.
  Each is cropped to its ink (`Sources/zenithbar/Symbols.swift`). Any interface of Ethernet
  type counts as Ethernet, USB and Thunderbolt adapters included. Omarchy 4's Material Wi-Fi
  wedges looked wrong beside the SF speaker; Steve chose the SF arcs on 2026-10-07.
- **Redraws:** the bar renders only when the icon or its color changes. The RSSI moves every
  few seconds and the level rarely.
- **Place:** from the bar's right end, the calendar, the battery, the network, then the
  volume, the native menu bar's order with the network in Wi-Fi's place.
- **Panel:** a left click opens the network panel (section 6).

## 6. The panel

Measured on 2026-10-07 with the Mac on Ethernet, en6, a Thunderbolt adapter at 1000baseT, as
primary, and Wi-Fi, en0, joined to the same network on channel 140 (5 GHz).

### What it shows

Omarchy 4's network panel (`shell/plugins/panels/network/Panel.qml`, `Model.js`), as Steve's
Omarchy machine showed it on Ethernet, with what Steve chose of it on 2026-10-07:

- **Header:** the connection's icon large, the bar's (section 5), and its title: the Wi-Fi
  network's name with its band, "Home (5ghz)", or "Ethernet (1gbit)" with the link speed, as
  Omarchy writes them (`networkTitle`, `Sources/ZenithBarCore/NetworkPanel.swift`). Under
  it Omarchy's caption, one of its connection phrases every 2.8 s, or "NOT CONNECTED". At
  the right, the speed test and, on a Mac with Wi-Fi, the Wi-Fi switch.
- **Figures** for the primary interface, two pairs a row: Ping and Packet Loss to 1.1.1.1,
  Omarchy's internet target; Router Ping and Router Loss; Receiving and Sending; Downloaded
  and Uploaded, the interface's totals since it came up; IP Address and Gateway, each with a
  copy button. Ping is the mean of the last 5 echoes answered, loss the share of the last 24
  lost, as Omarchy's (`PingHistory`). Each reads "--" until its first sample, so nothing
  moves when the samples come.
- **Speed test:** a line over the figures while it runs, "Testing… 6s" with the capacities so
  far, then its result, dimmed after an hour, until ZenithBar restarts.
- **Wi-Fi networks,** on a Mac with Wi-Fi, under a divider, whichever interface is primary:
  the last scan's results at once (`cachedScanResults`), then a scan's. One row a name, its
  strongest access point, the joined network first, then known ones, then by signal, under
  "KNOWN NETWORKS" and "OTHER NETWORKS" (`wifiRows`, `wifiSection`). Each row has the bar's
  `wifi` symbol filled to its signal, its name or "Hidden", a lock when it needs a password,
  and its status: Connected, Connecting…, Disconnecting…, Forgetting…, or the failure. The
  list scrolls past 240 pt.
- **Clicks,** as Omarchy's: on the joined network, it leaves it; on a secured network the Mac
  does not know, a password field opens in the row; on any other, it joins without a
  password. On a known network not joined, Forget shows on hover in the lock's place. While
  one action runs the other rows wait. A wrong password, saved or typed, opens the field
  again. An enterprise network the Mac does not know says to join it in System Settings once,
  as it needs a user name too.
- Left out, as Steve chose: Omarchy's DNS provider buttons, band locking and QR sharing.

### Reading

- **Counters and link speed:** the kernel's interface list with 64-bit counters
  (`sysctl` `NET_RT_IFLIST2`) gives each interface's bytes in and out and `ifi_baudrate`:
  en6 1,000,000,000 b/s, Wi-Fi en0 358,560,000 (its transmit rate), the adapters without a
  link 0. SystemConfiguration's media options agree for en6 (1000baseT, full duplex). A read
  of one interface took 0.6 ms of CPU, most of it walking every interface's record.
- **Ping:** an ICMP echo over a datagram socket (`socket(AF_INET, SOCK_DGRAM,
  IPPROTO_ICMP)`), which macOS lets a process without privileges open, its reply coming
  with the IP header. Both echoes of a sample took 0.36 ms of CPU and about 4 ms to come
  back: the router 0.7 to 1.3 ms, 1.1.1.1 3.9 to 5.0 ms. Running `/sbin/ping` twice took
  160 to 180 ms a sample and 9.8 ms of the probe's CPU, without its children's.
  `zenithbar-probe network stats` (30 s): 20 samples, none lost.
- **Band:** `wlanChannel().channelBand` without Location Services: 5 GHz, channel 140.
- **Scan:** `scanForNetworks(withSSID: nil)` took 6.9 s and found 4 networks, the cached
  results held 19, all without names (section 3), so the panel shows the cached ones first
  and scans on a queue of its own. The known networks' names come from
  `configuration().networkProfiles`, which needs no authorization: 44.
- Reads of the SSID, band, known networks and Location Services' answer each ask airportd or
  locationd, so the panel reads them when it opens, at each network change and after each
  action, not at each sample.

### Doing

- **Power:** `setPower(true)` with the power on returned no error from the unentitled probe,
  which suggests airportd lets ZenithBar set it. airport's preferences hold no
  `RequireAdmin` keys, so System Settings asks no password to turn Wi-Fi on or off. Turning
  it off is untested.
- **Forget:** through `networksetup -removepreferredwirelessnetwork en0 <name>`. Steve's user
  is an admin, and networksetup says it needs admin privileges, or root when System Settings
  requires a password for system wide preferences. For a name it did not know it answered "not
  found in the preferred networks list" in 92 ms with no prompt. Removing a known network is
  untested, so whether that prompts is unconfirmed.
- **Join and leave:** CoreWLAN's `associate(to:password:)`, with no password for an open or
  known network, which airportd joins from its own keychain item, and `disassociate()`, as the
  native menu's Disconnect. Both untested.
- **Speed test:** `/usr/bin/networkQuality --json`, an option its help lists and its man page
  does not, prints one JSON object a line about every 200 ms: `downlink_capacity_mbps`,
  `uplink_capacity_mbps`, `downlink_responsiveness_rpm` and the bytes moved so far, then a
  summary over several lines, whose last line is "}" (`SpeedTestOutput`). On Steve's Ethernet a
  run took about 23 s and moved about 200 MB down and 400 MB up by 17 s; the panel's run read
  97.7 Mbps down, 183 Mbps up, 173 RPM. Whose keys the summary has is unread: the first run
  was cut off before it and the second logged only its last line. ZenithBar now logs the
  output's last 2000 bytes when a run ends. Two runs in all, as Steve asked.

### Focus

The panel takes the keyboard only while the password field is open, and gives it back when
the field closes (`Popup.takeKeyboard`, `Popup.giveKeyboardBack`).

- `zenithbar-probe focus`, with Ghostty front: a nonactivating panel at the pop up menu level
  that allows key became key on `makeKey()` with its secure field first responder.
  WindowServer's front process stayed Ghostty, by `_SLPSGetFrontProcess` and NSWorkspace,
  while it sent keys to the probe (`SLPSGetKeyFocusProcess`), as Raycast's panel does. "ab"
  posted to the probe's own process reached the field. AppKit called the probe active
  meanwhile (`NSApp.isActive`), with no change macOS showed elsewhere.
- Nothing public hands key to another app. Ordering the panel out and in again with key
  refused gave keys back to Ghostty at once, the panel still shown, and ordering it out did
  the same.
- Kosmos (its docs/focus.md and docs/focus-follows-mouse.md) tracks key reports of regular
  apps only, and ZenithBar is an accessory app, so the panel taking key changes no focus
  intent. While ZenithBar holds the key window apart from the front app, Kosmos's focus
  follows mouse focuses nothing (`UserInput.keyHolderApartFromFront`), so moving the
  pointer out of the panel while typing keeps the keyboard there. Kosmos logged no focus
  change during the probe.
- The secure field turns on Secure Input while it holds the keyboard: Kosmos logged "secure
  input on" as the field became key and "off" as it gave keys back, both within the second.
  Kosmos's hotkeys stop meanwhile (Kosmos's docs/hotkeys.md), as for any password field.
  The probe ran from Ghostty, which Kosmos named as the holder; ZenithBar runs from launchd.
- **Closing:** the panel closes 50 ms after the pointer leaves it and its item, as the plugin
  panel does, except while someone types in it. A click in another app's window takes key
  from it, and then it closes unless the pointer is on it. Escape closes the field, gives
  keys back and closes the panel if the pointer is off it. Return joins, and the panel stays
  until the join ends, then closes if the pointer is off it.

### The pieces

The panel is built from views in `Sources/zenithbar/PanelKit.swift`, for the sound panel to
reuse: `PanelLabel`, `PanelButton` (an SF Symbol), `CopyButton`, `PanelSwitch`, `PanelRow`,
`ScrollList`, `PasswordField` and `PanelDivider`, each drawn in the theme's colors and the
bar's font, solid, and each taking the first click, as the panel is never active. `Popup`
(`Sources/zenithbar/Panel.swift`) hosts either a plugin's page or such a view in one
`NSPanel` with the plugin panel's fill and 2 pt accent border, under its item, and places it
again when its height changes. Not NSPopover or NSMenu, whose material the theme cannot
color ([plugins.md](plugins.md)).

Without a pointer, `zenithbar-probe send <command>` drives a debug build's panels through a
distributed notification it watches (`Controller.watchTestHooks`): `open network`, `close`,
`network speedtest`, `network allow` and `network password <name>`. Release builds, which
`script/install.sh` installs, leave the observer out, as any local process can post the
notification unauthenticated. The captures above came from `open network` and
`screencapture -x`, while an installed build still had the hook.

### Cost

Installed, ZenithBar spent 0.13 ms of CPU a second with the panel closed and 6.7 to 7.2 ms
with it open on Ethernet, over 30 s each (`proc_pid_rusage`). A 1 ms sample of its main
thread put most of the open panel's time in Core Animation drawing the changed labels
(about 2.8 ms a second) and in the panel's update (about 1 ms); the sampler's queue spends
about 1 ms a sample. Before the symbols were kept once drawn, the open panel spent 12 ms a
second, as each update cropped the header's symbol to its ink again. Nothing runs while it
is closed: the sampler, the phrases and the scan stop, and the figures start fresh at the
next open. Footprint: 65 MB resident, with every display's bar.

## 7. Untested

Steve's machine was in use, so the probes changed nothing. On 2026-10-07 Ethernet was
primary with Wi-Fi joined too, and the item showed the Ethernet glyph. Untested: Ethernet
alone; a cable unplugged; Wi-Fi off, or on and joined to nothing;
changing or roaming networks; sleep and wake; airportd restarting; a Tailscale exit node or
a full tunnel VPN as primary; iPhone USB tethering, which the item would show as Ethernet if
its interface is of Ethernet type. `zenithbar-probe network watch` logs all of these as they
happen.

The panel, untested on 2026-10-07: joining a network, known or with a typed password;
leaving one; forgetting one, and whether networksetup prompts then; turning Wi-Fi off and on
from the switch; a wrong password; an enterprise network; the list and its rows with names,
which need Location Services (section 3); the password field taking and giving back the
keyboard inside ZenithBar, which the probe showed for its own panel; and the speed test's
summary keys.
