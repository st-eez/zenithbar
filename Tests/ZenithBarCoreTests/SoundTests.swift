import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import ZenithBarCore

// The devices Steve's Mac listed on 2026-10-07 (docs/sound.md), and AirPods as they would join.
private let speakers = AudioDevice(id: 82, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                                   output: AudioSide(volume: 0.31, volumeSettable: true, muted: false, muteSettable: true,
                                                     dataSource: fourCharCode("ispk")))
private let microphone = AudioDevice(id: 89, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                     input: AudioSide(volume: 0.59, volumeSettable: true, muted: false, muteSettable: true))
private let monitor = AudioDevice(id: 94, name: "ASUS VA24E", transport: .hdmi, output: AudioSide())
private let teams = AudioDevice(id: 68, uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio", transport: .virtual,
                                output: AudioSide(canBeDefault: false, volume: 0.56, volumeSettable: true, muted: false,
                                                  muteSettable: true),
                                input: AudioSide(canBeDefault: false, volume: 1, volumeSettable: true, muted: false,
                                                 muteSettable: true))
private let airpods = AudioDevice(id: 120, uid: "7C-1A-2B-3C-4D-03:output", name: "steez AirPods ANC", transport: .bluetooth,
                                  output: AudioSide(volume: 0.5, volumeSettable: true, muted: false, muteSettable: true))
private let airpodsMic = AudioDevice(id: 121, uid: "7C-1A-2B-3C-4D-03:input", name: "steez AirPods ANC",
                                     transport: .bluetooth, running: true,
                                     input: AudioSide(volume: 0.8, volumeSettable: true, muted: false, muteSettable: true))
private let steve = SoundState(devices: [monitor, microphone, speakers, teams], defaultOutput: 82, defaultInput: 89)

private let usbMic = AudioDevice(id: 150, uid: "AppleUSBAudioEngine:Blue:Yeti", name: "Yeti", transport: .usb,
                                 input: AudioSide(volume: 0.7, volumeSettable: true, muted: false, muteSettable: true))

private func with(_ device: AudioDevice, running: Bool? = nil, inputMuted: Bool? = nil, outputMuted: Bool? = nil) -> AudioDevice {
    var device = device
    if let running { device.running = running }
    if let inputMuted { device.input?.muted = inputMuted }
    if let outputMuted { device.output?.muted = outputMuted }
    return device
}

/// `state` after `sides` are set to `mute`, as CoreAudio's listeners would read it back.
private func applying(_ toggle: (mute: Bool, sides: [MuteSide]), to state: SoundState) -> SoundState {
    var state = state
    for side in toggle.sides {
        guard let index = state.devices.firstIndex(where: { $0.id == side.device.id }) else { continue }
        if side.direction == .output { state.devices[index].output?.muted = toggle.mute } else { state.devices[index].input?.muted = toggle.mute }
    }
    return state
}

private func sides(_ toggle: (mute: Bool, sides: [MuteSide])) -> [String] {
    toggle.sides.map { "\($0.device.id) \($0.direction)" }
}

@Test func namesTheVolumeAsOmarchy() {
    #expect(outputVolumeName(0.5, muted: true) == "Muted")
    #expect(outputVolumeName(0.004, muted: false) == "Silenced")
    #expect(outputVolumeName(0.13, muted: false) == "Whisper")
    #expect(outputVolumeName(0.15, muted: false) == "Murmur")
    #expect(outputVolumeName(0.3, muted: false) == "Easy listening")
    #expect(outputVolumeName(0.5, muted: false) == "Steady groove")
    #expect(outputVolumeName(0.7, muted: false) == "Cranked up")
    #expect(outputVolumeName(0.85, muted: false) == "Party mode")
    #expect(outputVolumeName(1, muted: false) == "Concert hall")
    #expect(volumePercent(0.31) == "31%")
    #expect(volumePercent(nil) == "--")
    #expect(stepVolume(0.98, steps: 1) == 1)
    #expect(stepVolume(0.02, steps: -1) == 0)
    #expect(abs(stepVolume(0.31, steps: 2) - 0.41) < 1e-9)
}

@Test func micHidesWhileUnusedAndUnmuted() {
    #expect(steve.mic == .hidden)
    #expect(steve.micTargets.map(\.id) == [89])
    // A click with nothing in use mutes the default input, and the item stays as a reminder.
    #expect(steve.micToggle.mute)
    #expect(steve.micToggle.devices == [89])
    let muted = SoundState(devices: [monitor, with(microphone, inputMuted: true), speakers, teams], defaultOutput: 82,
                           defaultInput: 89)
    #expect(muted.mic == .muted)
    #expect(muted.mic.symbol! == ("mic.slash.fill", true))
    #expect(!muted.micToggle.mute)
    #expect(muted.micToggle.devices == [89])
}

@Test func micShowsWhileAnyAppRunsAnInput() {
    // A USB microphone in use, not the default: both are targets, and the item is live.
    let call = SoundState(devices: [microphone, speakers, with(usbMic, running: true)], defaultOutput: 82, defaultInput: 89)
    #expect(call.mic == .live)
    #expect(call.mic.symbol! == ("mic.fill", false))
    #expect(Set(call.micTargets.map(\.id)) == [150, 89])
    #expect(call.micToggle.mute)
    #expect(Set(call.micToggle.devices) == [150, 89])
    // The device in use muted elsewhere, as in System Settings: no app hears a microphone.
    let mutedElsewhere = SoundState(devices: [microphone, speakers, with(usbMic, running: true, inputMuted: true)],
                                    defaultOutput: 82, defaultInput: 89)
    #expect(mutedElsewhere.mic == .muted)
    // Unmuting unmutes only what is muted.
    #expect(!mutedElsewhere.micToggle.mute)
    #expect(mutedElsewhere.micToggle.devices == [150])
}

@Test func teamsAudioRunningLeavesTheMicrophoneItemWorking() {
    // Teams runs its virtual device, whose mute reads 0 whatever is written (docs/sound.md).
    // Counted as a microphone in use, it held the item live, so each click muted again and none
    // unmuted the MacBook Pro Microphone.
    let call = SoundState(devices: [microphone, speakers, with(teams, running: true)], defaultOutput: 82, defaultInput: 89)
    #expect(call.mic == .hidden)
    #expect(call.micTargets.map(\.id) == [89])
    #expect(call.micToggle == (true, [89]))
    let muted = SoundState(devices: [with(microphone, inputMuted: true), speakers, with(teams, running: true)],
                           defaultOutput: 82, defaultInput: 89)
    #expect(muted.mic == .muted)
    #expect(muted.micToggle == (false, [89]))
}

@Test func aMicrophoneMutedOutOfSightShowsAndUnmutes() {
    // The MacBook Pro Microphone is muted, then AirPods connect and macOS makes their
    // microphone the default input: it was hidden, as no target was muted, while the MacBook's
    // stayed muted.
    let pods = SoundState(devices: [with(microphone, inputMuted: true), speakers, airpods, with(airpodsMic, running: false)],
                          defaultOutput: 120, defaultInput: 121)
    #expect(pods.mic == .muted)
    #expect(pods.micToggle == (false, [89]))
    // A call on a USB microphone is muted with the default; the call ends, so the USB one is
    // no longer in use: a click unmutes both, where it unmuted the default alone.
    let ended = SoundState(devices: [with(microphone, inputMuted: true), speakers, with(usbMic, inputMuted: true)],
                           defaultOutput: 82, defaultInput: 89)
    #expect(ended.mic == .muted)
    #expect(Set(ended.micToggle.devices) == [89, 150])
    #expect(!ended.micToggle.mute)
}

@Test func micCopesWithAirPodsTakingACall() {
    // An app opens the AirPods' microphone: their input device appears, running, and becomes the
    // default input.
    let call = SoundState(devices: [microphone, speakers, airpods, airpodsMic], defaultOutput: 120, defaultInput: 121)
    #expect(call.mic == .live)
    #expect(call.micTargets.map(\.id) == [121])
    // They leave for another device between reads: the default names a device no longer listed.
    let gone = SoundState(devices: [microphone, speakers], defaultOutput: 120, defaultInput: 121)
    #expect(gone.defaultDevice(.input) == nil)
    #expect(gone.output == nil)
    #expect(gone.mic == .hidden)
    #expect(gone.micToggle.devices.isEmpty)
    #expect(outputSymbol(gone.defaultDevice(.output), bluetooth: nil) == ("speaker.wave.3.fill", false))
}

@Test func switchFollowsTheOutputAndRestoresWhatItMuted() {
    var muteSwitch = MuteSwitch()
    #expect(steve.switchOn)
    let off = muteSwitch.toggle(steve)
    #expect(off.mute && sides(off) == ["82 output", "89 input"])
    let quiet = applying(off, to: steve)
    #expect(!quiet.switchOn)
    let on = muteSwitch.toggle(quiet)
    #expect(!on.mute && Set(sides(on)) == ["82 output", "89 input"])
    #expect(applying(on, to: quiet) == steve)
}

@Test func switchReadsOffWhileTheOutputIsMuted() {
    // Steve's clicks on 2026-10-07 18:38, from CoreAudio's log: with the speakers muted and the
    // microphone unmuted, the switch read on, as the microphone was audible, and its click
    // muted the microphone while the speakers stayed muted; the sound came back on the next.
    var muteSwitch = MuteSwitch()
    let speakersMuted = SoundState(devices: [monitor, microphone, with(speakers, outputMuted: true), teams],
                                   defaultOutput: 82, defaultInput: 89)
    #expect(!speakersMuted.switchOn)
    let toggle = muteSwitch.toggle(speakersMuted)
    #expect(!toggle.mute && sides(toggle) == ["82 output"])
}

@Test func switchLeavesAMicrophoneMutedOnItsOwn() {
    // The microphone item muted the microphone; the switch mutes and unmutes the speakers alone.
    var muteSwitch = MuteSwitch()
    let micMuted = SoundState(devices: [monitor, with(microphone, inputMuted: true), speakers, teams],
                              defaultOutput: 82, defaultInput: 89)
    #expect(micMuted.switchOn)
    let off = muteSwitch.toggle(micMuted)
    #expect(off.mute && sides(off) == ["82 output"])
    let on = muteSwitch.toggle(applying(off, to: micMuted))
    #expect(!on.mute && sides(on) == ["82 output"])
    // A USB microphone in use is muted with the rest; its app stops before the switch goes back
    // on, so it is no longer a target, and the switch still unmutes it.
    let call = SoundState(devices: [microphone, speakers, with(usbMic, running: true)], defaultOutput: 82, defaultInput: 89)
    let callOff = muteSwitch.toggle(call)
    #expect(Set(sides(callOff)) == ["82 output", "89 input", "150 input"])
    var ended = applying(callOff, to: call)
    ended.devices[2].running = false
    #expect(Set(sides(muteSwitch.toggle(ended))) == ["82 output", "89 input", "150 input"])
    // The speakers unmuted elsewhere between the clicks: the switch reads on and mutes them
    // again, and still restores the microphone it muted first.
    _ = muteSwitch.toggle(steve)
    var partly = applying((true, [MuteSide(microphone, .input)]), to: steve)
    #expect(partly.switchOn)
    let again = muteSwitch.toggle(partly)
    #expect(again.mute && sides(again) == ["82 output"])
    partly = applying(again, to: partly)
    #expect(Set(sides(muteSwitch.toggle(partly))) == ["82 output", "89 input"])
}

@Test func switchOnAnOutputWithoutAMuteFollowsTheMicrophone() {
    var muteSwitch = MuteSwitch()
    let monitorOut = SoundState(devices: [monitor, microphone], defaultOutput: 94, defaultInput: 89)
    #expect(monitorOut.switchOn)
    #expect(sides(muteSwitch.toggle(monitorOut)) == ["89 input"])
    // Muted elsewhere: the switch reads off and unmutes it, the only thing it controls.
    var fresh = MuteSwitch()
    let mutedElsewhere = SoundState(devices: [monitor, with(microphone, inputMuted: true)], defaultOutput: 94, defaultInput: 89)
    #expect(!mutedElsewhere.switchOn)
    let toggle = fresh.toggle(mutedElsewhere)
    #expect(!toggle.mute && sides(toggle) == ["89 input"])
}

// preferBuiltInMic's states, from coreaudiod's log of 2026-10-07 (docs/sound.md, preferBuiltInMic).
private let airpodsInput = with(airpodsMic, running: false)
private let connected = SoundState(devices: steve.devices + [airpods, airpodsInput], defaultOutput: 82, defaultInput: 89)
/// macOS's route: the output and the input on the AirPods.
private let routed = SoundState(devices: connected.devices, defaultOutput: 120, defaultInput: 121)
/// The output on the AirPods, the input on the MacBook, as preferBuiltInMic leaves them.
private let kept = SoundState(devices: connected.devices, defaultOutput: 120, defaultInput: 89)

private func switched(_ decision: MicKeeper.Decision?, first: Bool = false) -> Bool {
    decision == .switchBack(builtIn: microphone, headset: airpodsInput, first: first)
}

@Test func preferBuiltInMicSwitchesBackEveryRouteOfMacOS() {
    // A new connection: macOS moves the output and the input in one read, or the output first.
    var keeper = MicKeeper()
    #expect(keeper.check(steve, now: 0) == nil)
    #expect(keeper.check(connected, now: 1) == nil)
    #expect(switched(keeper.check(routed, now: 2)))
    #expect(keeper.check(kept, now: 2.1) == nil)
    keeper = MicKeeper()
    #expect(keeper.check(connected, now: 0) == nil)
    #expect(keeper.check(kept, now: 1) == nil)
    #expect(switched(keeper.check(routed, now: 1.01)))
    // Back in the ear without disconnecting, as at 21:01:08: the output leaves and comes back
    // with the input, and the AirPods never leave the device list.
    #expect(keeper.check(connected, now: 30) == nil)
    #expect(switched(keeper.check(routed, now: 90)))
    // Back from the iPhone: they leave the list and come back.
    #expect(keeper.check(steve, now: 200) == nil)
    #expect(switched(keeper.check(routed, now: 300)))
    // A ZenithBar launched, a coreaudiod restarted or the setting turned on, each a new keeper,
    // with their microphone the default already; after a restart under new IDs, matched by UID.
    keeper = MicKeeper()
    #expect(switched(keeper.check(routed, now: 0), first: true))
    var renumbered = routed
    renumbered.devices = renumbered.devices.map { device in
        var device = device
        device.id += 200
        return device
    }
    renumbered.defaultOutput = 320
    renumbered.defaultInput = 321
    var builtIn = microphone, headset = airpodsInput
    builtIn.id = 289
    headset.id = 321
    keeper = MicKeeper()
    #expect(keeper.check(renumbered, now: 0) == .switchBack(builtIn: builtIn, headset: headset, first: true))
    // A Mac without a built-in microphone, as a Mac mini: nothing to switch to.
    keeper = MicKeeper()
    let mini = SoundState(devices: [speakers, airpods, airpodsInput], defaultOutput: 120, defaultInput: 121)
    #expect(keeper.check(mini, now: 0) == nil)
    #expect(steve.builtInMic?.id == 89)
    #expect(Config().preferBuiltInMic)
    #expect(Config(json: Data(#"{"preferBuiltInMic":false}"#.utf8))?.preferBuiltInMic == false)
}

@Test func preferBuiltInMicLeavesAPick() {
    // Picked in the panel: it stays through a return to the ear, until another is picked.
    var keeper = MicKeeper()
    #expect(keeper.check(kept, now: 0) == nil)
    keeper.chose(airpodsInput.uid)
    #expect(keeper.check(routed, now: 10) == nil)
    #expect(keeper.check(connected, now: 20) == nil)
    #expect(keeper.check(routed, now: 30) == nil)
    keeper.chose(microphone.uid)
    #expect(keeper.check(kept, now: 40) == nil)
    #expect(keeper.check(connected, now: 50) == nil)
    #expect(switched(keeper.check(routed, now: 60)))
    // Picked in System Settings' Input list: the input moves alone, and it stays until they
    // disconnect.
    #expect(keeper.check(kept, now: 61) == nil)
    #expect(keeper.check(routed, now: 120) == .leave(headset: airpodsInput, fighting: false))
    #expect(keeper.check(routed, now: 121) == nil)
    #expect(keeper.check(connected, now: 130) == nil)
    #expect(keeper.check(routed, now: 140) == nil)
    #expect(keeper.check(steve, now: 150) == nil)
    #expect(switched(keeper.check(routed, now: 160)))
}

@Test func preferBuiltInMicBacksOffWhenMacOSKeepsPuttingTheHeadsetBack() {
    var keeper = MicKeeper()
    #expect(keeper.check(connected, now: 0) == nil)
    // macOS sets the input again before ZenithBar reads its switch back, three times in a burst.
    #expect(switched(keeper.check(routed, now: 1)))
    #expect(switched(keeper.check(routed, now: 1.1)))
    #expect(switched(keeper.check(routed, now: 1.2)))
    #expect(keeper.check(routed, now: 1.3) == .leave(headset: airpodsInput, fighting: true))
    #expect(keeper.check(routed, now: 1.4) == nil)
    #expect(keeper.check(connected, now: 5) == nil)
    #expect(keeper.check(routed, now: 6) == nil)
    // A minute later, after they disconnect, it switches again.
    #expect(keeper.check(steve, now: 100) == nil)
    #expect(switched(keeper.check(routed, now: 101)))
}

@Test func symbolsByDevice() {
    #expect(deviceSymbol(speakers, .output, bluetooth: nil) == "hifispeaker.fill")
    #expect(deviceSymbol(microphone, .input, bluetooth: nil) == "mic.fill")
    #expect(deviceSymbol(monitor, .output, bluetooth: nil) == "display")
    #expect(deviceSymbol(teams, .input, bluetooth: nil) == "waveform")
    let pods = BluetoothDevice(vendorID: 0x004C, productID: 0x201B, minorType: "Headphones")
    #expect(deviceSymbol(airpods, .output, bluetooth: pods) == "airpods.gen4")
    #expect(deviceSymbol(airpodsMic, .input, bluetooth: pods) == "airpods.gen4")
    #expect(deviceSymbol(airpods, .output, bluetooth: BluetoothDevice(vendorID: 0x004C, productID: 0x2014)) == "airpodspro")
    // Bluetooth not read yet, or a model the table lacks: the name.
    #expect(deviceSymbol(airpods, .output, bluetooth: nil) == "airpods")
    #expect(deviceSymbol(airpods, .output, bluetooth: BluetoothDevice(vendorID: 0x004C, productID: 0x2099,
                                                                      minorType: "Headphones")) == "airpods")
    let beats = AudioDevice(id: 130, name: "steez studio beatz", transport: .bluetooth, output: AudioSide())
    #expect(deviceSymbol(beats, .output, bluetooth: BluetoothDevice(vendorID: 0x290B, productID: 0x0200,
                                                                    minorType: "Headphones")) == "headphones")
    let speaker = AudioDevice(id: 131, name: "Kitchen", transport: .bluetooth, output: AudioSide())
    #expect(deviceSymbol(speaker, .output, bluetooth: BluetoothDevice(minorType: "Loudspeaker"))
        == "dot.radiowaves.left.and.right")
    var jack = speakers
    jack.output?.dataSource = fourCharCode("hdpn")
    #expect(deviceSymbol(jack, .output, bluetooth: nil) == "headphones")
    #expect(outputSymbol(jack, bluetooth: nil) == ("headphones", false))
    jack.output?.muted = true
    #expect(outputSymbol(jack, bluetooth: nil) == ("headphones", true))
    #expect(outputSymbol(monitor, bluetooth: nil) == ("speaker.wave.3.fill", false))
    #expect(outputSymbol(speakers, bluetooth: nil) == ("speaker.wave.1.fill", false))
}

@Test func readsBluetoothFromSystemProfiler() {
    let json = Data("""
        {"SPBluetoothDataType": [{"controller_properties": {"controller_address": "60:1A:2B:3C:4D:02"},
          "device_connected": [{"steez AirPods ANC": {"device_address": "7C:1A:2B:3C:4D:03", "device_minorType": "Headphones",
            "device_productID": "0x201B", "device_vendorID": "0x004C"}}],
          "device_not_connected": [{"Xbox Wireless Controller": {"device_address": "AC:1A:2B:3C:4D:04",
            "device_minorType": "Gamepad"}}]}]}
        """.utf8)
    let found = bluetoothDevices(json: json)
    #expect(found["7C:1A:2B:3C:4D:03"] == BluetoothDevice(address: "7C:1A:2B:3C:4D:03", name: "steez AirPods ANC", connected: true,
                                                          vendorID: 0x004C, productID: 0x201B, minorType: "Headphones"))
    #expect(found["AC:1A:2B:3C:4D:04"] == BluetoothDevice(address: "AC:1A:2B:3C:4D:04", name: "Xbox Wireless Controller",
                                                          minorType: "Gamepad"))
    #expect(found.count == 2)
    #expect(bluetoothDevices(json: Data("nope".utf8)).isEmpty)
    #expect(bluetoothAddress(uid: "7c-1a-2b-3c-4d-03:output") == "7C:1A:2B:3C:4D:03")
    #expect(bluetoothAddress(uid: "BuiltInSpeakerDevice") == nil)
    #expect(bluetoothAddress(uid: "MSLoopbackDriverDevice_UID") == nil)
}

@Test func listenersFollowDevicesAndDefaults() {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let volume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    let before = soundWatches(steve)
    #expect(before.contains(AudioWatch(system, kAudioHardwarePropertyServiceRestarted)))
    #expect(before.contains(AudioWatch(system, kAudioHardwarePropertyDevices)))
    #expect(before.contains(AudioWatch(82, volume, kAudioObjectPropertyScopeOutput)))
    #expect(before.contains(AudioWatch(68, kAudioDevicePropertyDeviceIsRunningSomewhere)))
    #expect(before.contains(AudioWatch(89, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)))
    // Only the default output's levels: the monitor's are not listened to, only its streams,
    // which every device's are, as AirPods gain theirs after connecting.
    #expect(!before.contains { $0.object == 94 && $0.selector != kAudioDevicePropertyStreams })
    #expect(before.contains(AudioWatch(94, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)))
    // AirPods connect and take the output and a call: their output's levels and their input join,
    // and the speakers' levels go.
    let after = soundWatches(SoundState(devices: steve.devices + [airpods, airpodsMic], defaultOutput: 120, defaultInput: 121))
    let added = after.subtracting(before), dropped = before.subtracting(after)
    #expect(Set(added.map(\.object)) == [120, 121])
    #expect(Set(dropped.map(\.object)) == [82])
    // They leave: everything of theirs goes, and the default output's levels go with them until
    // CoreAudio names a new default.
    let gone = soundWatches(SoundState(devices: steve.devices, defaultOutput: 120, defaultInput: 121))
    #expect(!gone.contains { $0.object == 120 || $0.object == 121 })
    #expect(gone.contains(AudioWatch(system, kAudioHardwarePropertyDefaultOutputDevice)))
}

@Test func scrollStepsPerNotchAndPerPoints() {
    var steps = ScrollSteps()
    #expect(steps.steps(delta: 0.1, precise: false, momentum: false) == 1)
    #expect(steps.steps(delta: -4, precise: false, momentum: false) == -1)
    #expect(steps.steps(delta: 5, precise: true, momentum: false) == 0)
    #expect(steps.steps(delta: 8, precise: true, momentum: false) == 1)
    #expect(steps.steps(delta: 30, precise: true, momentum: false) == 2)
    // Turning back drops what was carried.
    #expect(steps.steps(delta: -11, precise: true, momentum: false) == 0)
    #expect(steps.steps(delta: -2, precise: true, momentum: false) == -1)
    #expect(steps.steps(delta: 100, precise: true, momentum: true) == 0)
}

@Test func listsHideVirtualDevicesUnlessDefault() {
    #expect(steve.listed(.output).map(\.id) == [94, 82])
    #expect(steve.listed(.input).map(\.id) == [89])
    let aggregate = AudioDevice(id: 140, name: "Aggregate", transport: .aggregate, output: AudioSide())
    let teamsDefault = SoundState(devices: steve.devices + [aggregate], defaultOutput: 68, defaultInput: 68)
    #expect(teamsDefault.listed(.output).map(\.id) == [94, 82, 68])
    #expect(teamsDefault.listed(.input).map(\.id) == [89, 68])
    #expect(AudioTransport(code: kAudioDeviceTransportTypeVirtual) == .virtual)
}

@Test func preferBuiltInMicWaitsForAnOutputCoreAudioHasNotReadFully() {
    // AirPods that are the default output before their output streams appear, as on 2026-10-09:
    // still macOS's route.
    var keeper = MicKeeper()
    var streamless = airpods
    streamless.output = nil
    let early = SoundState(devices: steve.devices + [streamless, airpodsInput], defaultOutput: 82, defaultInput: 89)
    #expect(keeper.check(early, now: 0) == nil)
    #expect(switched(keeper.check(SoundState(devices: early.devices, defaultOutput: 120, defaultInput: 121), now: 0.5)))
    // Or named the default output before CoreAudio lists them, with their microphone the default:
    // the decision waits for the list, and the moves date from the IDs' changes, so it is still
    // macOS's route 3 s later.
    keeper = MicKeeper()
    let unlisted = SoundState(devices: steve.devices + [airpodsInput], defaultOutput: 120, defaultInput: 121)
    #expect(keeper.check(steve, now: 0) == nil)
    #expect(keeper.check(unlisted, now: 1) == nil)
    #expect(keeper.check(unlisted, now: 2) == nil)
    #expect(switched(keeper.check(SoundState(devices: unlisted.devices + [streamless], defaultOutput: 120,
                                             defaultInput: 121), now: 4)))
    // An output that never lists within `listWait` leaves the microphone.
    keeper = MicKeeper()
    #expect(keeper.check(steve, now: 0) == nil)
    #expect(keeper.check(unlisted, now: 1) == nil)
    #expect(keeper.check(unlisted, now: 1 + MicKeeper.listWait) == .leave(headset: airpodsInput, fighting: false))
}
