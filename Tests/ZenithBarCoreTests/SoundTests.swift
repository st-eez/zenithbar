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

private func with(_ device: AudioDevice, running: Bool? = nil, inputMuted: Bool? = nil) -> AudioDevice {
    var device = device
    if let running { device.running = running }
    if let inputMuted { device.input?.muted = inputMuted }
    return device
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
    // Teams runs its own device, not the default one: both are targets, and the item is live.
    let call = SoundState(devices: [microphone, speakers, with(teams, running: true)], defaultOutput: 82, defaultInput: 89)
    #expect(call.mic == .live)
    #expect(call.mic.symbol! == ("mic.fill", false))
    #expect(Set(call.micTargets.map(\.id)) == [68, 89])
    #expect(call.micToggle.mute)
    #expect(Set(call.micToggle.devices) == [68, 89])
    // The device in use muted elsewhere, as in System Settings: no app hears a microphone.
    let mutedElsewhere = SoundState(devices: [microphone, speakers, with(teams, running: true, inputMuted: true)],
                                    defaultOutput: 82, defaultInput: 89)
    #expect(mutedElsewhere.mic == .muted)
    // Unmuting unmutes only what is muted.
    #expect(!mutedElsewhere.micToggle.mute)
    #expect(mutedElsewhere.micToggle.devices == [68])
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

@Test func masterSwitchCountsOnlySidesWithAMute() {
    #expect(steve.anyAudible)
    let all = steve.masterToggle
    #expect(all.mute && all.output == 82 && all.inputs == [89])
    var quiet = steve
    quiet.devices = [monitor, with(microphone, inputMuted: true), speakers, teams]
    quiet.devices[2].output?.muted = true
    #expect(!quiet.anyAudible)
    #expect(quiet.masterToggle == (false, 82, [89]))
    // On the monitor, without a mute, the switch follows the microphone alone.
    let monitorOut = SoundState(devices: [monitor, with(microphone, inputMuted: true)], defaultOutput: 94, defaultInput: 89)
    #expect(!monitorOut.anyAudible)
    #expect(monitorOut.masterToggle.output == nil)
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
    #expect(found["7C:1A:2B:3C:4D:03"] == BluetoothDevice(vendorID: 0x004C, productID: 0x201B, minorType: "Headphones"))
    #expect(found["AC:1A:2B:3C:4D:04"] == BluetoothDevice(minorType: "Gamepad"))
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
    #expect(before.contains(AudioWatch(system, kAudioHardwarePropertyDevices)))
    #expect(before.contains(AudioWatch(82, volume, kAudioObjectPropertyScopeOutput)))
    #expect(before.contains(AudioWatch(68, kAudioDevicePropertyDeviceIsRunningSomewhere)))
    #expect(before.contains(AudioWatch(89, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)))
    // Only the default output's levels: the monitor's are not listened to.
    #expect(!before.contains { $0.object == 94 })
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
