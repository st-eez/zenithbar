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

    /// Input devices some app runs. A device with both directions counts while only its output
    /// runs, as the property covers the device (docs/sound.md, the microphone).
    public var micInUse: [AudioDevice] { devices.filter { $0.running && $0.input != nil } }

    /// What a click on the microphone mutes or unmutes: the input devices in use, and the
    /// default input, so a click with nothing in use still mutes the next call's microphone.
    public var micTargets: [AudioDevice] {
        var targets = micInUse
        if let input = defaultDevice(.input), !targets.contains(where: { $0.id == input.id }) { targets.append(input) }
        return targets
    }

    /// Some app hears a microphone: an input device in use is unmuted, or has no mute.
    public var micLive: Bool { micInUse.contains { $0.input?.muted != true } }

    /// The microphone item: live while an app hears it, muted while a target is muted and none
    /// is heard, and hidden otherwise.
    public var mic: MicState {
        if micLive { return .live }
        return micTargets.contains { $0.input?.muted == true } ? .muted : .hidden
    }

    /// A click on the microphone item: mutes every target while live or unmuted, else unmutes
    /// them. Only devices whose mute is settable.
    public var micToggle: (mute: Bool, devices: [AudioObjectID]) {
        let mute = mic != .muted
        return (mute, micTargets.filter { $0.input?.muteSettable == true && $0.input?.muted != mute }.map(\.id))
    }

    /// The header's switch, as Omarchy's: on while the output or a microphone target is unmuted.
    /// Only sides with a mute count, so an output without one leaves it able to read off.
    public var anyAudible: Bool {
        output?.muted == false || micTargets.contains { $0.input?.muted == false }
    }

    /// The switch's click: mutes the output and every microphone target while anything is
    /// audible, else unmutes them all.
    public var masterToggle: (mute: Bool, output: AudioObjectID?, inputs: [AudioObjectID]) {
        let mute = anyAudible
        let output = defaultDevice(.output).flatMap { $0.output?.muteSettable == true && $0.output?.muted != mute ? $0.id : nil }
        let inputs = micTargets.filter { $0.input?.muteSettable == true && $0.input?.muted != mute }.map(\.id)
        return (mute, output, inputs)
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

// MARK: Bluetooth

/// What Bluetooth knows of a paired device, from `system_profiler SPBluetoothDataType -json`.
public struct BluetoothDevice: Equatable, Sendable {
    public var vendorID: Int?
    public var productID: Int?
    /// Bluetooth's minor device class, as "Headphones".
    public var minorType: String?

    public init(vendorID: Int? = nil, productID: Int? = nil, minorType: String? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.minorType = minorType
    }
}

/// The paired devices in system_profiler's JSON, by address in capitals with colons.
public func bluetoothDevices(json: Data) -> [String: BluetoothDevice] {
    guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return [:] }
    var found: [String: BluetoothDevice] = [:]
    func hex(_ value: Any?) -> Int? { (value as? String).flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } }
    for controller in root["SPBluetoothDataType"] as? [[String: Any]] ?? [] {
        // Connected and not connected devices are lists of one-entry objects keyed by name.
        for case let list as [[String: [String: Any]]] in controller.values {
            for info in list.flatMap(\.values) {
                guard let address = info["device_address"] as? String else { continue }
                found[address.uppercased()] = BluetoothDevice(vendorID: hex(info["device_vendorID"]),
                                                              productID: hex(info["device_productID"]),
                                                              minorType: info["device_minorType"] as? String)
            }
        }
    }
    return found
}

/// The Bluetooth address a CoreAudio UID starts with, as "7C-1A-2B-3C-4D-03:output", in
/// capitals with colons; nil for a UID without one.
public func bluetoothAddress(uid: String) -> String? {
    let head = uid.prefix(17).uppercased()
    let parts = head.split(whereSeparator: { $0 == "-" || $0 == ":" })
    guard head.count == 17, parts.count == 6, parts.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { return nil }
    return parts.joined(separator: ":")
}

/// Apple's AirPods by Bluetooth product ID, vendor 0x004C, as their SF Symbols.
private let airpodsModels: [Int: String] = [
    0x2002: "airpods", 0x200F: "airpods", // AirPods, 2nd generation
    0x2013: "airpods.gen3",
    0x2019: "airpods.gen4", 0x201B: "airpods.gen4", // AirPods 4, and with noise cancellation
    0x200E: "airpodspro", 0x2014: "airpodspro", 0x2024: "airpodspro", // Pro, Pro 2, Pro 2 USB-C
    0x200A: "airpodsmax", 0x201F: "airpodsmax", // Max, Max USB-C
]

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
    if let bluetooth, bluetooth.vendorID == 0x004C, let model = bluetooth.productID.flatMap({ airpodsModels[$0] }) {
        return model
    }
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

/// Every property the speaker, the microphone item and the open panel follow for `state`: the
/// device list and the defaults; the default output's volume, mute and data source; and each
/// input device's running, mute and volume. A new state's set, against the last, says which
/// listeners to add and which to drop, as devices come and go and the default changes.
public func soundWatches(_ state: SoundState) -> Set<AudioWatch> {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var watches: Set<AudioWatch> = [
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
