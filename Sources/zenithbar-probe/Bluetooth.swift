// What the Bluetooth item and panel read from IOBluetooth, CoreBluetooth and system_profiler,
// and what they cost (docs/bluetooth.md). No probe turns Bluetooth off or connects or
// disconnects a device: `bluetooth noop` makes only writes that change nothing.
//
//   zenithbar-probe bluetooth read [runs]
//       CoreBluetooth's authorization; the controller's power by the private
//       IOBluetoothPreferenceGetControllerPowerState and by IOBluetoothHostController; each
//       paired device IOBluetooth lists, with its address, whether it is connected, its class
//       and the private battery and product properties; each device system_profiler lists with
//       its fields; whether JetBrainsMono NF has the three Bluetooth glyphs. Then times the
//       reads, median of `runs` (default 20), system_profiler's with its CPU.
//   zenithbar-probe bluetooth watch [seconds]
//       Listens, without polling, to CoreBluetooth's state, IOBluetooth's connect notifications
//       and each connected device's disconnect notification, and the controller's power
//       notifications, printing each with its time. Default: 120 s.
//   zenithbar-probe bluetooth cost [seconds]
//       The probe's CPU and bluetoothd's a second, idle and then with everything `watch`
//       registers, in 5 s stretches taking turns, each after a second to settle. Default: 60 s.
//   zenithbar-probe bluetooth noop
//       Sets the controller's power on through the private
//       IOBluetoothPreferenceSetControllerPowerState only while it reads on, and calls
//       closeConnection on a paired device that is not connected, printing what each returns.
//       Refuses when the power reads off or every device is connected.
import AppKit
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth

// Private, as blueutil calls them: 1 on, 0 off. Undocumented (docs/bluetooth.md).
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState") private func getPowerState() -> Int32
@_silgen_name("IOBluetoothPreferenceSetControllerPowerState") private func setPowerState(_ state: Int32)

@MainActor func bluetooth(_ arguments: [String]) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let number = arguments.dropFirst().first.flatMap(Double.init)
    switch arguments.first {
    case "read": bluetoothRead(runs: Int(number ?? 20))
    case "watch":
        bluetoothWatch(seconds: number ?? 120)
        return
    case "cost":
        bluetoothCost(seconds: number ?? 60)
        return
    case "noop": bluetoothNoop()
    default: usage()
    }
    exit(0)
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func median(_ values: [Double]) -> String {
    let sorted = values.sorted()
    return String(format: "median %.2f, max %.2f ms", sorted[sorted.count / 2], sorted.last ?? 0)
}

private func authorization() -> String {
    switch CBManager.authorization {
    case .notDetermined: "not determined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .allowedAlways: "allowed always"
    @unknown default: "unknown"
    }
}

private func paired() -> [IOBluetoothDevice] { IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] }

/// A private property of IOBluetoothDevice, read by key, or "-" where it has none.
private func privateValue(_ device: IOBluetoothDevice, _ key: String) -> String {
    device.responds(to: NSSelectorFromString(key)) ? "\(device.value(forKey: key) ?? "nil")" : "-"
}

/// system_profiler's output, its wall time and its CPU, children's rusage before and after.
private func profile() -> (json: [String: Any], wall: Double, cpu: Double) {
    func children() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_CHILDREN, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }
    let before = children(), start = ContinuousClock.now
    let text = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
    let wall = milliseconds(since: start)
    let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    return (json, wall, children() - before)
}

@MainActor private func bluetoothRead(runs: Int) {
    print("CoreBluetooth authorization: \(authorization())")
    var start = ContinuousClock.now
    let power = getPowerState()
    print("IOBluetoothPreferenceGetControllerPowerState: \(power), first call \(String(format: "%.1f", milliseconds(since: start))) ms")
    let controller = IOBluetoothHostController.default()
    print("IOBluetoothHostController: power \(controller?.powerState.rawValue ?? 99), address \(controller?.addressAsString() ?? "nil")")
    start = ContinuousClock.now
    let devices = paired()
    print("IOBluetooth paired devices: \(devices.count), first call \(String(format: "%.1f", milliseconds(since: start))) ms")
    for device in devices {
        print("  \(device.name ?? "nil") \(device.addressString ?? "nil"): connected \(device.isConnected()), "
            + "class \(device.deviceClassMajor)/\(device.deviceClassMinor), service \(device.serviceClassMajor), "
            + "vendor \(privateValue(device, "vendorID")), product \(privateValue(device, "productID")), "
            + "apple \(privateValue(device, "isAppleDevice")), LE \(privateValue(device, "isLowEnergyConnection")), "
            + "battery single \(privateValue(device, "batteryPercentSingle")) left \(privateValue(device, "batteryPercentLeft")) "
            + "right \(privateValue(device, "batteryPercentRight")) case \(privateValue(device, "batteryPercentCase"))")
    }

    let first = profile()
    print("system_profiler: \(String(format: "%.0f", first.wall)) ms, \(String(format: "%.0f", first.cpu)) ms CPU")
    for controller in first.json["SPBluetoothDataType"] as? [[String: Any]] ?? [] {
        if let properties = controller["controller_properties"] as? [String: Any] {
            print("  controller: state \(properties["controller_state"] ?? "nil"), chipset \(properties["controller_chipset"] ?? "nil")")
        }
        for (key, value) in controller where key != "controller_properties" {
            for case let entry as [String: [String: Any]] in value as? [Any] ?? [] {
                for (name, info) in entry {
                    print("  \(key) \(name): " + info.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                }
            }
        }
    }

    let font = NSFont(name: "JetBrainsMonoNF-Regular", size: 16)
    for (name, scalar) in [("on", 0xF00AF), ("connected", 0xF00B1), ("off", 0xF00B2)] {
        var characters = Array(String(UnicodeScalar(scalar)!).utf16), glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let found = font.map { CTFontGetGlyphsForCharacters($0 as CTFont, &characters, &glyphs, characters.count) } ?? false
        print(String(format: "glyph U+%05X (%@): %@ in JetBrainsMono NF, glyph %d", scalar, name, found ? "present" : "missing", glyphs[0]))
    }

    var powerReads: [Double] = [], deviceReads: [Double] = [], profiles: [Double] = [], profileCPU: [Double] = []
    for _ in 0..<runs {
        start = ContinuousClock.now
        _ = getPowerState()
        powerReads.append(milliseconds(since: start))
        start = ContinuousClock.now
        _ = paired().map { ($0.name, $0.addressString, $0.isConnected()) }
        deviceReads.append(milliseconds(since: start))
        let read = profile()
        profiles.append(read.wall)
        profileCPU.append(read.cpu)
    }
    print("reads, \(runs) runs: power \(median(powerReads)); paired devices with names and connected \(median(deviceReads)); "
        + "system_profiler \(median(profiles)) wall, \(median(profileCPU)) CPU")
}

// MARK: watch

/// Prints what CoreBluetooth and IOBluetooth send.
@MainActor private final class Watcher: NSObject, CBCentralManagerDelegate {
    let start = ContinuousClock.now
    var central: CBCentralManager?
    var connects: IOBluetoothUserNotification?
    var disconnects: [IOBluetoothUserNotification] = []
    var observers: [NSObjectProtocol] = []
    var quiet = false

    func say(_ text: String) { if !quiet { print("\(stamp(start)) \(text)") } }

    func listen() {
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        connects = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        for name in [NSNotification.Name.IOBluetoothHostControllerPoweredOn, .IOBluetoothHostControllerPoweredOff] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.say(name.rawValue) }
            })
        }
    }

    func stop() {
        central?.delegate = nil
        central = nil
        connects?.unregister()
        connects = nil
        for notification in disconnects { notification.unregister() }
        disconnects = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state.rawValue
        MainActor.assumeIsolated { say("CoreBluetooth state \(state) (5 on, 4 off, 3 unauthorized)") }
    }

    /// IOBluetooth calls this for every device connected when it registers, then for each new connection.
    @objc func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        say("connected \(device.name ?? "nil") \(device.addressString ?? "nil")")
        if let disconnect = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:))) {
            disconnects.append(disconnect)
        }
    }

    @objc func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        say("disconnected \(device.name ?? "nil") \(device.addressString ?? "nil")")
        notification.unregister()
    }
}

@MainActor private func bluetoothWatch(seconds: Double) {
    let watcher = Watcher()
    watcher.listen()
    print("watching for \(Int(seconds)) s")
    pumpEvents(seconds)
    watcher.stop()
    exit(0)
}

@MainActor private func bluetoothCost(seconds: Double) {
    let me = getpid(), daemon = pid(of: "bluetoothd")
    let watcher = Watcher()
    watcher.quiet = true
    var stretches: [(listening: Bool, cpu: Double, daemon: Double?)] = []
    var listening = false, registering: [Double] = []
    var last = (rusageCPU(me) ?? 0, daemon.flatMap(psCPU), ContinuousClock.now)
    let stretch = 5.0, count = max(2, Int(seconds / stretch))
    var done = 0
    func next() {
        let now = (rusageCPU(me) ?? 0, daemon.flatMap(psCPU), ContinuousClock.now)
        let span = milliseconds(since: last.2) / 1000
        let daemonCPU = now.1.flatMap { now in last.1.map { (now - $0) / span } }
        stretches.append((listening, (now.0 - last.0) / span, daemonCPU))
        done += 1
        if done >= count { return report() }
        listening.toggle()
        let start = ContinuousClock.now
        if listening { watcher.listen() } else { watcher.stop() }
        if listening { registering.append(milliseconds(since: start)) }
        // A second for bluetoothd to set up or end the sessions, so a stretch holds only what
        // listening costs while it waits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                last = (rusageCPU(me) ?? 0, daemon.flatMap(psCPU), ContinuousClock.now)
                DispatchQueue.main.asyncAfter(deadline: .now() + stretch) { MainActor.assumeIsolated { next() } }
            }
        }
    }
    func report() {
        for mode in [false, true] {
            let runs = stretches.dropFirst().filter { $0.listening == mode }
            let cpu = runs.map(\.cpu).sorted(), bluetoothd = runs.compactMap(\.daemon).sorted()
            print(String(format: "%@: probe %.3f to %.3f ms a second, bluetoothd %@", mode ? "listening" : "idle",
                         cpu.first ?? 0, cpu.last ?? 0,
                         bluetoothd.isEmpty ? "unread" : String(format: "%.1f to %.1f ms a second", bluetoothd.first!, bluetoothd.last!)))
        }
        print("registering: \(median(registering))")
        exit(0)
    }
    print("\(count) stretches of \(Int(stretch)) s, idle and listening taking turns, idle first")
    DispatchQueue.main.asyncAfter(deadline: .now() + stretch) { MainActor.assumeIsolated { next() } }
    pumpEvents(Double(count + 2) * (stretch + 1))
}

// MARK: noop

@MainActor private func bluetoothNoop() {
    let before = getPowerState()
    guard before == 1 else { return print("power reads \(before), not on; the probe sets it only while on") }
    var start = ContinuousClock.now
    setPowerState(1)
    print("IOBluetoothPreferenceSetControllerPowerState(1) while on: returned in \(String(format: "%.1f", milliseconds(since: start))) ms, "
        + "power reads \(getPowerState()) after")
    guard let idle = paired().first(where: { !$0.isConnected() }) else { return print("every paired device is connected") }
    start = ContinuousClock.now
    let result = idle.closeConnection()
    print("closeConnection on \(idle.name ?? "nil"), not connected: \(String(format: "0x%08x", result)) in "
        + "\(String(format: "%.1f", milliseconds(since: start))) ms, connected after: \(idle.isConnected())")
}
