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
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.readSoon() }
    }

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        read()
    }

    /// Reads once for a burst of listener calls, as AirPods switching profiles or a volume key
    /// held down send many.
    private func readSoon() {
        guard !readPending else { return }
        readPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
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
        for watch in watches.subtracting(wanted) {
            var address = AudioObjectPropertyAddress(mSelector: watch.selector, mScope: watch.scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            // A device that went answers with an error, its listeners already gone with it.
            AudioObjectRemovePropertyListenerBlock(watch.object, &address, .main, listener)
        }
        for watch in wanted.subtracting(watches) {
            var address = AudioObjectPropertyAddress(mSelector: watch.selector, mScope: watch.scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(watch.object, &address) {
                AudioObjectAddPropertyListenerBlock(watch.object, &address, .main, listener)
            }
        }
        watches = wanted
        lookUpBluetooth(next)
        guard next != state else { return }
        state = next
        changed()
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
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.bluetooth.merge(found) { $1 }
                    self.changed()
                }
            }
        }
    }

    // MARK: writes, each read back through the listeners

    func setVolume(_ device: AudioObjectID, _ direction: AudioDirection, _ volume: Double) {
        var value = Float32(min(1, max(0, volume)))
        set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, direction.scope, &value)
    }

    func setMute(_ device: AudioObjectID, _ direction: AudioDirection, _ mute: Bool) {
        var value = UInt32(mute ? 1 : 0)
        set(device, kAudioDevicePropertyMute, direction.scope, &value)
    }

    func setDefault(_ device: AudioObjectID, _ direction: AudioDirection) {
        var value = device
        set(AudioObjectID(kAudioObjectSystemObject),
            direction == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal, &value)
    }

    /// The default output's volume moved by `steps` of 5%, as a scroll on the speaker.
    func stepOutput(_ steps: Int) {
        guard let device = state.defaultDevice(.output), let side = device.output, side.volumeSettable,
              let volume = side.volume else { return }
        setVolume(device.id, .output, stepVolume(volume, steps: steps))
    }

    /// The default input's level moved by `steps` of 5%, as a scroll on the microphone.
    func stepInput(_ steps: Int) {
        guard let device = state.defaultDevice(.input), let side = device.input, side.volumeSettable,
              let volume = side.volume else { return }
        setVolume(device.id, .input, stepVolume(volume, steps: steps))
    }

    func toggleOutputMute() {
        guard let device = state.defaultDevice(.output), let muted = device.output?.muted, device.output?.muteSettable == true
        else { return }
        setMute(device.id, .output, !muted)
    }

    /// The microphone item's click (`SoundState.micToggle`).
    func toggleMic() {
        let toggle = state.micToggle
        for device in toggle.devices { setMute(device, .input, toggle.mute) }
    }

    /// The panel's switch (`SoundState.masterToggle`).
    func toggleAll() {
        let toggle = state.masterToggle
        if let output = toggle.output { setMute(output, .output, toggle.mute) }
        for device in toggle.inputs { setMute(device, .input, toggle.mute) }
    }

    private func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                        _ value: inout T) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
        if status != noErr { log.error("CoreAudio refused to set \(selector) on device \(object): \(status)") }
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
