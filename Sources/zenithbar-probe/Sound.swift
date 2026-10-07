// What the sound panel and the microphone item read from CoreAudio and what they cost
// (docs/sound.md). No probe opens an audio stream, so none turns on the microphone indicator,
// and only `sound write` changes anything, on a virtual device alone.
//
//   zenithbar-probe sound read [runs]
//       Every device CoreAudio lists: its name, UID, manufacturer, transport type, streams in
//       each direction, data source with the names of all its sources, whether it can be the
//       default, its volume and mute in each direction with whether each is settable, and
//       whether it is running anywhere; the defaults; each audio process with its PID, bundle
//       ID, devices and whether it runs input or output. Then times the reads, median of `runs`
//       (default 50).
//   zenithbar-probe sound watch [seconds]
//       Listens, without polling, to the device list, the defaults, the process list, and on
//       each device to running anywhere, data source, volume and mute in each direction, and on
//       each process to running input and output, printing each change with its time.
//       Default: 120 s.
//   zenithbar-probe sound cost [seconds]
//       The probe's CPU and coreaudiod's a second, idle and then with every listener `watch`
//       adds, in 5 s stretches taking turns. Default: 60 s.
//   zenithbar-probe sound write <device name>
//       On a device whose transport is virtual, as Microsoft Teams Audio: sets its input mute
//       on and its input volume 0.05 lower, confirms each read back and each listener fired,
//       and restores both. On another input device, only while no process runs it
//       (`kAudioDevicePropertyDeviceIsRunningSomewhere` 0), as the MacBook Pro Microphone: its
//       input mute alone, the same way. Prints coreaudiod's settings files' modification times
//       before and after, to see when it saves. Refuses any other device.
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

@MainActor func sound(_ arguments: [String]) {
    // For pumpEvents, with no Dock icon.
    NSApplication.shared.setActivationPolicy(.prohibited)
    switch arguments.first {
    case "read": soundRead(runs: arguments.dropFirst().first.flatMap(Int.init) ?? 50)
    case "watch":
        soundWatch(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 120)
        return
    case "cost":
        soundCost(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 60)
        return
    case "write":
        guard arguments.count > 1 else { usage() }
        soundWrite(arguments.dropFirst().joined(separator: " "))
    default: usage()
    }
    exit(0)
}

// MARK: reads

private let system = AudioObjectID(kAudioObjectSystemObject)
private let input = kAudioObjectPropertyScopeInput, output = kAudioObjectPropertyScopeOutput
private let global = kAudioObjectPropertyScopeGlobal

private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = global,
                     _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = global) -> Bool {
    var a = address(selector, scope)
    return AudioObjectHasProperty(object, &a)
}

private func settable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = global) -> Bool {
    var a = address(selector, scope), result = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(object, &a, &result) == noErr && result.boolValue
}

private func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = global, _ initial: T) -> T? {
    var a = address(selector, scope), result = initial, size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &result) == noErr ? result : nil
}

private func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = global, _ zero: T) -> [T] {
    var a = address(selector, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var result = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &result) == noErr else { return [] }
    return result
}

private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = global) -> String? {
    var a = address(selector, scope), result: Unmanaged<CFString>?, size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &result) == noErr else { return nil }
    return result?.takeRetainedValue() as String?
}

private func icon(_ device: AudioObjectID) -> String? {
    var a = address(kAudioDevicePropertyIcon), result: Unmanaged<CFURL>?, size = UInt32(MemoryLayout<CFURL?>.size)
    guard AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &size, &result) == noErr else {
        return nil
    }
    return (result?.takeRetainedValue() as URL?)?.lastPathComponent
}

private func fourCC(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? "'" + String(decoding: bytes, as: UTF8.self) + "'" : String(code)
}

private func dataSourceName(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope, _ source: UInt32) -> String? {
    var id = source, name: Unmanaged<CFString>?
    var translation = withUnsafeMutablePointer(to: &id) { idPointer in
        withUnsafeMutablePointer(to: &name) { namePointer in
            AudioValueTranslation(mInputData: idPointer, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                  mOutputData: namePointer, mOutputDataSize: UInt32(MemoryLayout<CFString?>.size))
        }
    }
    var a = address(kAudioDevicePropertyDataSourceNameForIDCFString, scope)
    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
    guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &translation) == noErr else { return nil }
    return name?.takeRetainedValue() as String?
}

private func devices() -> [AudioObjectID] { array(system, kAudioHardwarePropertyDevices, global, AudioObjectID(0)) }

private func streams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    array(device, kAudioDevicePropertyStreams, scope, AudioObjectID(0)).count
}

private func name(_ device: AudioObjectID) -> String { string(device, kAudioObjectPropertyName) ?? "#\(device)" }

private func describeLevel(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
    let volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    var parts: [String] = []
    if has(device, volumeSelector, scope) {
        let level: String = value(device, volumeSelector, scope, Float32(0)).map { String(format: "%.2f", $0) } ?? "?"
        parts.append("volume \(level)\(settable(device, volumeSelector, scope) ? " settable" : " read only")")
    } else {
        parts.append("no volume")
    }
    // Some devices have a volume only on each channel, which the virtual main volume covers.
    let channels = (1...2).filter { has(device, kAudioDevicePropertyVolumeScalar, scope, element: $0) }
    if !channels.isEmpty { parts.append("channel volumes \(channels)") }
    if has(device, kAudioDevicePropertyMute, scope) {
        let mute: String = value(device, kAudioDevicePropertyMute, scope, UInt32(0)).map { $0 != 0 ? "on" : "off" } ?? "?"
        parts.append("mute \(mute)\(settable(device, kAudioDevicePropertyMute, scope) ? " settable" : " read only")")
    } else {
        parts.append("no mute")
    }
    return parts.joined(separator: ", ")
}

private func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                 element: UInt32) -> Bool {
    var a = address(selector, scope, element)
    return AudioObjectHasProperty(object, &a)
}

private func describeSource(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
    guard has(device, kAudioDevicePropertyDataSource, scope) else { return "no data source" }
    let current = value(device, kAudioDevicePropertyDataSource, scope, UInt32(0))
    let all = array(device, kAudioDevicePropertyDataSources, scope, UInt32(0))
    let listed = all.map { "\(fourCC($0)) \(dataSourceName(device, scope, $0) ?? "?")" }.joined(separator: "; ")
    return "data source \(current.map(fourCC) ?? "?") of [\(listed)]"
}

private func processes() -> [AudioObjectID] {
    array(system, kAudioHardwarePropertyProcessObjectList, global, AudioObjectID(0))
}

private func describeProcess(_ process: AudioObjectID) -> String {
    let pid = value(process, kAudioProcessPropertyPID, global, pid_t(0)) ?? 0
    let bundle = string(process, kAudioProcessPropertyBundleID) ?? "-"
    let runningInput = value(process, kAudioProcessPropertyIsRunningInput, global, UInt32(0)) ?? 0
    let runningOutput = value(process, kAudioProcessPropertyIsRunningOutput, global, UInt32(0)) ?? 0
    let inputDevices = array(process, kAudioProcessPropertyDevices, input, AudioObjectID(0)).map(name)
    let outputDevices = array(process, kAudioProcessPropertyDevices, output, AudioObjectID(0)).map(name)
    return "pid \(pid) \(bundle) input \(runningInput != 0 ? "running" : "idle") \(inputDevices) "
        + "output \(runningOutput != 0 ? "running" : "idle") \(outputDevices)"
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func median(_ values: [Double]) -> String {
    let sorted = values.sorted()
    return String(format: "%.3f ms", sorted[sorted.count / 2])
}

@MainActor private func soundRead(runs: Int) {
    for device in devices() {
        let transport = value(device, kAudioDevicePropertyTransportType, global, UInt32(0)).map(fourCC) ?? "?"
        print("\(device) \(name(device)) uid \(string(device, kAudioDevicePropertyDeviceUID) ?? "?") "
            + "by \(string(device, kAudioObjectPropertyManufacturer) ?? "?") transport \(transport) "
            + "model \(string(device, kAudioDevicePropertyModelUID) ?? "?") "
            + "running somewhere \(value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, global, UInt32(0)) ?? 9) "
            + "hidden \(value(device, kAudioDevicePropertyIsHidden, global, UInt32(0)) ?? 9) "
            + "icon \(icon(device) ?? "none")")
        for (label, scope) in [("output", output), ("input", input)] {
            let count = streams(device, scope)
            guard count > 0 else { continue }
            let canDefault = value(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope, UInt32(0)) ?? 9
            let canSystem = value(device, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope, UInt32(0)) ?? 9
            print("  \(label): \(count) streams, can be default \(canDefault), system default \(canSystem); "
                + "\(describeSource(device, scope)); \(describeLevel(device, scope))")
        }
    }
    for (label, selector) in [("default output", kAudioHardwarePropertyDefaultOutputDevice),
                              ("default input", kAudioHardwarePropertyDefaultInputDevice),
                              ("default system output", kAudioHardwarePropertyDefaultSystemOutputDevice)] {
        print("\(label): \(value(system, selector, global, AudioObjectID(0)).map(name) ?? "?")")
    }
    print("processes:")
    for process in processes() { print("  \(describeProcess(process))") }
    bluetooth()

    // Timings, median of `runs`.
    let all = devices()
    func time(_ label: String, _ body: () -> Void) {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            body()
            samples.append(milliseconds(since: start))
        }
        print("\(label): \(median(samples))")
    }
    time("device list") { _ = devices() }
    time("every device's name, transport, streams each way, volume and mute") {
        for device in all {
            _ = name(device)
            _ = value(device, kAudioDevicePropertyTransportType, global, UInt32(0))
            for scope in [input, output] where streams(device, scope) > 0 {
                _ = value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, Float32(0))
                _ = value(device, kAudioDevicePropertyMute, scope, UInt32(0))
            }
        }
    }
    time("every device's running somewhere") {
        for device in all { _ = value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, global, UInt32(0)) }
    }
    time("process list and each one's running input") {
        for process in processes() { _ = value(process, kAudioProcessPropertyIsRunningInput, global, UInt32(0)) }
    }
}

/// Bluetooth's paired devices from `system_profiler SPBluetoothDataType -json`, which needs no
/// Bluetooth permission, timed, and each Bluetooth audio device CoreAudio lists matched to one by
/// the address its UID starts with.
private func bluetooth() {
    let start = ContinuousClock.now
    let json = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
    print(String(format: "system_profiler SPBluetoothDataType -json: %.0f ms", milliseconds(since: start)))
    var paired: [String: [String: Any]] = [:]
    let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    for controller in root?["SPBluetoothDataType"] as? [[String: Any]] ?? [] {
        for case let (state, list as [[String: [String: Any]]]) in controller {
            for entry in list {
                for (name, info) in entry {
                    print("  \(state) \(name): address \(info["device_address"] ?? "-"), vendor \(info["device_vendorID"] ?? "-"), "
                        + "product \(info["device_productID"] ?? "-"), minor type \(info["device_minorType"] ?? "-")")
                    if let address = info["device_address"] as? String { paired[address.uppercased()] = info }
                }
            }
        }
    }
    let bluetoothTransports = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
    for device in devices() where bluetoothTransports.contains(value(device, kAudioDevicePropertyTransportType, global, UInt32(0)) ?? 0) {
        let uid = string(device, kAudioDevicePropertyDeviceUID) ?? ""
        let address = String(uid.prefix(17)).replacingOccurrences(of: "-", with: ":").uppercased()
        print("  CoreAudio \(name(device)) uid \(uid): \(paired[address].map { "paired, product \($0["device_productID"] ?? "-")" } ?? "no match")")
    }
}

// MARK: watch

/// Each listener `watch` and `cost` add, kept so `cost` can take them off again.
@MainActor private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

@MainActor private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = global, _ changed: @escaping @MainActor () -> Void) {
    var a = address(selector, scope)
    guard AudioObjectHasProperty(object, &a) else { return }
    let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { changed() } }
    if AudioObjectAddPropertyListenerBlock(object, &a, .main, block) == noErr { listeners.append((object, a, block)) }
}

@MainActor private func unlistenAll() {
    for (object, a, block) in listeners {
        var a = a
        AudioObjectRemovePropertyListenerBlock(object, &a, .main, block)
    }
    listeners = []
}

/// Listens to everything the panel and the microphone item would, printing each change when
/// `report` is given; the device and process lists listen again when they change.
@MainActor private func listenAll(report: ((String) -> Void)?) {
    unlistenAll()
    let say = report ?? { _ in }
    listen(system, kAudioHardwarePropertyDevices) {
        say("devices: \(devices().map(name))")
        listenAll(report: report)
    }
    for (label, selector) in [("default output", kAudioHardwarePropertyDefaultOutputDevice),
                              ("default input", kAudioHardwarePropertyDefaultInputDevice),
                              ("default system output", kAudioHardwarePropertyDefaultSystemOutputDevice)] {
        listen(system, selector) { say("\(label): \(value(system, selector, global, AudioObjectID(0)).map(name) ?? "?")") }
    }
    listen(system, kAudioHardwarePropertyProcessObjectList) {
        say("processes: \(processes().count)")
        listenAll(report: report)
    }
    for device in devices() {
        let label = name(device)
        listen(device, kAudioDevicePropertyDeviceIsRunningSomewhere) {
            say("\(label) running somewhere \(value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, global, UInt32(0)) ?? 9)")
        }
        for (direction, scope) in [("output", output), ("input", input)] where streams(device, scope) > 0 {
            listen(device, kAudioDevicePropertyDataSource, scope) { say("\(label) \(direction) \(describeSource(device, scope))") }
            listen(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope) {
                say("\(label) \(direction) \(describeLevel(device, scope))")
            }
            listen(device, kAudioDevicePropertyMute, scope) { say("\(label) \(direction) \(describeLevel(device, scope))") }
        }
    }
    for process in processes() {
        listen(process, kAudioProcessPropertyIsRunningInput) { say("process \(describeProcess(process))") }
        listen(process, kAudioProcessPropertyIsRunningOutput) { say("process \(describeProcess(process))") }
    }
}

@MainActor private func soundWatch(seconds: Double) {
    let start = ContinuousClock.now
    listenAll { line in print("\(stamp(start)) \(line)") }
    print("\(stamp(start)) listening to \(listeners.count) properties for \(Int(seconds)) s")
    pumpEvents(seconds)
    exit(0)
}

@MainActor private func soundCost(seconds: Double) {
    let me = getpid(), daemon = pid(of: "coreaudiod")
    var stretches: [(listening: Bool, cpu: Double, daemon: Double?)] = []
    var listening = false
    var registering: [Double] = [], registered = 0
    var last = (rusageCPU(me) ?? 0, daemon.flatMap(psCPU), ContinuousClock.now)
    let stretch = 5.0, count = max(2, Int(seconds / stretch))
    var done = 0
    func next() {
        let now = (rusageCPU(me) ?? 0, daemon.flatMap(psCPU), ContinuousClock.now)
        let span = milliseconds(since: last.2) / 1000
        let daemonCPU = zip(now.1, last.1).map { ($0 - $1) / span }
        stretches.append((listening, (now.0 - last.0) / span, daemonCPU))
        last = now
        done += 1
        if done >= count { return report() }
        listening.toggle()
        let start = ContinuousClock.now
        if listening { listenAll(report: nil) } else { unlistenAll() }
        if listening { registering.append(milliseconds(since: start)); registered = listeners.count }
        // Taken after registering, so a stretch holds only what listening costs while it waits.
        last = (rusageCPU(me) ?? 0, daemon.flatMap(psCPU), ContinuousClock.now)
        DispatchQueue.main.asyncAfter(deadline: .now() + stretch) { MainActor.assumeIsolated { next() } }
    }
    func report() {
        for mode in [false, true] {
            // The first stretch holds the probe's start.
            let runs = stretches.dropFirst().filter { $0.listening == mode }
            let cpu = runs.map(\.cpu).sorted(), coreaudiod = runs.compactMap(\.daemon).sorted()
            print(String(format: "%@: probe %.3f to %.3f ms a second, coreaudiod %@", mode ? "listening" : "idle",
                         cpu.first ?? 0, cpu.last ?? 0,
                         coreaudiod.isEmpty ? "unread" : String(format: "%.1f to %.1f ms a second", coreaudiod.first!,
                                                                 coreaudiod.last!)))
        }
        print("registering \(registered) listeners: \(median(registering)) median")
        exit(0)
    }
    print("\(count) stretches of \(Int(stretch)) s, idle and listening taking turns, idle first")
    DispatchQueue.main.asyncAfter(deadline: .now() + stretch) { MainActor.assumeIsolated { next() } }
    pumpEvents(Double(count + 2) * stretch)
}

private func zip(_ a: Double?, _ b: Double?) -> (Double, Double)? {
    guard let a, let b else { return nil }
    return (a, b)
}

// MARK: write

@MainActor private func soundWrite(_ deviceName: String) {
    guard let device = devices().first(where: { name($0) == deviceName }) else { return print("no device \(deviceName)") }
    let virtual = value(device, kAudioDevicePropertyTransportType, global, UInt32(0)) == kAudioDeviceTransportTypeVirtual
    guard virtual || (streams(device, input) > 0 && value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, global,
                                                         UInt32(1)) == 0) else {
        return print("\(deviceName) is neither virtual nor an input device no process runs; the probe leaves it alone")
    }
    func saved() -> String {
        ["DeviceSettings", "SystemSettings"].map { file in
            let path = "/Library/Preferences/Audio/com.apple.audio.\(file).plist"
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return "\(file) \(date.map { "\($0)" } ?? "?")"
        }.joined(separator: ", ")
    }
    print("saved: \(saved())")
    let muteSelector = kAudioDevicePropertyMute, volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    print("before: input \(describeLevel(device, input))")
    var heard: [String] = []
    let start = ContinuousClock.now
    listen(device, muteSelector, input) {
        heard.append("mute")
        print("\(stamp(start)) mute listener reads \(value(device, muteSelector, input, UInt32(9)) ?? 9)")
    }
    listen(device, volumeSelector, input) {
        heard.append("volume")
        print("\(stamp(start)) volume listener reads \(value(device, volumeSelector, input, Float32(9)) ?? 9)")
    }

    func set<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, _ newValue: T) -> OSStatus {
        var a = address(selector, input), v = newValue
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    if has(device, muteSelector, input), let mute = value(device, muteSelector, input, UInt32(0)) {
        let before = ContinuousClock.now
        let status = set(muteSelector, UInt32(mute == 0 ? 1 : 0))
        let took = milliseconds(since: before)
        print("\(stamp(start)) mute reads \(value(device, muteSelector, input, UInt32(9)) ?? 9) at once")
        settle()
        print(String(format: "mute set to %d: status %d in %.2f ms, reads %@, listener %@", mute == 0 ? 1 : 0, status, took,
                     "\(value(device, muteSelector, input, UInt32(9)) ?? 9)", heard.contains("mute") ? "fired" : "silent"))
        _ = set(muteSelector, mute)
        settle()
        print("mute restored to \(mute): reads \(value(device, muteSelector, input, UInt32(9)) ?? 9)")
    } else {
        print("no input mute")
    }
    if virtual, has(device, volumeSelector, input), let level = value(device, volumeSelector, input, Float32(0)) {
        let lower = max(0, level - 0.05)
        let status = set(volumeSelector, lower)
        print("\(stamp(start)) volume reads \(value(device, volumeSelector, input, Float32(9)) ?? 9) at once")
        settle()
        print(String(format: "volume set to %.2f: status %d, reads %.2f, listener %@", lower, status,
                     value(device, volumeSelector, input, Float32(9)) ?? 9, heard.contains("volume") ? "fired" : "silent"))
        _ = set(volumeSelector, level)
        settle()
        print(String(format: "volume restored to %.2f: reads %.2f", level, value(device, volumeSelector, input, Float32(9)) ?? 9))
    } else {
        print(virtual ? "no input volume" : "input volume left alone")
    }
    print("after: input \(describeLevel(device, input))")
    print("saved: \(saved())")
}
