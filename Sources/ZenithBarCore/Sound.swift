import AudioToolbox
import CoreAudio
import Foundation

// What the speaker, the microphone item and the sound panel show and do, apart from AppKit and
// CoreAudio's reads, after Omarchy 4's audio panel and microphone widget
// (`shell/plugins/panels/audio/`, `shell/plugins/bar/widgets/Microphone.qml`) (docs/sound.md).

/// How a device connects, from CoreAudio's `kAudioDevicePropertyTransportType`.
public enum AudioTransport: Equatable, Sendable {
    case builtIn, hdmi, displayPort, bluetooth, usb, virtual, airPlay, aggregate, thunderbolt, continuity, other

    public init(code: UInt32) {
        self = switch code {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeHDMI: .hdmi
        case kAudioDeviceTransportTypeDisplayPort: .displayPort
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        case kAudioDeviceTransportTypeThunderbolt: .thunderbolt
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: .continuity
        default: .other
        }
    }
}

public enum AudioDirection: Equatable, Hashable, Sendable {
    case output, input

    public var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }
}

/// A device's side in one direction: what it has and where it stands.
public struct AudioSide: Equatable, Sendable {
    public var canBeDefault: Bool
    /// From 0 to 1, nil without a volume, as Steve's monitors have.
    public var volume: Double?
    public var volumeSettable: Bool
    /// Nil without a mute.
    public var muted: Bool?
    public var muteSettable: Bool
    /// The current data source, as 'hdpn' for the headphone jack.
    public var dataSource: UInt32?

    public init(canBeDefault: Bool = true, volume: Double? = nil, volumeSettable: Bool = false, muted: Bool? = nil,
                muteSettable: Bool = false, dataSource: UInt32? = nil) {
        self.canBeDefault = canBeDefault
        self.volume = volume
        self.volumeSettable = volumeSettable
        self.muted = muted
        self.muteSettable = muteSettable
        self.dataSource = dataSource
    }
}

public struct AudioDevice: Equatable, Sendable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var transport: AudioTransport
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere`: some process runs it, in either direction.
    public var running: Bool
    public var output: AudioSide?
    public var input: AudioSide?

    public init(id: AudioObjectID, uid: String = "", name: String, transport: AudioTransport = .builtIn, running: Bool = false,
                output: AudioSide? = nil, input: AudioSide? = nil) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.running = running
        self.output = output
        self.input = input
    }

    public func side(_ direction: AudioDirection) -> AudioSide? { direction == .output ? output : input }
}

/// Every device CoreAudio lists and the defaults, as read at one moment.
public struct SoundState: Equatable, Sendable {
    public var devices: [AudioDevice]
    public var defaultOutput: AudioObjectID?
    public var defaultInput: AudioObjectID?

    public init(devices: [AudioDevice] = [], defaultOutput: AudioObjectID? = nil, defaultInput: AudioObjectID? = nil) {
        self.devices = devices
        self.defaultOutput = defaultOutput
        self.defaultInput = defaultInput
    }

    public func devices(_ direction: AudioDirection) -> [AudioDevice] { devices.filter { $0.side(direction) != nil } }

    /// The default device in `direction`, nil when CoreAudio names one it no longer lists, as
    /// when AirPods leave for another Mac between two reads.
    public func defaultDevice(_ direction: AudioDirection) -> AudioDevice? {
        let id = direction == .output ? defaultOutput : defaultInput
        return devices.first { $0.id == id && $0.side(direction) != nil }
    }

    public var output: AudioSide? { defaultDevice(.output)?.output }

    /// The panel's list for `direction`: every device but virtual and aggregate ones, by their
    /// transport type, so Steve never switches to one, as Microsoft Teams Audio, by accident;
    /// one that is the default still shows, so he can see it and switch away (docs/sound.md).
    public func listed(_ direction: AudioDirection) -> [AudioDevice] {
        let current = defaultDevice(direction)?.id
        return devices(direction).filter { ![.virtual, .aggregate].contains($0.transport) || $0.id == current }
    }

    /// The input devices that can be a microphone: all but virtual ones, whose input carries
    /// another app's sound, as Microsoft Teams Audio's, which keeps its own mute whatever is
    /// written (docs/sound.md, writes).
    public var microphones: [AudioDevice] { devices(.input).filter { $0.transport != .virtual } }

    /// Microphones some app runs. A device with both directions counts while only its output
    /// runs, as the property covers the device (docs/sound.md, the microphone).
    public var micInUse: [AudioDevice] { microphones.filter(\.running) }

    /// What a click on the microphone mutes: the microphones in use, and the default input, so
    /// a click with nothing in use still mutes the next call's microphone.
    public var micTargets: [AudioDevice] {
        var targets = micInUse
        if let input = defaultDevice(.input), !targets.contains(where: { $0.id == input.id }) { targets.append(input) }
        return targets
    }

    /// Some app hears a microphone: one in use is unmuted, or has no mute.
    public var micLive: Bool { micInUse.contains { $0.input?.muted != true } }

    /// Every input device muted, by ZenithBar or elsewhere, in use or not.
    public var mutedInputs: [AudioDevice] { devices(.input).filter { $0.input?.muted == true } }

    /// The microphone item: live while an app hears a microphone, muted while any input device
    /// is muted, and hidden otherwise, so a device left muted always shows (docs/sound.md).
    public var mic: MicState {
        if micLive { return .live }
        return mutedInputs.isEmpty ? .hidden : .muted
    }

    /// A click on the microphone item. While it shows muted, or no target it can mute is
    /// unmuted, it unmutes every muted input device, so none stays muted out of sight;
    /// otherwise it mutes the unmuted targets. Only devices whose mute is settable.
    public var micToggle: (mute: Bool, devices: [AudioObjectID]) {
        let unmuted = micTargets.filter { $0.input?.muteSettable == true && $0.input?.muted == false }
        if mic != .muted, !unmuted.isEmpty { return (true, unmuted.map(\.id)) }
        return (false, mutedInputs.filter { $0.input?.muteSettable == true }.map(\.id))
    }

    /// The header's switch: on while the default output is unmuted, so with the output muted it
    /// reads off and its click brings the sound back; on an output without a mute, as the
    /// monitors', while a microphone target it can mute is unmuted.
    public var switchOn: Bool {
        if let side = output, side.muteSettable, let muted = side.muted { return !muted }
        return micTargets.contains { $0.input?.muteSettable == true && $0.input?.muted == false }
    }
}

/// A device's side by UID, which outlives the device's ID when it reconnects.
public struct AudioSideKey: Hashable, Sendable {
    public var uid: String
    public var direction: AudioDirection

    public init(_ uid: String, _ direction: AudioDirection) {
        self.uid = uid
        self.direction = direction
    }
}

/// One side of a device to mute or unmute.
public struct MuteSide: Equatable, Sendable {
    public var device: AudioDevice
    public var direction: AudioDirection

    public init(_ device: AudioDevice, _ direction: AudioDirection) {
        self.device = device
        self.direction = direction
    }

    var key: AudioSideKey { AudioSideKey(device.uid, direction) }

    /// Its mute is settable and reads `muted`.
    func can(_ muted: Bool) -> Bool {
        device.side(direction)?.muteSettable == true && device.side(direction)?.muted == muted
    }
}

/// The panel's switch, which mutes the output and the microphone targets together and, turned
/// back on, unmutes what it muted and the output, so it never unmutes a microphone muted on
/// its own (docs/sound.md, the panel).
public struct MuteSwitch: Sendable {
    /// What the switch muted, kept until it unmutes them or they are unmuted elsewhere.
    public private(set) var muted: Set<AudioSideKey> = []

    public init() {}

    /// The click: whether it mutes, and the sides to set.
    public mutating func toggle(_ state: SoundState) -> (mute: Bool, sides: [MuteSide]) {
        let all = state.devices.flatMap { device in [AudioDirection.output, .input].map { MuteSide(device, $0) } }
            .filter { $0.device.side($0.direction) != nil }
        // A side unmuted since, elsewhere or by the microphone item, is no longer the switch's.
        muted.subtract(all.filter { $0.device.side($0.direction)?.muted == false }.map(\.key))
        let output = state.defaultDevice(.output).map { MuteSide($0, .output) }
        if state.switchOn {
            let sides = ([output].compactMap { $0 } + state.micTargets.map { MuteSide($0, .input) }).filter { $0.can(false) }
            muted.formUnion(sides.map(\.key))
            return (true, sides)
        }
        var sides = all.filter { muted.contains($0.key) && $0.can(true) }
        if let output, output.can(true), !sides.contains(output) { sides.append(output) }
        // Nothing of the switch's to restore, as on the monitors with a microphone muted
        // elsewhere: the click unmutes the targets, the only thing it then controls.
        if sides.isEmpty { sides = state.micTargets.map { MuteSide($0, .input) }.filter { $0.can(true) } }
        muted = []
        return (false, sides)
    }
}

/// Moves the default input back to the built-in microphone whenever macOS makes a Bluetooth
/// headset's microphone the default, as opening it drops the headset into the call profile, at
/// 24 kHz, and leaves a headset microphone Steve picked (docs/sound.md, preferBuiltInMic).
/// macOS's routes, on connecting, returning to the ear and after coreaudiod restarted, moved the
/// default output to the headset 5 to 50 ms before the input in coreaudiod's log on 2026-10-07;
/// a pick in System Settings' Input list moves the input alone.
public struct MicKeeper: Sendable {
    /// How long after the default output moves to a headset its microphone becoming the default
    /// still counts as macOS's route.
    public static let routeWindow: TimeInterval = 2
    /// Switches away from one headset within `fightWindow` before ZenithBar stops and leaves it,
    /// as macOS putting it back each time.
    public static let fightLimit = 3
    public static let fightWindow: TimeInterval = 60

    public enum Decision: Equatable, Sendable {
        /// Make `builtIn` the default input in place of `headset`; `first` when the headset was the
        /// default at the first check, as at launch, after coreaudiod restarted, or when the
        /// setting turned on.
        case switchBack(builtIn: AudioDevice, headset: AudioDevice, first: Bool)
        /// Leave `headset`'s microphone the default until it disconnects: it became the default
        /// with no output moving to it, as a pick in System Settings does, or, `fighting`, macOS
        /// put it back `fightLimit` times.
        case leave(headset: AudioDevice, fighting: Bool)
    }

    private var started = false
    /// The default input's UID at the last check, or the built-in microphone's after a switch, so
    /// macOS putting the headset back before the next read still reads as a change.
    private var input: String?
    /// The default output's and input's IDs at the last check, and when each took its value. A
    /// move is dated by the ID's change, not by when the device reads fully: on 2026-10-09
    /// coreaudiod made the AirPods the default output at 19:42:21.852 and logged their output
    /// streams only at 23.765, and a device without streams in a direction reads as no default.
    private var output: (id: AudioObjectID?, since: TimeInterval)?
    private var inputID: (id: AudioObjectID?, since: TimeInterval)?
    /// Headset microphones that stay the default until they disconnect.
    private var kept: Set<String> = []
    /// When ZenithBar switched away from each headset microphone.
    private var switches: [String: [TimeInterval]] = [:]

    /// How long a headset microphone's decision waits for an unlisted default output to list.
    public static let listWait: TimeInterval = 10

    public init() {}

    /// What to do about `state`'s default input, read at `now`, in seconds: nothing unless it has
    /// just become a Bluetooth microphone, or is one at the first check.
    public mutating func check(_ state: SoundState, now: TimeInterval) -> Decision? {
        let listed = Set(state.devices(.input).map(\.uid))
        kept.formIntersection(listed)
        switches = switches.filter { listed.contains($0.key) }
        if output == nil || output?.id != state.defaultOutput { output = (state.defaultOutput, now) }
        if inputID == nil || inputID?.id != state.defaultInput { inputID = (state.defaultInput, now) }
        let first = !started, previous = input
        started = true
        let current = state.defaultDevice(.input)
        guard let headset = current, headset.transport == .bluetooth, first || headset.uid != previous,
              !kept.contains(headset.uid), let builtIn = state.builtInMic else {
            input = current?.uid
            return nil
        }
        if !first {
            let seen = inputID?.since ?? now, movedAt = output?.since ?? now
            // By ID, whatever its streams: `defaultDevice(.output)` needs streams, and the AirPods
            // had none yet on 2026-10-09, so their microphone read as a pick (docs/sound.md, 10).
            guard let moved = state.devices.first(where: { $0.id == state.defaultOutput }) else {
                // Named the default before CoreAudio lists it: decide once it lists, leaving
                // `input` unrecorded so the next read sees the change again.
                if now - seen < Self.listWait, (0...Self.routeWindow).contains(seen - movedAt) { return nil }
                return leave(headset)
            }
            guard moved.transport == .bluetooth, Self.headset(moved) == Self.headset(headset),
                  (0...Self.routeWindow).contains(seen - movedAt) else { return leave(headset) }
        }
        let recent = (switches[headset.uid] ?? []).filter { now - $0 < Self.fightWindow }
        guard recent.count < Self.fightLimit else {
            input = headset.uid
            kept.insert(headset.uid)
            return .leave(headset: headset, fighting: true)
        }
        switches[headset.uid] = recent + [now]
        input = builtIn.uid
        return .switchBack(builtIn: builtIn, headset: headset, first: first)
    }

    private mutating func leave(_ headset: AudioDevice) -> Decision {
        input = headset.uid
        kept.insert(headset.uid)
        return .leave(headset: headset, fighting: false)
    }

    /// Steve picked `uid` as the default input in the panel: a headset's microphone stays until it
    /// disconnects, and picking another ends that.
    public mutating func chose(_ uid: String) { kept = [uid] }

    /// A headset's output and input share its Bluetooth address, as `7C-1A-2B-3C-4D-03:output`
    /// and `:input`.
    private static func headset(_ device: AudioDevice) -> String { bluetoothAddress(uid: device.uid) ?? device.name }
}

extension SoundState {
    /// The MacBook's own microphone, by its UID or the built-in microphone's data source,
    /// `imic`, read on Steve's M3 Pro (docs/sound.md, the devices).
    public var builtInMic: AudioDevice? {
        devices(.input).first {
            $0.transport == .builtIn && $0.input?.canBeDefault == true
                && ($0.uid == "BuiltInMicrophoneDevice" || $0.input?.dataSource == fourCharCode("imic"))
        }
    }
}

public enum MicState: Equatable, Sendable {
    case hidden, live, muted

    /// The SF Symbol and whether it shows in the alert color.
    public var symbol: (name: String, alert: Bool)? {
        switch self {
        case .hidden: nil
        case .live: ("mic.fill", false)
        case .muted: ("mic.slash.fill", true)
        }
    }
}

/// Omarchy's name for an output volume, from Model.js `outputVolumeName`.
public func outputVolumeName(_ volume: Double, muted: Bool) -> String {
    if muted { return "Muted" }
    let percent = Int((volume * 100).rounded())
    if percent == 0 { return "Silenced" }
    if percent >= 100 { return "Concert hall" }
    if percent >= 85 { return "Party mode" }
    if percent >= 70 { return "Cranked up" }
    if percent >= 50 { return "Steady groove" }
    if percent >= 30 { return "Easy listening" }
    if percent >= 15 { return "Murmur" }
    return "Whisper"
}

/// "13%", or "--" for a side without a volume.
public func volumePercent(_ volume: Double?) -> String { volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "--" }

/// `volume` moved by `steps` of 5%, as Omarchy's scroll and keys step, kept from 0 to 1.
public func stepVolume(_ volume: Double, steps: Int) -> Double { min(1, max(0, volume + Double(steps) * 0.05)) }

/// The SF Symbol a device's row shows, and the speaker's in place of the speaker glyph for
/// headphones: the AirPods' model by their product ID, `airpods` for other Bluetooth devices
/// named "AirPods", `headphones` for other headphones, else by how it connects.
public func deviceSymbol(_ device: AudioDevice, _ direction: AudioDirection, bluetooth: BluetoothDevice?) -> String {
    if let symbol = headphonesSymbol(device, bluetooth: bluetooth) { return symbol }
    switch device.transport {
    case .hdmi, .displayPort: return "display"
    case .bluetooth: return "dot.radiowaves.left.and.right"
    case .usb: return "cable.connector"
    case .virtual: return "waveform"
    case .airPlay: return "airplayaudio"
    case .continuity: return "iphone"
    case .builtIn, .aggregate, .thunderbolt, .other: return direction == .output ? "hifispeaker.fill" : "mic.fill"
    }
}

/// AirPods' or headphones' symbol, or nil for a device that is neither. Names, which Steve can
/// edit, count only where Bluetooth gives no product, as Omarchy's `isHeadphones` reads them.
public func headphonesSymbol(_ device: AudioDevice, bluetooth: BluetoothDevice?) -> String? {
    if let model = bluetooth.flatMap(airpodsSymbol) { return model }
    let name = device.name.lowercased()
    if device.transport == .bluetooth, name.contains("airpods") { return "airpods" }
    // The headphone jack, a data source of the built-in output.
    if device.output?.dataSource == fourCharCode("hdpn") { return "headphones" }
    if bluetooth?.minorType == "Headphones" { return "headphones" }
    if bluetooth == nil, ["headphone", "headset", "earbud", "earphone", "airpod"].contains(where: name.contains) {
        return "headphones"
    }
    return nil
}

/// The speaker item's SF Symbol and whether it shows dim: AirPods or headphones when the default
/// output is one, dim while muted, else the speaker by volume.
public func outputSymbol(_ device: AudioDevice?, bluetooth: BluetoothDevice?) -> (name: String, dim: Bool) {
    let muted = device?.output?.muted ?? false
    if let device, let symbol = headphonesSymbol(device, bluetooth: bluetooth) { return (symbol, muted) }
    // An output without a volume, as Steve's monitors, shows full.
    return volumeSymbol(device?.output?.volume ?? 1, muted: muted)
}

public func fourCharCode(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

// MARK: listeners

/// A CoreAudio property ZenithBar listens to.
public struct AudioWatch: Hashable, Sendable {
    public var object: AudioObjectID
    public var selector: AudioObjectPropertySelector
    public var scope: AudioObjectPropertyScope

    public init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.object = object
        self.selector = selector
        self.scope = scope
    }
}

/// Every property the speaker, the microphone item and the open panel follow for `state`:
/// coreaudiod restarting, the device list and the defaults; the default output's volume, mute
/// and data source; and each input device's running, mute and volume. A new state's set, against
/// the last, says which listeners to add and which to drop, as devices come and go and the
/// default changes.
public func soundWatches(_ state: SoundState) -> Set<AudioWatch> {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var watches: Set<AudioWatch> = [
        AudioWatch(system, kAudioHardwarePropertyServiceRestarted),
        AudioWatch(system, kAudioHardwarePropertyDevices),
        AudioWatch(system, kAudioHardwarePropertyDefaultOutputDevice),
        AudioWatch(system, kAudioHardwarePropertyDefaultInputDevice),
    ]
    let levels = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]
    if let output = state.defaultDevice(.output) {
        for selector in levels + [kAudioDevicePropertyDataSource] {
            watches.insert(AudioWatch(output.id, selector, kAudioObjectPropertyScopeOutput))
        }
    }
    // AirPods gain their output streams after they connect and after their microphone is let go,
    // with no other property changing, so a device's streams are watched in both directions.
    for device in state.devices {
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            watches.insert(AudioWatch(device.id, kAudioDevicePropertyStreams, scope))
        }
    }
    for device in state.devices(.input) {
        watches.insert(AudioWatch(device.id, kAudioDevicePropertyDeviceIsRunningSomewhere))
        for selector in levels { watches.insert(AudioWatch(device.id, selector, kAudioObjectPropertyScopeInput)) }
    }
    return watches
}

/// Keeps one step per notch of a mouse wheel, and one per `points` of a trackpad's scroll,
/// carrying what is left between events and dropping it when the direction turns, after
/// Omarchy's `wheelSteps`. Momentum after the fingers lift moves nothing, so a flick does not
/// run the volume to an end.
public struct ScrollSteps: Sendable {
    public static let points = 12.0
    private var carried = 0.0

    public init() {}

    /// `delta` up positive, as the hand moved.
    public mutating func steps(delta: Double, precise: Bool, momentum: Bool) -> Int {
        guard !momentum, delta != 0 else { return 0 }
        guard precise else {
            carried = 0
            return delta > 0 ? 1 : -1
        }
        if carried * delta < 0 { carried = 0 }
        carried += delta
        let steps = Int(carried / Self.points)
        carried -= Double(steps) * Self.points
        return steps
    }
}
