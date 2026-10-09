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

- **Elements:** every control ZenithBar writes is on the main element. On 2026-10-07 the
  speakers and the MacBook Pro Microphone had their mute and volume on element 0 only, none on
  channels 1 and 2 (probe of each element). coreaudiod's saved settings show Bluetooth
  outputs, as the AirPods', keep a volume on each channel and one mute on the main element;
  `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` sets the channels together, and the
  mute is on element 0 there too.
- **The MacBook Pro Microphone:** `zenithbar-probe sound write "MacBook Pro Microphone"`,
  which writes only while no process runs the device, on 2026-10-07 at 18:46 with nothing
  recording: its input mute read 1 at once after the write, its listener fired 0.7 ms later,
  it still read 1 300 ms later, and it read 0 after the probe restored it; its volume read
  0.502 before and after. That every app then hears silence is unconfirmed (section 13).
- `zenithbar-probe sound write "Microsoft Teams Audio"`, three runs: setting its input mute
  and its input volume each returned no error in under 2 ms and fired the listener, and the
  value read back unchanged at once and 300 ms later, mute 0 and volume 1.00. Teams' driver
  takes the write and keeps its own value. So a virtual device counts as no microphone
  (`SoundState.microphones`): Teams Audio running, as its IO did on 2026-10-06 at 20:18 in
  coreaudiod's log, held the microphone item live, and every click muted again.
- A write elsewhere comes back through the listeners as any change does: the installed bar
  re-read its state after each of the probe's writes to Teams Audio, three reads for the four
  writes, as it reads once for a burst. ZenithBar writes nothing in answer to a listener but
  `preferBuiltInMic`'s default input (section 10), whose own change reads back as a default that
  is not Bluetooth, so no write echoes.
- **Logs:** ZenithBar logs each write at notice level, which the unified log keeps: the
  control clicked, the device's name, ID and UID, the direction, and the value read before and
  after, with CoreAudio's status. `log show --predicate 'subsystem == "io.github.st-eez.zenithbar"
  AND eventMessage BEGINSWITH "Sound"'` lists them. CoreAudio logs every write too, in the
  process that made it, as `LogVolumeChangeForClientSide` (mute and volume) and
  `HALDefaultDeviceProperty::SetData` (defaults), and coreaudiod as
  `LogVolumeChangeForServerSideControl`: `log show --predicate 'process == "zenithbar" OR
  process == "coreaudiod"' | grep -E 'LogVolumeChange|SetDefaultDevice|SetData'`.

### Steve's glitch on 2026-10-07

Read back from CoreAudio's log of the installed bar (pid 61338) at 18:37 and 18:38:

- 18:37:35 to 18:37:38: the panel's rows made the ASUS VA24E, the LG ULTRAWIDE and the
  speakers the default output in turn. The apps playing took until 18:37:47 to move to the
  speakers, so the sound went to the LG for 9 s: coreaudiod stopped the LG's IO and started
  the speakers' only then. The apps follow the default on their own time; ZenithBar wrote
  each default once.
- 18:38:00 to 18:38:07: the switch muted and unmuted the speakers and the microphone together,
  twice, each write holding (coreaudiod's server side logged each one).
- 18:38:24: the switch muted both. 18:38:30 the microphone item unmuted the microphone, and
  the item hid, as nothing used it. 18:38:32 the switch, on because the microphone was
  audible, muted the microphone alone, the speakers still muted. 18:38:34 the item unmuted it
  again, 18:38:39 the switch muted it again, and 18:38:40 the switch, now off, unmuted both.
  The speakers stayed muted for 16 s while each click on the switch muted the microphone.
- The cause was the switch's rule, Omarchy's: on while the output or the microphone is
  unmuted. It now follows the output (section 9). The volumes Steve set stuck: the
  microphone's last write, 0.502104 at 18:39:20, is what CoreAudio and System Settings read
  (section 5).

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

## 5. Persistence

- ZenithBar writes through CoreAudio's properties, as System Settings and Control Center do,
  so coreaudiod holds each value for every app at once, and keeps it when ZenithBar quits.
  On 2026-10-07, after Steve's drags, System Settings' Sound pane read the input volume slider
  (`InputVolumeSlider`, through accessibility) as 0.5021, CoreAudio as 0.502104, and
  `osascript -e 'get volume settings'` as input volume 50. System Settings shows no input mute.
- coreaudiod saves the mutes and volumes to
  `/Library/Preferences/Audio/com.apple.audio.DeviceSettings.plist`, by device UID and data
  source: the file was last written on 2026-10-06 at 09:11, 4 minutes before the restart at
  09:15, and kept the MacBook Pro Microphone at 0.706 and the speakers at 0.375 though both
  read 0.50 on 2026-10-07; neither the probe's mute, nor two days of changes, nor sleep wrote
  it. coreaudiod writes it at shutdown, so a change survives a restart, and a crash or
  forced power off loses changes since the last save, for System Settings' changes as for
  ZenithBar's.
- The preferred defaults, `preferred devices` in `com.apple.audio.SystemSettings.plist`, were
  written on 2026-10-07 at 18:37, as the panel's rows set the default output: coreaudiod saves
  those at once.

## 6. Events and cost

- `zenithbar-probe sound watch 30`, every device's and process's properties: one event in 30
  s, the speakers' running state at the start. Nothing fires while nothing changes.
- `zenithbar-probe sound cost 120`, idle and listening in 5 s stretches taking turns, after the
  first: the probe spent 0.20 to 2.8 ms a second idle and 0.19 to 0.53 listening, and coreaudiod
  75 to 200 ms a second either way with the players running. Listening costs nothing
  measurable. Registering the probe's 112 listeners took 16 ms; ZenithBar registers about 12.
- Installed, ZenithBar spent 40 ms of CPU in 120 s with the panel closed, 0.33 ms a second,
  with everything it runs, at 50 MB resident.

## 7. The speaker

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

## 8. The microphone item

- **Place:** left of the speaker: the agents gauge, the microphone, the speaker, the network,
  the battery and the clock.
- **Microphones** (`SoundState.microphones`): every input device but virtual ones, whose input
  is another app's sound and whose mute may not hold, as Microsoft Teams Audio's (section 3).
- **When** (`SoundState.mic`): live, `mic.fill` in the foreground color, while a microphone in
  use is unmuted or has no mute; muted, `mic.slash.fill` in the theme's alert color, while none
  is heard and any input device is muted, by ZenithBar or elsewhere, in use or not; hidden
  otherwise. So a device left muted always shows, as the MacBook Pro Microphone muted before
  AirPods took the default input, which hid it before 2026-10-07. ZenithBar listens to every
  input device's mute, so a mute set in System Settings shows too. The item hides once nothing
  is muted and nothing records, after Omarchy's widget; the panel's INPUT slider then shows the
  level. Drawn at 14 pt and cropped to its ink, as the speaker.
- **Which devices a click mutes** (`micTargets`): the microphones in use, and the default input.
  With a call on, that mutes what the call hears; with none, it mutes the next call's
  microphone, and the item stays as a reminder. A click while it shows muted unmutes every
  muted input device, targets or not, so a microphone muted in a call that has since ended
  comes back with the rest; a click while it shows live or hidden mutes the unmuted targets,
  and unmutes everything when none is left to mute, so a microphone without a mute in use
  cannot hold the item on muting (`micToggle`). A device without a settable mute is skipped.
- **Clicks,** Omarchy's widget: a left click mutes or unmutes, a middle click opens the sound
  panel under it, and scrolling steps the default input's level by 5%.

## 9. The panel

- **Header:** the speaker's icon at 22 pt, "Audio", and Omarchy's volume name under it, dim, in
  capitals spaced 1.2 pt (`outputVolumeName`): Muted, Silenced, Whisper, Murmur, Easy listening,
  Steady groove, Cranked up, Party mode, Concert hall. At the right, a switch that mutes the
  output and the microphone targets together (`MuteSwitch`). It is on while the default output
  is unmuted, and on an output without a mute, as the monitors', while a microphone target is
  unmuted. Omarchy's is on while either is unmuted, which with the speakers muted and the
  microphone not read on, so its click muted the microphone and left the sound off (section 3,
  Steve's glitch). Turned off, it mutes the output and every unmuted target and remembers them
  by UID; turned on, it unmutes what it muted and is still muted, wherever the device is now,
  and the default output, so it never unmutes a microphone muted on its own. With nothing of
  its own to restore and no output mute, it unmutes the muted targets.
- **OUTPUT and INPUT:** the caption with the percent at the right, the default device's slider,
  then the devices, the default bold and highlighted, each with its icon: `hifispeaker.fill`
  for built-in speakers, `mic.fill` for a built-in microphone, `display` for HDMI and
  DisplayPort, AirPods and headphones as above, `dot.radiowaves.left.and.right` for other
  Bluetooth, `cable.connector` for USB, `airplayaudio` for AirPlay and `iphone` for Continuity.
  A click makes the device the default output or input; the mic item's middle click opens the
  same panel, where INPUT picks the microphone. A Bluetooth microphone picked there stays the
  default input (section 10). A slider is disabled on a side without a
  volume, as the monitors', with "--" for its percent; a muted side's slider shows at half
  strength, and a right click on it mutes or unmutes that side, as Omarchy's.
- **Virtual devices,** Steve's choice on 2026-10-07: devices whose transport type is virtual or
  aggregate (`kAudioDeviceTransportTypeVirtual`, `Aggregate`, `AutoAggregate`) are left out of
  the lists, so he never switches to Microsoft Teams Audio by accident. One that is the default
  still shows, highlighted, so he can see it and switch away (`SoundState.listed`).
- **Live:** the panel draws `Sound`'s state, which the bar's listeners keep current: the device
  list and both defaults, the default output's volume, mute and data source, every input
  device's running state, mute and level, and every device's streams in both directions
  (`soundWatches`). The streams, as on 2026-10-09 the AirPods gained their output streams after
  they connected, with nothing else changing, and the panel listed them under INPUT only until
  the next read. So the open panel follows the volume
  keys, System Settings, Control Center and other apps with nothing polling, and needs no
  listener of its own: nothing starts when it opens or stops when it closes. A change in the
  device list or a default adds the new devices' listeners and drops the gone ones', as when
  AirPods connect, leave for another device or take a call, and after coreaudiod restarts every
  listener is added again (section 11).
- **Dragging** (`PanelSlider`): while dragged, the knob follows the pointer alone, and the
  listener's reading of each step waits for after, so the knob does not jump back; the percent
  and the volume name follow the knob. On release the knob keeps the last value until the
  listener reads it back. A drag sets the device it started on, and ends when that device stops
  being the default or goes.
- **Look:** 380 pt wide, in the network panel's fill and border, built from PanelKit's views
  ([network.md](network.md), the pieces) and the slider it adds. Omarchy's input level meter
  and per app mixer are left out: macOS has no volume per app, and a meter would need
  ZenithBar to open the microphone.
- **Module** (`SoundModule`, `Sources/zenithbar/SoundModule.swift`): both items, their clicks
  and scrolling, and the panel under whichever opened it, from `Sound`'s state
  ([overview.md](overview.md), modules).
- **Test hooks,** debug builds only (`Controller.watchTestHooks`, and `SoundModule.test` for
  `mic`): `open volume`, `close`, and
  `mic live|muted|off|real`, which draws the microphone item that way without an app or a mute,
  for captures.

## 10. preferBuiltInMic

- **Why:** when AirPods or another Bluetooth headset connect, macOS makes them the default
  output and input. An app opening their microphone drops them into the call profile, whose
  input runs at 24 kHz (section 4), and their output then sounds poor.
- **The rule** (`MicKeeper`, `Sound.keep`), Steve's on 2026-10-08: whenever the default input
  becomes a Bluetooth headset's microphone and Steve did not pick it, ZenithBar makes the
  built-in microphone the default input again and leaves the default output on the headset.
  That covers a new connection, AirPods coming back to the ear or from the iPhone, macOS routing
  again after coreaudiod restarts (section 11), and ZenithBar starting, or the setting turning
  on, while a headset's microphone is the default. The built-in microphone is the built-in
  input with the UID `BuiltInMicrophoneDevice` or the data source `imic`, as on Steve's M3 Pro;
  on a Mac without one ZenithBar does nothing.
- **macOS's route:** coreaudiod's log marks the defaults macOS sets itself as `transient`
  (`HALS_DefaultDeviceManager::SetDefaultDevice: 'dIn ' | transient 233:
  '7C-1A-2B-3C-4D-03:input'`) and a client's write without the mark, but no CoreAudio property
  says which a default is. Each of macOS's three routes on 2026-10-07 moved the default output to
  the AirPods 5 to 50 ms before the input: on connecting at 20:41:33, when they came back 80 s
  after coreaudiod restarted, at 20:52:05, and back in the ear at 21:01:08. So ZenithBar takes a
  headset's microphone becoming the default within 2 s (`routeWindow`) of the default output
  moving to the same headset, matched by the Bluetooth address both UIDs begin with, as macOS's
  route, and switches it back. Each read is timed from its start: on 2026-10-09 reading the
  AirPods just after they connected took about 2 s (nothing from ZenithBar in its log between
  19:42:21.5 and 23.3), and timed at its end their microphone, set 1 ms after the output, read
  as moved 2.2 s later and was left as a pick.
- **Choices stand:** a headset's microphone picked in the panel's INPUT stays the default until
  the headset leaves CoreAudio's device list, coreaudiod restarts, or Steve picks another input
  in the panel; the AirPods leaving the ear and coming back keep it. A headset's microphone that
  becomes the default with no output moving to it, as a pick in System Settings' Input list
  does, stays the same way, and ZenithBar logs that it leaves it.
- **What cannot be told apart,** as the output is the only tell:
  - a pick of the headset as the output, in Control Center or System Settings' Output list, that
    macOS follows by moving the input too reads as macOS's route, and the input is switched back.
    Whether macOS moves the input then is untested;
  - a pick in System Settings within 2 s of the output moving to the headset reads as macOS's
    route;
  - macOS moving only the input to a headset whose output is the default already reads as a pick,
    and the microphone stays until the headset disconnects. None was seen on 2026-10-07;
  - a headset's microphone that is the default at launch, after coreaudiod restarts, or when the
    setting turns on is switched back, whoever picked it.

  A pick in the panel always holds. There is no upgrade path through public API: the `transient`
  mark shows only in coreaudiod's log.
- **Not fighting macOS:** ZenithBar acts only when the default input changes to a headset's
  microphone, so a write that fails is not retried at every read. When macOS puts the same
  headset's microphone back after ZenithBar switched away from it three times within 60 s
  (`fightLimit`, `fightWindow`), ZenithBar leaves it until it disconnects and logs that it backed
  off. Three, as macOS set the AirPods' input three times within 120 ms when they connected at
  20:41:33, so a switch can land inside such a burst.
- **Logs,** at notice level (section 3): each switch as `preferBuiltInMic, as macOS moved the
  default output and input to steez AirPods ANC`, or `as steez AirPods ANC was the default input
  at launch`, `after coreaudiod restarted` or `when PREFER MACBOOK MIC turned on`, with the
  defaults before and after and CoreAudio's status; each microphone left as `preferBuiltInMic
  leaves <device> until it disconnects, as` the pick or the back off.
- **2026-10-07's miss:** the rule until then acted only on a headset that connected while
  ZenithBar ran and had not been the default before. ZenithBar's log shows it switched at
  20:41:33, on connecting, and at 20:52:05, as its reads during coreaudiod's restart listed the
  AirPods anew. At 21:01:08 the AirPods came back to the ear without leaving the device list,
  macOS moved the output and the input to them, and ZenithBar did nothing, until Steve picked
  the MacBook Pro Microphone in the panel at 21:01:36.
- **Setting:** the panel's PREFER MACBOOK MIC switch, under INPUT, or `"preferBuiltInMic":
  false` in `~/.config/zenithbar/config.json`; it is on when the key is missing, and ZenithBar
  reads a change at once. "Prefer", Steve's word (2026-10-07), as a microphone he picks stays.
  The switch writes the key into config.json's text (`settingConfig`), first in the object or
  in place, so the rest of the file keeps its formatting, and through the symlink into the
  dotfiles, where the change then shows as uncommitted. Named `keepBuiltInMic` until then.
- **Apps with their own microphone setting,** as Discord, Zoom and Microsoft Teams, use the
  device chosen there and ignore the default: set them to "MacBook Pro Microphone" or to
  "Default" for this to keep the headset out of the call profile.
- **Untested:** no Bluetooth headset was connected while this rule was built; the switches of
  2026-10-07 were the earlier rule's. The unit tests cover the states
  (`preferBuiltInMicSwitchesBackEveryRouteOfMacOS`, `preferBuiltInMicLeavesAPick`,
  `preferBuiltInMicBacksOffWhenMacOSKeepsPuttingTheHeadsetBack`).

## 11. coreaudiod restarting

- **What a restart breaks:** Apple's header (`AudioHardware.h`,
  `kAudioHardwarePropertyServiceRestarted`): "When a reset happens, any state the client has,
  such as cached data or added listeners, must be re-established by the client." The device IDs
  are renumbered too.
- **What ZenithBar saw on 2026-10-07:** coreaudiod crashed (section 12) and launchd started it
  again at 20:50:45. ZenithBar's listeners on the system object still fired: at 20:50:47 it read
  the new device list and removed its listeners on IDs 68, 89, 124 and 130, which CoreAudio
  logged as `AudioObjectRemovePropertyListenerBlock: no object with given ID`, and added the new
  devices'; at 20:52:05 the MacBook Pro Microphone read as 265, 89 before. So on macOS 27 the
  system object's listeners outlived that restart, and the device list's listener caught the
  new IDs, but nothing in Apple's documentation promises either.
- **What ZenithBar does:** it listens to `kAudioHardwarePropertyServiceRestarted` on the system
  object with its other listeners (`soundWatches`). The system object reads as lacking the
  property (`AudioObjectHasProperty` false) while adding its listener returns no error
  (`zenithbar-probe sound restart`, 2026-10-08), so ZenithBar adds it without asking. When it
  fires, the next read:
  - removes every listener ZenithBar added, by the ID it was added on, and adds every one the
    new state needs, so each is registered once whether CoreAudio kept it or dropped it, and
    none stays on an old ID that a new device might be given;
  - starts preferBuiltInMic's keeper anew, which ends picks and switches back a headset's
    microphone that is the default (section 10);
  - logs `Sound: coreaudiod restarted: listening again to <n> properties of <m> devices` at
    notice level.

  The rest of what ZenithBar keeps about devices is keyed by UID or Bluetooth address: the
  switch's mutes, the keeper, the AirPods' models. The panel's rows and a slider's drag hold IDs
  only until the read after the restart redraws them.
- **Left out:** a second signal, as the device list changing wholesale. The header documents
  `ServiceRestarted` for this, and the device list's listener already re-read the state on
  2026-10-07. If a restart passes without the log line while the IDs change, take a read in
  which none of the last state's device IDs remains as a restart.
- **Untested live:** coreaudiod was not restarted to test this, as its crash cut Steve's audio on
  2026-10-07. Whether `ServiceRestarted` reaches a block listener on macOS 27 is unconfirmed;
  ControlCenter's AVAudioSession logged `handleServiceRestart` at 20:50:46, 0.7 s after that
  restart. A reboot tests nothing, as coreaudiod starts before ZenithBar. To confirm, the next
  time coreaudiod restarts on its own, as when an audio driver's installer restarts it: compare
  `ps -o lstart= -p $(pgrep -x coreaudiod)` with `log show --predicate 'subsystem ==
  "io.github.st-eez.zenithbar" AND eventMessage BEGINSWITH "Sound: coreaudiod"'`, then press F11
  or F12 with the sound panel open and see its slider follow. `zenithbar-probe sound restart
  86400` in a terminal logs the next restart on its own.

## 12. AirPods listening modes: not possible

Steve asked for the native Sound menu's Listening Mode (Off, Transparency, Adaptive, Noise
Cancellation) and Conversation Awareness; on 2026-10-07 he chose to stop after a probe found no
way a third-party app can change them on macOS 27. Don't retry these:
- `IOBluetoothDevice`'s `listeningMode`/`setListeningMode:`, which NoiseBuddy used, still exist,
  but the setter only stores a byte in the object and reaches neither bluetoothd nor the
  AirPods, and the getters read stale values (0, while bluetoothd logged `LsnM Normal`).
- Control Center's paths, CoreBluetooth's private `CBController` (`modifyDevice:settings:`),
  AudioAccessoryServices and AVFoundation's private `AVOutputDevice`, need Apple-only
  entitlements (`com.apple.bluetooth.system`, `com.apple.AudioAccessoryServices`,
  `com.apple.avfoundation.allows-access-to-device-list`) an Apple Development signature cannot
  claim.
- A second AACP channel to the AirPods (PSM 0x1001) with the handshake made them drop
  macOS's own session for 10 s, and macOS moved the output to the speakers.
- Reading the Bluetooth audio driver's private CoreAudio properties crashed coreaudiod
  (`dvsf`, on the AirPods' output device), and macOS moved the output to the speakers.
- What remains: the mode, read-only, from bluetoothd's log lines (`LsnM`, `LsMC`), or pressing
  Control Center's own menu through Accessibility. Steve declined both.

## 13. Untested

On 2026-10-07, with the Mac in use, only the probe's mute of the idle MacBook Pro Microphone,
Steve's own clicks and preferBuiltInMic's switches changed a real device (sections 3 and 10).
Untested: that every app hears silence from a muted microphone; whether macOS moves the alert
sound device with the default output; the knob's behaviour at a drag's release; scrolling on the
items; the panel following a change Steve makes while it is open, beyond the listener path the
probe's writes showed. AirPods were not connected while the panel was built: their symbol, the
system_profiler match, connecting and leaving while the bar runs and while the panel is open,
switching to another Apple device, and the call profile adding an input stream to their output
device, which the unit tests cover as states (`Tests/ZenithBarCoreTests/SoundTests.swift`); and
headphones in the jack. preferBuiltInMic's rule of 2026-10-08 (section 10) and ZenithBar's
answer to coreaudiod restarting (section 11) are untested live.
