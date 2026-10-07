// What CoreWLAN, SystemConfiguration and Network give a native network item, read without
// asking for any permission (docs/network.md).
//
//   zenith-probe network read [runs]
//       Prints the primary interface from SystemConfiguration's dynamic store and from an
//       NWPathMonitor's first path, each network service's interface, address and router, and
//       each hardware interface's type. Then what CoreWLAN gives this process for the Wi-Fi
//       interface: power, SSID, BSSID, RSSI, noise, transmit rate, channel, mode and the known
//       networks' names, and Location Services' authorization as CoreLocation reports it,
//       without requesting it. Times each read `runs` times (default 100).
//   zenith-probe network watch [seconds]
//       Monitors every CoreWLAN event, the store's keys for the primary interface, the
//       services' addresses and every interface's link, and an NWPathMonitor, and logs each
//       with the time a read in the handler took; logs sleep and wake. Reports the events'
//       counts and the probe's CPU. Default: 120 s.
//   zenith-probe network cost [seconds]
//       The CPU a second of the probe and airportd, in 5 s stretches taking turns, `seconds`
//       each (default 60): idle, monitoring every CoreWLAN event but link quality, monitoring
//       link quality, reading RSSI once a second, the store's notifications, and an
//       NWPathMonitor.
//   zenith-probe network launchd <arguments>
//       Runs `zenith-probe network <arguments>` as a LaunchAgent, as Zenith runs, so
//       CoreLocation judges the probe itself rather than the terminal it was started from, and
//       prints its output.
import AppKit
@preconcurrency import CoreLocation
@preconcurrency import CoreWLAN
import Network
import SystemConfiguration

@MainActor func network(_ arguments: [String]) {
    let number = arguments.dropFirst().first.flatMap(Double.init)
    switch arguments.first {
    case "read": networkRead(runs: Int(number ?? 100))
    case "watch": networkWatch(seconds: number ?? 120)
    case "cost": networkCost(seconds: number ?? 60)
    case "launchd" where arguments.count > 1: networkLaunchd(Array(arguments.dropFirst()))
    default: usage()
    }
    exit(0)
}

private func authorization() -> String {
    switch CLLocationManager().authorizationStatus {
    case .notDetermined: "not determined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorizedAlways: "authorized always"
    case .authorized: "authorized"
    @unknown default: "unknown"
    }
}

private func describe(_ interface: CWInterface) -> String {
    let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
    return """
        interface \(interface.interfaceName ?? "nil"): power \(interface.powerOn()), service active \(interface.serviceActive()), \
        mode \(interface.interfaceMode().rawValue), PHY \(interface.activePHYMode().rawValue)
          SSID \(interface.ssid() ?? "nil"), BSSID \(interface.bssid() ?? "nil"), security \(interface.security().rawValue)
          RSSI \(interface.rssiValue()) dBm, noise \(interface.noiseMeasurement()) dBm, \
        transmit rate \(interface.transmitRate()) Mb/s, channel \(interface.wlanChannel().map { "\($0.channelNumber)" } ?? "nil")
          known networks \(profiles.count), with a name \(profiles.filter { $0.ssid != nil }.count)
        """
}

/// Each hardware interface's BSD name, with its type and the name System Settings gives it.
private func hardware() -> [String: String] {
    Dictionary((SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { interface in
        SCNetworkInterfaceGetBSDName(interface).map {
            ($0 as String, "\(SCNetworkInterfaceGetInterfaceType(interface).map { $0 as String } ?? "?") "
                + "\"\(SCNetworkInterfaceGetLocalizedDisplayName(interface).map { $0 as String } ?? "?")\"")
        }
    }, uniquingKeysWith: { first, _ in first })
}

private func primary(_ store: SCDynamicStore) -> String? {
    (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryInterface"]
        as? String
}

/// Each network service's interface, address and router.
private func services(_ store: SCDynamicStore) -> [String] {
    (SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/IPv4"] as CFArray) as? [String: [String: Any]] ?? [:])
        .values.map { service in
            "\(service["InterfaceName"] as? String ?? "?") \((service["Addresses"] as? [String])?.first ?? "?") "
                + "router \(service["Router"] as? String ?? "none")"
        }.sorted()
}

private func describe(_ path: NWPath) -> String {
    "\(path.status), interfaces \(path.availableInterfaces.map { "\($0.name) \($0.type)" }), "
        + "gateways \(path.gateways.map { "\($0)" }), expensive \(path.isExpensive)"
}

/// An NWPathMonitor's first path, and how long it took to come.
private func firstPath() -> (NWPath, Double) {
    let monitor = NWPathMonitor(), done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var first: NWPath?
    let start = ContinuousClock.now
    monitor.pathUpdateHandler = { path in
        if first == nil { first = path; done.signal() }
    }
    monitor.start(queue: DispatchQueue(label: "path"))
    done.wait()
    let ms = milliseconds(since: start)
    monitor.cancel()
    return (first!, ms)
}

/// The interface's IPv4 address and its service's router, from SystemConfiguration's store.
private func addresses(_ name: String, store: SCDynamicStore) -> (address: String?, router: String?) {
    let address = (SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/IPv4" as CFString) as? [String: Any])?[
        "Addresses"] as? [String]
    let services = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/IPv4"] as CFArray) as? [String: [String: Any]]
    let router = services?.values.first { $0["InterfaceName"] as? String == name }?["Router"] as? String
    return (address?.first, router)
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func median(_ values: [Double]) -> String {
    let sorted = values.sorted()
    return String(format: "median %.3f, max %.3f ms", sorted[sorted.count / 2], sorted.last ?? 0)
}

// MARK: read

@MainActor private func networkRead(runs: Int) {
    let store = SCDynamicStoreCreate(nil, "zenith-probe" as CFString, nil, nil)!
    print("primary interface (store): \(primary(store) ?? "none")")
    let (path, pathMs) = firstPath()
    print(String(format: "NWPathMonitor's first path, after %.1f ms: %@", pathMs, describe(path)))
    print("services:\n  " + services(store).joined(separator: "\n  "))
    let types = hardware()
    print("hardware:\n  " + types.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "\n  "))
    print("bundle identifier: \(Bundle.main.bundleIdentifier ?? "nil"), parent pid \(getppid())")
    print("Location Services on: \(CLLocationManager.locationServicesEnabled()), this process: \(authorization())")
    var start = ContinuousClock.now
    let client = CWWiFiClient.shared()
    print(String(format: "CWWiFiClient.shared(): %.1f ms", milliseconds(since: start)))
    print("interface names: \(client.interfaceNames() ?? [])")
    guard let interface = client.interface() else { return print("no Wi-Fi interface") }
    print(describe(interface))
    let name = interface.interfaceName ?? "en0"
    let (address, router) = addresses(name, store: store)
    print("IPv4 \(address ?? "nil"), router \(router ?? "nil")")
    let reads: [(String, () -> Void)] = [
        ("powerOn", { _ = interface.powerOn() }),
        ("rssiValue", { _ = interface.rssiValue() }),
        ("noiseMeasurement", { _ = interface.noiseMeasurement() }),
        ("ssid", { _ = interface.ssid() }),
        ("transmitRate", { _ = interface.transmitRate() }),
        ("address and router", { _ = addresses(name, store: store) }),
        ("primary interface (store)", { _ = primary(store) }),
        ("every service", { _ = services(store) }),
        ("SCNetworkInterfaceCopyAll", { _ = hardware() }),
        ("NWPathMonitor's first path", { _ = firstPath() }),
    ]
    for (label, read) in reads {
        var times: [Double] = []
        for _ in 0..<runs {
            start = .now
            read()
            times.append(milliseconds(since: start))
        }
        print("\(label): \(median(times))")
    }
}

// MARK: watch

nonisolated(unsafe) private var watchStart = ContinuousClock.now
nonisolated(unsafe) private var counts: [String: Int] = [:]
private let countsLock = NSLock()

private func record(_ event: String, _ detail: String = "") {
    countsLock.withLock { counts[event, default: 0] += 1 }
    print("\(stamp(watchStart))  \(event)\(Thread.isMainThread ? "" : " (off main)")  \(detail)")
}

/// Logs each CoreWLAN event with a read of power and RSSI, timed, as an item would read them.
private final class Events: NSObject, CWEventDelegate, @unchecked Sendable {
    let interface = CWWiFiClient.shared().interface()
    let quiet: Bool

    init(quiet: Bool) { self.quiet = quiet }

    private func read(_ event: String, _ extra: String = "") {
        guard !quiet else { return countsLock.withLock { counts[event, default: 0] += 1 } }
        let start = ContinuousClock.now
        let power = interface?.powerOn() ?? false, rssi = interface?.rssiValue() ?? 0, ssid = interface?.ssid()
        record(event, String(format: "%@power %@, RSSI %d, SSID %@, read %.2f ms", extra, power ? "on" : "off", rssi,
                             ssid ?? "nil", milliseconds(since: start)))
    }

    func powerStateDidChangeForWiFiInterface(withName name: String) { read("power") }
    func ssidDidChangeForWiFiInterface(withName name: String) { read("ssid") }
    func bssidDidChangeForWiFiInterface(withName name: String) { read("bssid") }
    func linkDidChangeForWiFiInterface(withName name: String) { read("link") }
    func modeDidChangeForWiFiInterface(withName name: String) { read("mode") }
    func countryCodeDidChangeForWiFiInterface(withName name: String) { read("country code") }
    func scanCacheUpdatedForWiFiInterface(withName name: String) { read("scan cache") }
    func linkQualityDidChangeForWiFiInterface(withName name: String, rssi: Int, transmitRate: Double) {
        guard !quiet else { return countsLock.withLock { counts["link quality", default: 0] += 1 } }
        let start = ContinuousClock.now, read = interface?.rssiValue() ?? 0
        record("link quality", String(format: "RSSI %d, transmit rate %.0f; rssiValue() %d, read %.2f ms", rssi, transmitRate,
                                      read, milliseconds(since: start)))
    }
    func clientConnectionInterrupted() { record("connection interrupted") }
    func clientConnectionInvalidated() { record("connection invalidated") }
}

private let allEvents: [CWEventType] = [.powerDidChange, .ssidDidChange, .bssidDidChange, .countryCodeDidChange,
                                        .linkDidChange, .linkQualityDidChange, .modeDidChange, .scanCacheUpdated]

private func monitor(_ client: CWWiFiClient, _ events: [CWEventType]) {
    for event in events {
        do { try client.startMonitoringEvent(with: event) } catch { print("monitoring \(event.rawValue) failed: \(error)") }
    }
}

private func storeChanged(_ store: SCDynamicStore, _ keys: CFArray, _ info: UnsafeMutableRawPointer?) {
    for key in keys as? [String] ?? [] {
        record("store", "\(key): \(SCDynamicStoreCopyValue(store, key as CFString).map { "\($0)" }?.replacingOccurrences(of: "\n", with: " ") ?? "removed")")
    }
}

@MainActor private func networkWatch(seconds: Double) {
    NSApplication.shared.setActivationPolicy(.accessory)
    print("bundle identifier: \(Bundle.main.bundleIdentifier ?? "nil"), Location Services for this process: \(authorization())")
    watchStart = .now
    let client = CWWiFiClient.shared(), events = Events(quiet: false)
    client.delegate = events
    monitor(client, allEvents)
    let name = client.interface()?.interfaceName ?? "en0"
    let store = SCDynamicStoreCreate(nil, "zenith-probe" as CFString, storeChanged, nil)!
    SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/IPv4"] as CFArray,
                                      ["State:/Network/Interface/\(name)/.*", "State:/Network/Interface/[^/]+/Link",
                                       "State:/Network/Service/.*/IPv4"] as CFArray)
    CFRunLoopAddSource(CFRunLoopGetMain(), SCDynamicStoreCreateRunLoopSource(nil, store, 0), .defaultMode)
    let path = NWPathMonitor()
    path.pathUpdateHandler = { record("path", describe($0)) }
    path.start(queue: DispatchQueue(label: "path"))
    for note in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                 NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
        NSWorkspace.shared.notificationCenter.addObserver(forName: note, object: nil, queue: .main) { _ in
            record(note.rawValue, client.interface().map { "power \($0.powerOn()), RSSI \($0.rssiValue())" } ?? "")
        }
    }
    watchStart = .now
    let cpu = rusageCPU(getpid()) ?? 0
    pumpEvents(seconds)
    let spent = (rusageCPU(getpid()) ?? 0) - cpu
    print(countsLock.withLock { counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") })
    print(String(format: "probe CPU over %.0f s: %.1f ms, %.2f ms a second", seconds, spent, spent / seconds))
}

// MARK: cost

@MainActor private func networkCost(seconds: Double) {
    guard let airportd = pid(of: "airportd") else { return print("airportd is not running") }
    NSApplication.shared.setActivationPolicy(.accessory)
    let client = CWWiFiClient.shared(), events = Events(quiet: true), interface = client.interface()
    client.delegate = events
    let store = SCDynamicStoreCreate(nil, "zenith-probe" as CFString, storeChanged, nil)!
    CFRunLoopAddSource(CFRunLoopGetMain(), SCDynamicStoreCreateRunLoopSource(nil, store, 0), .defaultMode)
    var path: NWPathMonitor?
    let stretches: [(name: String, start: () -> Void, poll: (() -> Void)?)] = [
        ("idle", {}, nil),
        ("every event but link quality", { monitor(client, allEvents.filter { $0 != .linkQualityDidChange }) }, nil),
        ("link quality events", { monitor(client, [.linkQualityDidChange]) }, nil),
        ("RSSI read once a second", {}, { _ = interface?.rssiValue() }),
        ("store notifications", {
            SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/IPv4"] as CFArray,
                                              ["State:/Network/Interface/[^/]+/Link", "State:/Network/Service/.*/IPv4"] as CFArray)
        }, nil),
        ("NWPathMonitor", { path = NWPathMonitor(); path?.pathUpdateHandler = { _ in countsLock.withLock { counts["path", default: 0] += 1 } }
            path?.start(queue: DispatchQueue(label: "path")) }, nil),
    ]
    var totals = stretches.map { _ in [0.0, 0.0] }
    var seen = stretches.map { _ in 0 }
    for _ in 0..<Int(seconds / 5) {
        for (index, stretch) in stretches.enumerated() {
            stretch.start()
            let timer = stretch.poll.map { poll in
                nonisolated(unsafe) let poll = poll
                let timer = Timer(timeInterval: 1, repeats: true) { _ in poll() }
                RunLoop.main.add(timer, forMode: .common)
                return timer
            }
            let before = [rusageCPU(getpid()) ?? 0, psCPU(airportd) ?? 0]
            let counted = countsLock.withLock { counts.values.reduce(0, +) }
            pumpEvents(5)
            totals[index] = zip(totals[index], zip([rusageCPU(getpid()) ?? 0, psCPU(airportd) ?? 0], before).map { $0 - $1 })
                .map { $0 + $1 }
            seen[index] += countsLock.withLock { counts.values.reduce(0, +) } - counted
            timer?.invalidate()
            try? client.stopMonitoringAllEvents()
            SCDynamicStoreSetNotificationKeys(store, nil, nil)
            path?.cancel()
            path = nil
        }
    }
    for (index, stretch) in stretches.enumerated() {
        print(String(format: "%@: a second, probe %.2f ms, airportd %.2f ms; %d events", stretch.name,
                     totals[index][0] / seconds, totals[index][1] / seconds, seen[index]))
    }
    print(countsLock.withLock { counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") })
}

// MARK: launchd

/// Runs the probe as a LaunchAgent and prints what it printed.
@MainActor private func networkLaunchd(_ arguments: [String]) {
    let label = "io.github.st-eez.zenith-probe-network", domain = "gui/\(getuid())"
    let plist = URL(fileURLWithPath: "/tmp/\(label).plist"), output = "/tmp/\(label).log"
    let job: [String: Any] = [
        "Label": label, "ProgramArguments": [CommandLine.arguments[0], "network"] + arguments,
        "StandardOutPath": output, "StandardErrorPath": output, "LimitLoadToSessionType": "Aqua", "RunAtLoad": true,
    ]
    try? FileManager.default.removeItem(atPath: output)
    try! PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
    run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
    run("/bin/launchctl", ["bootstrap", domain, plist.path])
    // The job runs once at load, and launchd keeps it listed with its exit code once it exits.
    var state: String
    repeat {
        Thread.sleep(forTimeInterval: 0.5)
        state = run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        guard state.contains("state = ") else { return print("launchd did not load the job") }
    } while state.contains("pid = ") || state.contains("never exited")
    run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
    print((try? String(contentsOfFile: output, encoding: .utf8)) ?? "no output")
    print(state.split(separator: "\n").first { $0.contains("last exit code") }?.trimmingCharacters(in: .whitespaces) ?? "")
}
