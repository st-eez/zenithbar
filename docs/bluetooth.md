# Bluetooth

The Bluetooth item and panel, modelled on Omarchy 4's Bluetooth panel
(`shell/plugins/panels/bluetooth/Panel.qml`, `Model.js`), kept simple at Steve's request: the
panel connects and disconnects paired devices and turns Bluetooth on and off, and Steve pairs
and forgets devices in System Settings. This doc records what macOS gives ZenithBar for
Bluetooth on macOS 27, what it costs, what needs permission, and what the item and the panel
do. Probe: `zenithbar-probe bluetooth` (`Sources/zenithbar-probe/Bluetooth.swift`). Measured on
Steve's M3 Pro, macOS 27.0.1, 2026-10-07, with Bluetooth on and none of the 7 paired devices
connected.

## 1. What macOS gives

`zenithbar-probe bluetooth read`, run from Ghostty:

| Source | Gives | Permission | Cost, release build |
|---|---|---|---|
| `system_profiler SPBluetoothDataType -json` | the controller's state (`attrib_on`), each paired device under `device_connected` or `device_not_connected` with its address, vendor and product IDs, minor type, and battery levels | none | 143 ms, 41 ms of CPU, median of 20 |
| IOBluetooth `IOBluetoothDevice.pairedDevices()` | each paired device's name, address, `isConnected()`, class | Bluetooth | 0.75 ms with every name and connection |
| `IOBluetoothPreferenceGetControllerPowerState`, private | 1 on, 0 off | Bluetooth | 40 ms the first call, then under 0.01 ms |
| CoreBluetooth `CBManager.authorization` | the permission's answer, without asking | none | |

- **Permission:** IOBluetooth, the private power call included, opens a session with
  bluetoothd, which asks tccd for `kTCCServiceBluetoothAlways` on behalf of the responsible app,
  as the unified log showed for the probe: Ghostty was responsible, and Ghostty is allowed.
  Ghostty runs under the hardened runtime with no Bluetooth entitlement and only
  `NSBluetoothAlwaysUsageDescription`, and tccd records its grant as user consent, so the
  hardened runtime needs no entitlement for Bluetooth, unlike Location. The hardened runtime's
  resource entitlements list none for Bluetooth; `com.apple.security.device.bluetooth` is the
  App Sandbox's. ZenithBar's `Resources/Info.plist` carries the usage string.
- **Reading the answer does not ask:** the installed ZenithBar read `CBManager.authorization` at
  launch, 0, not determined; tccd logged the request with `Auth Right: Unknown`, `DB
  Action:None`, and no prompt showed on any display.
- **Device types:** system_profiler gives the minor type for every device, Bluetooth LE ones
  too: Keyboard for the AULA F75Max, Mouse for the MX Master 2S, Gamepad for both Xbox
  controllers, Headphones for the AirPods and the Beats. IOBluetooth's class reads 0 for the LE
  devices. "steez", 00:1A:2B:3C:4D:01, has neither, only an RSSI.
- **Battery levels:** system_profiler gives the AirPods' `device_batteryLevelLeft`, `Right` and
  `Case` while they are not connected: 100%, 100% and 21%, the last levels it heard. IOBluetooth's
  private `batteryPercentLeft`, `Right` and `Case` read 34, 38 and 41 at the same moment, so both
  keep old levels for a device away. ZenithBar shows a battery only for a connected device, the
  lowest of its levels other than a case's, then the case's, as System Settings does ("100% ·
  Case 6%"). Connected, on 2026-10-08, the AirPods' own entry (7C:1A:2B:3C:4D:03, `< AACP >`)
  read left and right 100% and case 6%, as System Settings showed. That system_profiler
  names other devices' levels `device_batteryLevelMain`, as the parser expects of any
  `device_batteryLevel` key, is unconfirmed, as is IORegistry's `BatteryPercent` for Apple's
  HID devices, as Steve has none paired.
- **Glyphs:** JetBrainsMono NF has U+F00AF, U+F00B1 and U+F00B2, Material's Bluetooth, Bluetooth
  connected and Bluetooth off, which Omarchy's item shows. SF Symbols has no Bluetooth logo.

## 2. Writes

- **Power:** macOS has no public call to turn Bluetooth on or off. ZenithBar calls
  `IOBluetoothPreferenceSetControllerPowerState`, private and undocumented, which blueutil
  calls; if a macOS update drops it, the switch does nothing. `zenithbar-probe bluetooth noop`
  set it to 1 while on: it returned at once and the power read 1 after. Turning it off and on
  is untested, as Steve asked that Bluetooth stay on.
- **Connect and disconnect:** IOBluetooth's `openConnection(_:)`, which answers through
  `connectionComplete(_:status:)`, and `closeConnection()`, which blueutil uses too.
  `closeConnection()` on the Beats, not connected, returned 0 at once and changed nothing.
  Neither was tried on a connected device or to connect one. IOBluetooth's connections are
  Bluetooth Classic's, so connecting an LE device such as the MX Master may fail; ZenithBar logs
  the failure and the row stops waiting.

## 3. Events and cost

- `zenithbar-probe bluetooth watch`: on registering, IOBluetooth posted
  `IOBluetoothHostControllerPoweredOnNotification` and CoreBluetooth reported state 5, powered
  on. Nothing else came in 15 s, as nothing connected. IOBluetooth's connect notification
  (`IOBluetoothDevice.register(forConnectNotifications:selector:)`) calls once for each device
  connected when it registers, then for each new connection, and each device's own disconnect
  notification for its going; neither fired, as none connected.
- `zenithbar-probe bluetooth cost 120`, idle and listening in 5 s stretches taking turns, each
  after a second to settle: the probe spent 0.16 to 0.67 ms a second idle and 0.16 to 0.72
  listening, and bluetoothd 0 to 3.8 and 0 to 5.6, within `ps`'s 2 ms a second steps over a
  stretch with the Mac in use. Listening costs nothing measurable. Registering took 4 to 6 ms,
  81 to 91 ms the first time.
- **What ZenithBar does with them:** it reads system_profiler at launch, after a wake, when the
  panel opens, and after each event: CoreBluetooth's state, which changes with the power, and
  IOBluetooth's connections. Each event reads now and again 2 s later, as system_profiler may
  lag the event and AirPods report their batteries after connecting; both unconfirmed, as
  nothing connected. One read runs at a time, off the main thread. Nothing polls.
- **Find My's quarter hours:** about every 15 minutes, as bluetoothd gives Find My's devices
  new addresses, it drops the old device record and forces its disconnection for every app
  with a Bluetooth session, and IOBluetooth calls ZenithBar's connect notification for a
  device with no address, no name, not connected and not paired (logged on 2026-10-08 at
  16:30:04; bluetoothd logged the same at :00, :15, :30 and :45 of most hours that day).
  ZenithBar ran system_profiler twice for each, about 8 times an hour with nothing
  connecting. A connect notification for a device without an address now reads nothing, as
  no row is keyed by one.
- **Before the permission:** without Bluetooth permission ZenithBar starts neither CoreBluetooth
  nor IOBluetooth, so the item follows only launches, wakes and the panel opening. The panel's
  first open starts CoreBluetooth, which makes macOS ask; once allowed, the events start, and
  they start at each launch after.

## 4. The item

- **Glyph** (`BluetoothState.icon`, `Sources/ZenithBarCore/Bluetooth.swift`): Omarchy's three,
  at 16 pt in JetBrainsMono NF and cropped to its ink, as the Ethernet glyph: on, U+F00AF; a
  device connected, U+F00B1; off, U+F00B2, dim. A Mac without a controller shows none.
- **Place,** as Omarchy's: the agents gauge, the microphone, the speaker, Bluetooth, the network,
  the battery and the clock.
- **Clicks:** a left click opens or closes the panel. Omarchy's right click, which turns
  Bluetooth on or off, is left out.

## 5. The panel

- **Header:** the item's glyph at 28 pt, dim while off; "Bluetooth" in bold; under it, dim, in
  capitals spaced 1.2 pt, Omarchy's phrases, one every 2.8 s while on (`bluetoothPhrases`):
  Untangling wires, Streaming vikings, Pairing mysteries, Herding headsets, Taming radios,
  Summoning speakers, Wrangling codecs, Polishing packets; "Turned off" while off. At the right,
  the power switch, which moves at the click and goes back after 10 s if the power never
  changes.
- **CONNECTED:** connected devices on the current row's fill, each with its icon and its battery
  under its name. A click disconnects it.
- **Left out:** a device with neither a product ID nor a type, as System Settings leaves it
  out. On 2026-10-07 the panel showed the AirPods as connected from such an entry, their
  Bluetooth LE link for batteries and proximity (`< BLE >` services, an address that changed
  between reads) while the AirPods themselves (7C:1A:2B:3C:4D:03) were not connected, and a
  paired "steez" with no type that System Settings does not list.
- **MY DEVICES:** paired devices not connected, under System Settings' name for them, as
  AVAILABLE read as nearby when most were not (Steve, 2026-10-07): a Mac cannot tell a paired
  device is in range without connecting. A click connects one. Omarchy calls these PAIRED and
  lists devices a scan finds under AVAILABLE; ZenithBar scans for nothing, Steve's choice.
- **Rows:** by name; a device whose name is empty or an address is left out, as Omarchy's
  `hasHumanName`. Icons (`bluetoothSymbol`): AirPods by their model, from the sound panel's
  product table ([sound.md](sound.md), AirPods), then by minor type: `headphones`,
  `keyboard.fill`, `computermouse.fill`, `gamecontroller.fill`, `hifispeaker.fill`, `iphone`;
  else the Bluetooth glyph. While a click waits, the row reads "Connecting…" or
  "Disconnecting…" and the other rows wait, until the device gets there, the call fails, or 20
  s pass, as Omarchy's `pendingTimeout`. Each list scrolls past 400 pt, as Omarchy's.
- **Off:** the lists give way to "Turn Bluetooth on to connect"; with nothing paired, "No paired
  devices; pair them in System Settings".
- **Permission:** a click on a row or the switch before Bluetooth is allowed asks again if
  macOS has not asked, and opens System Settings' Bluetooth privacy pane if Steve denied it.
- **Left out,** Steve's choice: scanning, pairing and Forget, which System Settings does.
- **Look:** 380 pt wide, built from PanelKit's labels, switch, rows, lists and dividers, as the
  sound panel ([network.md](network.md), the pieces).
- **Module** (`BluetoothModule`, `Sources/zenithbar/BluetoothModule.swift`): the item and its
  panel, from `Bluetooth`'s state ([overview.md](overview.md), modules).
- **Test hooks,** debug builds only (`Controller.watchTestHooks`, and `BluetoothModule.test` for
  `bluetooth`): `open bluetooth`, `close`,
  and `bluetooth connected <percent> <name>`, which draws a paired device connected until the
  next read, for captures without connecting it. The panel was captured from a debug build on
  2026-10-07 with the AirPods and the MX Master drawn connected.
- **Ceiling:** the sound panel asks system_profiler on its own for AirPods' models
  (`Sound.lookUpBluetooth`). Were the extra 140 ms read to matter, it could take `Bluetooth`'s
  devices.

## 6. Cost

Installed, release build, panel closed, Bluetooth not yet allowed and so with no Bluetooth
listener: ZenithBar spent 100 ms of CPU in 120 s, 0.83 ms a second, with everything it runs, at
48 MB resident, while Discord's microphone test kept the sound listeners busy; sound.md's 0.33
ms a second was read with nothing recording. Bluetooth's share while closed is the launch's
system_profiler reads, about 41 ms of the child's CPU each, and once allowed the listeners, which
cost nothing measurable (section 3). Allowed, with nothing connected, a launch read three times
on 2026-10-08: its own read, CoreBluetooth's first state, and that state's read 2 s later. Each open of the panel adds one read, about 41 ms of CPU off the
main thread, and the phrases' timer, a caption redraw every 2.8 s. The open panel's own cost
was not measured installed, as opening it needs a click and release builds have no test hook.

## 7. Untested

On 2026-10-07 no device was connected, Bluetooth stayed on, and nothing connected or
disconnected, as Steve asked. Untested: the permission prompt on the panel's first open, and
the events after it is allowed; connecting and disconnecting from the panel, AirPods and the
Beats (Classic) and the MX Master and AULA keyboard (LE); the connect and disconnect
notifications and the item's connected glyph following them; system_profiler's timing against
those notifications; a connected device's battery; turning Bluetooth off and on from the
switch, the CoreBluetooth state change and the item's dim glyph; a Mac without a controller.
