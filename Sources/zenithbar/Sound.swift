import AudioToolbox
import CoreAudio
import Foundation
import ZenithBarCore
import ZenithBarKit

/// Every audio device and the defaults, read from CoreAudio and followed through its listeners,
/// for the speaker, the microphone item and the sound panel (docs/sound.md). Nothing polls,
/// and nothing opens a stream, so ZenithBar never turns on the microphone indicator.
@MainActor final class Sound {
    private(set) var state = SoundState()
    /// Paired Bluetooth devices by address, for the AirPods' model.
    private(set) var bluetooth: [String: BluetoothDevice] = [:]
    private let changed: @MainActor () -> Void
    private var watches: Set<AudioWatch> = []
    private var readPending = false
    /// Addresses system_profiler was asked about, so each is asked once.
    private var lookedUp: Set<String> = []
    private var muteSwitch = MuteSwitch()
    private var keeper = MicKeeper()
    /// What the keeper's first check follows, for the log: launch, a coreaudiod restart, or the
    /// setting turning on, each of which starts a new keeper.
    private var keeperStart = "at launch"
    /// coreaudiod restarted, and the next read listens to everything again.
    private var restarted = false
    /// config.json's `preferBuiltInMic`. Turning it on acts on a headset microphone that is the
    /// default already, as at launch.
    var preferBuiltInMic: Bool {
        didSet {
            guard preferBuiltInMic, !oldValue else { return }
            keeper = MicKeeper()
            keeperStart = "when PREFER MACBOOK MIC turned on"
            read()
        }
    }
    private lazy var listener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] count, addresses in
        let restart = UnsafeBufferPointer(start: addresses, count: Int(count))
            .contains { $0.mSelector == kAudioHardwarePropertyServiceRestarted }
        onMain {
            if restart { self?.restarted = true }
            self?.readSoon()
        }
    }

    init(preferBuiltInMic: Bool, changed: @escaping @MainActor () -> Void) {
        self.preferBuiltInMic = preferBuiltInMic
        self.changed = changed
        read()
    }

    /// Reads once for a burst of listener calls, as AirPods switching profiles or a volume key
    /// held down send many.
    private func readSoon() {
        guard !readPending else { return }
        readPending = true
        DispatchQueue.main.async { [weak self] in
            onMain {
                self?.readPending = false
                self?.read()
            }
        }
    }

    /// Reads every device again, listens to what the new state needs and drops what it no longer
    /// does, as when a device goes or the default changes, and tells the bar when anything changed.
    func read() {
        let next = Self.readState()
        let wanted = soundWatches(next)
        // After coreaudiod restarts, every listener is dropped and added again: Apple's header
        // says a client must add its listeners again, the old device IDs are gone, and dropping
        // first leaves none twice whether CoreAudio kept it or not (docs/sound.md, coreaudiod).
        let drop = restarted ? watches : watches.subtracting(wanted)
        let add = restarted ? wanted : wanted.subtracting(watches)
        if restarted {
            restarted = false
            keeper = MicKeeper()
            keeperStart = "after coreaudiod restarted"
            log.notice("Sound: coreaudiod restarted: listening again to \(wanted.count) properties of \(next.devices.count) devices")
        }
        for watch in drop {
            var address = AudioObjectPropertyAddress(mSelector: watch.selector, mScope: watch.scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            // A device that went answers with an error, its listeners already gone with it.
            AudioObjectRemovePropertyListenerBlock(watch.object, &address, .main, listener)
        }
        for watch in add {
            var address = AudioObjectPropertyAddress(mSelector: watch.selector, mScope: watch.scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            // The system object reads as lacking ServiceRestarted on macOS 27, yet adding its
            // listener returns no error (zenithbar-probe sound restart, docs/sound.md, coreaudiod).
            if AudioObjectHasProperty(watch.object, &address) || watch.selector == kAudioHardwarePropertyServiceRestarted {
                AudioObjectAddPropertyListenerBlock(watch.object, &address, .main, listener)
            }
        }
        watches = wanted
        lookUpBluetooth(next)
        if preferBuiltInMic { keep(next) }
        guard next != state else { return }
        state = next
        changed()
    }

    /// preferBuiltInMic (`MicKeeper`): the switch comes back through the listener as a default
    /// that is not Bluetooth, so no write echoes.
    private func keep(_ next: SoundState) {
        switch keeper.check(next, now: ProcessInfo.processInfo.systemUptime) {
        case let .switchBack(builtIn, headset, first)?:
            let why = first ? "\(headset.name) was the default input \(keeperStart)"
                : "macOS moved the default output and input to \(headset.name)"
            setDefault(builtIn.id, .input, because: "preferBuiltInMic, as \(why)")
        case let .leave(headset, fighting)?:
            let why = fighting
                ? "macOS made it the default input again after \(MicKeeper.fightLimit) switches in \(Int(MicKeeper.fightWindow)) s"
                : "it became the default input with no output moving to it, as a pick in System Settings does"
            log.notice("Sound: preferBuiltInMic leaves \(self.describe(headset.id), privacy: .public) until it disconnects, as \(why, privacy: .public)")
        case nil: break
        }
    }

    func bluetooth(for device: AudioDevice) -> BluetoothDevice? {
        bluetoothAddress(uid: device.uid).flatMap { bluetooth[$0] }
    }

    /// Asks system_profiler, which needs no Bluetooth permission, about Bluetooth devices not
    /// asked about before, off the main thread: about 60 ms (docs/sound.md, AirPods).
    private func lookUpBluetooth(_ state: SoundState) {
        let addresses = Set(state.devices.filter { $0.transport == .bluetooth }.compactMap { bluetoothAddress(uid: $0.uid) })
        guard !addresses.isSubset(of: lookedUp) else { return }
        lookedUp.formUnion(addresses)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return log.error("Could not run system_profiler") }
            let found = bluetoothDevices(json: pipe.fileHandleForReading.readDataToEndOfFile())
            process.waitUntilExit()
            onMain {
                guard let self else { return }
                self.bluetooth.merge(found) { $1 }
                self.changed()
            }
        }
    }

    // MARK: writes, each read back through the listeners

    /// Each write is logged at notice level, with what the clicked control was and the value
    /// read before and after, so `log show` explains a glitch (docs/sound.md, writes).
    func setVolume(_ device: AudioObjectID, _ direction: AudioDirection, _ volume: Double, because reason: String) {
        write(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, direction, Float32(min(1, max(0, volume))),
              "volume", reason)
    }

    func setMute(_ device: AudioObjectID, _ direction: AudioDirection, _ mute: Bool, because reason: String) {
        write(device, kAudioDevicePropertyMute, direction, UInt32(mute ? 1 : 0), "mute", reason)
    }

    func setDefault(_ device: AudioObjectID, _ direction: AudioDirection, because reason: String) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let selector = direction == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        let before = Self.value(system, selector, AudioObjectID(0))
        var value = device, address = Self.address(selector, kAudioObjectPropertyScopeGlobal)
        let status = AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        let after = Self.value(system, selector, AudioObjectID(0))
        log.notice("""
            Sound: \(reason, privacy: .public): default \(String(describing: direction), privacy: .public) \
            \(self.describe(before), privacy: .public) -> \(self.describe(after), privacy: .public), \
            asked \(self.describe(device), privacy: .public), status \(status)
            """)
    }

    /// A panel row's click: makes the device the default, and a Bluetooth microphone picked
    /// there stays the default input until it disconnects or another is picked (`MicKeeper`).
    func choose(_ device: AudioObjectID, _ direction: AudioDirection) {
        if direction == .input, let uid = state.devices.first(where: { $0.id == device })?.uid { keeper.chose(uid) }
        setDefault(device, direction, because: "panel \(direction) row")
    }

    /// The default output's volume moved by `steps` of 5%, as a scroll on the speaker.
    func stepOutput(_ steps: Int) {
        guard let device = state.defaultDevice(.output), let side = device.output, side.volumeSettable,
              let volume = side.volume else { return }
        setVolume(device.id, .output, stepVolume(volume, steps: steps), because: "speaker scroll")
    }

    /// The default input's level moved by `steps` of 5%, as a scroll on the microphone.
    func stepInput(_ steps: Int) {
        guard let device = state.defaultDevice(.input), let side = device.input, side.volumeSettable,
              let volume = side.volume else { return }
        setVolume(device.id, .input, stepVolume(volume, steps: steps), because: "microphone scroll")
    }

    /// The speaker's right click, or a right click on a panel slider: mutes or unmutes the
    /// default device's side.
    func toggleMute(_ direction: AudioDirection, because reason: String) {
        guard let device = state.defaultDevice(direction), let muted = device.side(direction)?.muted,
              device.side(direction)?.muteSettable == true else { return }
        setMute(device.id, direction, !muted, because: reason)
    }

    /// The microphone item's click (`SoundState.micToggle`).
    func toggleMic() {
        let toggle = state.micToggle
        for device in toggle.devices { setMute(device, .input, toggle.mute, because: "microphone click") }
    }

    /// The panel's switch (`MuteSwitch`).
    func toggleAll() {
        let toggle = muteSwitch.toggle(state)
        for side in toggle.sides { setMute(side.device.id, side.direction, toggle.mute, because: "panel switch") }
    }

    private func write<T: BitwiseCopyable>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                           _ direction: AudioDirection, _ value: T, _ what: String, _ reason: String) {
        let before = Self.value(device, selector, value, direction.scope)
        var value = value, address = Self.address(selector, direction.scope)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
        let after = Self.value(device, selector, value, direction.scope)
        log.notice("""
            Sound: \(reason, privacy: .public): \(String(describing: direction), privacy: .public) \(what, privacy: .public) \
            of \(self.describe(device), privacy: .public), element main: \(Self.text(before), privacy: .public) -> \
            \(Self.text(after), privacy: .public), wrote \(Self.text(value), privacy: .public), status \(status)
            """)
    }

    /// "MacBook Pro Microphone (89, BuiltInMicrophoneDevice)".
    private func describe(_ device: AudioObjectID?) -> String {
        guard let device else { return "none" }
        let name = Self.string(device, kAudioObjectPropertyName) ?? "?", uid = Self.string(device, kAudioDevicePropertyDeviceUID) ?? "?"
        return "\(name) (\(device), \(uid))"
    }

    private static func text<T>(_ value: T?) -> String {
        switch value {
        case let value as Float32: String(format: "%.3f", value)
        case let value?: "\(value)"
        case nil: "unread"
        }
    }

    // MARK: reads

    /// Every device and the defaults, about 1.4 ms for Steve's five devices (docs/sound.md).
    private static func readState() -> SoundState {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids = array(system, kAudioHardwarePropertyDevices, AudioObjectID(0))
        let devices = ids.map { id in
            AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                        name: string(id, kAudioObjectPropertyName) ?? "Unknown",
                        transport: AudioTransport(code: value(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0),
                        running: (value(id, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) ?? 0) != 0,
                        output: side(id, .output), input: side(id, .input))
        }
        return SoundState(devices: devices,
                          defaultOutput: value(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
                          defaultInput: value(system, kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(0)))
    }

    /// Nil for a direction without streams.
    private static func side(_ device: AudioObjectID, _ direction: AudioDirection) -> AudioSide? {
        let scope = direction.scope
        guard !array(device, kAudioDevicePropertyStreams, AudioObjectID(0), scope).isEmpty else { return nil }
        let volume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mute = kAudioDevicePropertyMute
        return AudioSide(canBeDefault: (value(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, UInt32(0), scope) ?? 0) != 0,
                         volume: value(device, volume, Float32(0), scope).map(Double.init),
                         volumeSettable: settable(device, volume, scope),
                         muted: value(device, mute, UInt32(0), scope).map { $0 != 0 },
                         muteSettable: settable(device, mute, scope),
                         dataSource: value(device, kAudioDevicePropertyDataSource, UInt32(0), scope))
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Nil when the object lacks the property or the read fails, as for a device that just went.
    private static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                                                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = address(selector, scope), result = initial, size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
    }

    private static func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ zero: T,
                                                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var address = address(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return [] }
        return Array(result.prefix(Int(size) / MemoryLayout<T>.size))
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector, kAudioObjectPropertyScopeGlobal), result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }

    private static func settable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 _ scope: AudioObjectPropertyScope) -> Bool {
        var address = address(selector, scope), result = DarwinBoolean(false)
        return AudioObjectHasProperty(object, &address)
            && AudioObjectIsPropertySettable(object, &address, &result) == noErr && result.boolValue
    }
}
