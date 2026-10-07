# Sound

The speaker item, the microphone item and the sound panel, modelled on Omarchy 4's audio panel
(`shell/plugins/panels/audio/Panel.qml`, `Model.js`) and microphone widget
(`shell/plugins/bar/widgets/Microphone.qml`), so Steve needs the native menu bar and Control
Center for nothing on sound. This doc records what CoreAudio gives ZenithBar on macOS 27, what
it costs, and what the items and the panel do. Probe: `zenithbar-probe sound`
(`Sources/zenithbar-probe/Sound.swift`). Measured on Steve's M3 Pro, macOS 27.0.1 (26A434),
2026-10-07, with the Mac in use: Spotify and Moonlight playing through the speakers, nothing
recording.

## 1. The devices

`zenithbar-probe sound read` lists every device CoreAudio lists (`kAudioHardwarePropertyDevices`),
none hidden:

| Device | Transport | Directions | Can be default | Volume | Mute | Data source |
|---|---|---|---|---|---|---|
| ASUS VA24E, LG ULTRAWIDE | `hdmi` | output | yes | none | none | none |
| MacBook Pro Speakers | `bltn` | output | yes | 0.31, settable | settable | `ispk` only |
| MacBook Pro Microphone | `bltn` | input | yes | 0.59, settable | settable | `imic` only |
| Microsoft Teams Audio | `virt` | both | no, either way | settable | settable | one, 0 |

- The monitors have neither a volume nor a mute, as Steve's VG279QE5A monitors did on
  2026-10-06 ([overview.md](overview.md)): their level is set on the monitor.
- Microsoft Teams Audio is a virtual device, `kAudioDeviceTransportTypeVirtual`, that macOS
  will not make the default output or input (`kAudioDevicePropertyDeviceCanBeDefaultDevice` 0).
- Reads, release build, median of 100: the device list 0.001 ms; every device's name,
  transport, streams each way, volume and mute 2.2 ms; every device's
  `kAudioDevicePropertyDeviceIsRunningSomewhere` 0.23 ms; the audio process list with each
  process's running input 6.9 ms.

## 2. Which app uses a microphone

- `kAudioDevicePropertyDeviceIsRunningSomewhere` on each input device: 0 for the MacBook Pro
  Microphone while nothing recorded, and 1 for the speakers while Spotify and Moonlight played.
- CoreAudio's process objects (`kAudioHardwarePropertyProcessObjectList`) name each audio
  process with its bundle ID, devices and `kAudioProcessPropertyIsRunningInput`. CoreSpeech, the
  Siri listener, read input running with no input device, while the microphone did not run, so
  the process objects would show the microphone always in use. ZenithBar reads the devices.
- ZenithBar appears in the process list with input idle: it opens no stream, so it never turns
  on the orange microphone indicator.
- **Ceiling:** the property covers the whole device, so a device with both directions counts
  as in use while only its output runs: Microsoft Teams Audio, a USB headset, or AirPods while
  their output device carries an input stream (section 4). The upgrade path is the process
  objects' input devices (`kAudioProcessPropertyDevices`, input scope) of processes running
  input, matched by device, as CoreSpeech names none.

## 3. Writes

- `zenithbar-probe sound write "Microsoft Teams Audio"`, three runs: setting its input mute
  and its input volume each returned no error in under 2 ms and fired the listener, and the
  value read back unchanged at once and 300 ms later, mute 0 and volume 1.00. Teams' driver
  takes the write and keeps its own value. The probe restored both and refuses any device that
  is not virtual; it refused the MacBook Pro Microphone.
- No device here shows whether a mute holds, as Steve asked that no real device be written
  while the Mac is in use. That the MacBook Pro Microphone's `kAudioDevicePropertyMute` is
  settable on the input scope, and that a muted device gives every app silence, Discord
  included, is unconfirmed.
- A write elsewhere comes back through the listeners as any change does: the installed bar
  re-read its state after each of the probe's writes to Teams Audio, three reads for the four
  writes, as it reads once for a burst.

## 4. AirPods and headphones

- **What ZenithBar relies on:** a Bluetooth device's CoreAudio UID begins with its address,
  `7C-1A-2B-3C-4D-03:output` and `:input` for Steve's AirPods, as coreaudiod logged when they
  connected on 2026-10-06. `system_profiler SPBluetoothDataType -json` names each paired
  device's address, vendor ID, product ID and minor type, without asking for Bluetooth
  permission, in 62 to 65 ms. Steve's "steez AirPods ANC" read vendor 0x004C, product 0x201B,
  AirPods 4 with noise cancellation, minor type Headphones; his "steez studio beatz" vendor
  0x290B, product 0x0200, Headphones. ZenithBar asks once for each Bluetooth address it has not
  seen, off the main thread (`Sound.lookUpBluetooth`). IOBluetooth needs Bluetooth permission
  ([bluetooth.md](bluetooth.md)), which the sound panel does without.
- **Symbols** (`headphonesSymbol`, `Sources/ZenithBarCore/Sound.swift`, and `airpodsSymbol`,
  `Sources/ZenithBarCore/Bluetooth.swift`, which the Bluetooth panel shares): Apple's product IDs
  give `airpods` (0x2002, 0x200F), `airpods.gen3` (0x2013), `airpods.gen4` (0x2019, 0x201B),
  `airpodspro` (0x200E, 0x2014, 0x2024) and `airpodsmax` (0x200A, 0x201F); all five symbols
  exist on macOS 27. A Bluetooth device named "AirPods" that the table lacks shows `airpods`,
  other Bluetooth headphones by their minor type `headphones`. Names, which Steve can edit,
  count only as the fallback. The table's IDs other than 0x201B come from community lists of
  Apple's product IDs and were not seen here.
- **The headphone jack:** a built-in output whose data source is `hdpn` shows `headphones`, and
  a device named with "headphone", as Apple silicon's "External Headphones", does by name. Only
  `ispk` was listed with nothing plugged in.
- **Calls:** coreaudiod published both AirPods devices on connecting. While an app ran their
  microphone, their input ran at 24 kHz and the output device carried an input stream too
  (`num streams in/out: 1/1`), so both may list under INPUT then. coreaudiod logged no data
  source for them (`datasource in/out 0/0`).

## 5. Events and cost

- `zenithbar-probe sound watch 30`, every device's and process's properties: one event in 30
  s, the speakers' running state at the start. Nothing fires while nothing changes.
- `zenithbar-probe sound cost 120`, idle and listening in 5 s stretches taking turns, after the
  first: the probe spent 0.20 to 2.8 ms a second idle and 0.19 to 0.53 listening, and coreaudiod
  75 to 200 ms a second either way with the players running. Listening costs nothing
  measurable. Registering the probe's 112 listeners took 16 ms; ZenithBar registers about 12.
- Installed, ZenithBar spent 40 ms of CPU in 120 s with the panel closed, 0.33 ms a second,
  with everything it runs, at 50 MB resident.

## 6. The speaker

- **Icon** (`outputSymbol`): the filled SF speaker by volume (`volumeSymbol`), dim and slashed
  while muted, full on an output without a volume; AirPods' or headphones' symbol (section 4)
  when the default output is one, dim while muted.
- **Clicks,** Omarchy's bar table (`shell/plugins/bar/README.md`): a left or middle click opens
  the panel, a right click mutes or unmutes the default output, and scrolling steps its volume
  by 5%. Omarchy's code mutes output and input together on the right click, as its switch does;
  ZenithBar follows the table and mutes the output alone, as the microphone has its own click.
- **Scrolling** (`ScrollSteps`): a mouse wheel's event is one step, a trackpad's scroll one
  step per 12 points, and momentum after the fingers lift nothing, so a flick cannot run the
  volume to an end; up is louder whatever the scroll direction setting. Kept, as it is small
  and unit tested, but untested on screen, as posting a scroll needs the pointer. If it proves
  flaky, drop `BarView.scrollWheel`: the clicks and the sliders cover the same.

## 7. The microphone item

- **Place:** left of the speaker: the agents gauge, the microphone, the speaker, the network,
  the battery and the clock.
- **When** (`SoundState.mic`): live, `mic.fill` in the foreground color, while any input device
  in use is unmuted; muted, `mic.slash.fill` in the theme's alert color, while none is heard and
  a target (below) is muted, even with no app using a microphone; hidden otherwise. A mute set
  elsewhere, as in System Settings, shows, as ZenithBar listens to every input device's mute.
  Drawn at 14 pt and cropped to its ink, as the speaker.
- **Which devices a click mutes** (`micTargets`): the input devices in use, and the default
  input. With a call on, that mutes what the call hears; with none, it mutes the next call's
  microphone, and the item stays as a reminder. While live or unmuted a click mutes every
  target; while muted it unmutes the muted ones. A device without a settable mute is skipped.
- **Clicks,** Omarchy's widget: a left click mutes or unmutes, a middle click opens the sound
  panel under it, and scrolling steps the default input's level by 5%.

## 8. The panel

- **Header:** the speaker's icon at 22 pt, "Audio", and Omarchy's volume name under it, dim, in
  capitals spaced 1.2 pt (`outputVolumeName`): Muted, Silenced, Whisper, Murmur, Easy listening,
  Steady groove, Cranked up, Party mode, Concert hall. At the right, a switch that mutes the
  output and the microphone targets together, on while either is unmuted, as Omarchy's; only
  sides with a mute count, so on the monitors it follows the microphone.
- **OUTPUT and INPUT:** the caption with the percent at the right, the default device's slider,
  then the devices, the default bold and highlighted, each with its icon: `hifispeaker.fill`
  for built-in speakers, `mic.fill` for a built-in microphone, `display` for HDMI and
  DisplayPort, AirPods and headphones as above, `dot.radiowaves.left.and.right` for other
  Bluetooth, `cable.connector` for USB, `airplayaudio` for AirPlay and `iphone` for Continuity.
  A click makes the device the default output or input; the mic item's middle click opens the
  same panel, where INPUT picks the microphone. A slider is disabled on a side without a
  volume, as the monitors', with "--" for its percent; a muted side's slider shows at half
  strength, and a right click on it mutes or unmutes that side, as Omarchy's.
- **Virtual devices,** Steve's choice on 2026-10-07: devices whose transport type is virtual or
  aggregate (`kAudioDeviceTransportTypeVirtual`, `Aggregate`, `AutoAggregate`) are left out of
  the lists, so he never switches to Microsoft Teams Audio by accident. One that is the default
  still shows, highlighted, so he can see it and switch away (`SoundState.listed`).
- **Live:** the panel draws `Sound`'s state, which the bar's listeners keep current: the device
  list and both defaults, the default output's volume, mute and data source, and every input
  device's running state, mute and level (`soundWatches`). So the open panel follows the volume
  keys, System Settings, Control Center and other apps with nothing polling, and needs no
  listener of its own: nothing starts when it opens or stops when it closes. A change in the
  device list or a default adds the new devices' listeners and drops the gone ones', as when
  AirPods connect, leave for another device or take a call.
- **Dragging** (`PanelSlider`): while dragged, the knob follows the pointer alone, and the
  listener's reading of each step waits for after, so the knob does not jump back; the percent
  and the volume name follow the knob. On release the knob keeps the last value until the
  listener reads it back. A drag sets the device it started on, and ends when that device stops
  being the default or goes.
- **Look:** 380 pt wide, in the network panel's fill and border, built from PanelKit's views
  ([network.md](network.md), the pieces) and the slider it adds. Omarchy's input level meter
  and per app mixer are left out: macOS has no volume per app, and a meter would need
  ZenithBar to open the microphone.
- **Test hooks,** debug builds only (`Controller.watchTestHooks`): `open volume`, `close`, and
  `mic live|muted|off|real`, which draws the microphone item that way without an app or a mute,
  for captures.

## 9. Untested

On 2026-10-07, with the Mac in use, nothing changed a real device, the default, or the output's
level. Untested: muting the MacBook Pro Microphone, and that every app then hears silence; a
click on a device row setting the default, and whether macOS moves the alert sound device with
it; dragging a slider and the knob's behaviour at release; scrolling on the items; the panel
following a change Steve makes while it is open, beyond the listener path the probe's writes
showed. AirPods were not connected: their symbol, the system_profiler match, connecting and
leaving while the bar runs and while the panel is open, switching to another Apple device, and
the call profile adding an input stream to their output device, which the unit tests cover as
states (`Tests/ZenithBarCoreTests/SoundTests.swift`); and headphones in the jack.
