// What the network panel reads and does, measured without changing the connection
// (docs/network.md, the panel).
//
//   zenithbar-probe network wifi
//       The Wi-Fi's channel, band and width; one scan, timed, with each network's name, RSSI,
//       channel, band and security, and whether it is known; the cached scan; and
//       `setPower(true)` while the power is on, which changes nothing and shows whether an
//       unentitled process may set it. Each hardware interface's link speed from the
//       kernel's interface list and from SystemConfiguration's media options.
//   zenithbar-probe network stats [seconds] [spawn]
//       Samples every 1.5 s, as Omarchy's panel does: the primary interface's byte counters
//       from the kernel's interface list, and one ICMP echo each to the router and 1.1.1.1
//       over an unprivileged datagram socket, or with `spawn`, through /sbin/ping run twice.
//       Prints each sample and the probe's CPU a sample. Default: 30 s.
//   zenithbar-probe network speedtest
//       Runs `networkQuality --json` once through a pipe, as the panel would, printing each
//       line it writes with its time. Uses the internet connection for about 20 s.
import Foundation
@preconcurrency import CoreWLAN
import SystemConfiguration

@MainActor func networkPanel(_ arguments: [String]) {
    switch arguments.first {
    case "wifi": wifiProbe()
    case "stats":
        statsProbe(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 30, spawn: arguments.contains("spawn"))
    case "speedtest": speedProbe()
    default: usage()
    }
    exit(0)
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func band(_ channel: CWChannel?) -> String {
    switch channel?.channelBand {
    case .band2GHz?: "2.4 GHz"
    case .band5GHz?: "5 GHz"
    case .band6GHz?: "6 GHz"
    default: "unknown band"
    }
}

private func security(_ network: CWNetwork) -> String {
    let kinds: [(CWSecurity, String)] = [(.none, "open"), (.OWE, "OWE"), (.WEP, "WEP"), (.wpaPersonal, "WPA"),
                                         (.wpa2Personal, "WPA2"), (.wpa3Personal, "WPA3"), (.wpa3Transition, "WPA3/2"),
                                         (.wpaEnterprise, "WPA Ent"), (.wpa2Enterprise, "WPA2 Ent"),
                                         (.wpa3Enterprise, "WPA3 Ent")]
    return kinds.filter { network.supportsSecurity($0.0) }.map(\.1).joined(separator: ",")
}

// MARK: wifi

@MainActor private func wifiProbe() {
    let client = CWWiFiClient.shared()
    guard let interface = client.interface() else { return print("no Wi-Fi interface") }
    let channel = interface.wlanChannel()
    print("power \(interface.powerOn()), SSID \(interface.ssid() ?? "nil"), channel \(channel?.channelNumber ?? 0), "
        + "\(band(channel)), width \(channel?.channelWidth.rawValue ?? 0), RSSI \(interface.rssiValue())")
    let known = Set((interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap(\.ssid))
    print("known networks: \(known.count)")
    let start = ContinuousClock.now
    do {
        let found = try interface.scanForNetworks(withSSID: nil)
        print(String(format: "scan: %.0f ms, %d networks, %d with a name", milliseconds(since: start), found.count,
                     found.filter { $0.ssid != nil }.count))
        for network in found.sorted(by: { $0.rssiValue > $1.rssiValue }) {
            print("  \(network.ssid ?? "nil") RSSI \(network.rssiValue) channel \(network.wlanChannel?.channelNumber ?? 0) "
                + "\(band(network.wlanChannel)) \(security(network))\(network.ssid.map(known.contains) == true ? " known" : "")")
        }
    } catch {
        print(String(format: "scan failed after %.0f ms: %@", milliseconds(since: start), "\(error)"))
    }
    print("cached scan: \(interface.cachedScanResults()?.count ?? 0) networks")
    if interface.powerOn() {
        do {
            try interface.setPower(true)
            print("setPower(true) while on: no error")
        } catch {
            print("setPower(true) while on: \(error)")
        }
    }
    for (name, speed) in linkSpeeds().sorted(by: { $0.key < $1.key }) { print("link \(name): \(speed) b/s (ifi_baudrate)") }
    for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
        guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
        var current: Unmanaged<CFDictionary>?, active: Unmanaged<CFDictionary>?, available: Unmanaged<CFArray>?
        guard SCNetworkInterfaceCopyMediaOptions(interface, &current, &active, &available, false) else { continue }
        let media = active?.takeRetainedValue() as? [String: Any]
        _ = current?.takeRetainedValue()
        _ = available?.takeRetainedValue()
        print("media \(name): \(media?["MediaSubType"] ?? "none") \(media?["MediaOptions"] ?? "")")
    }
}

// MARK: counters

/// Each interface's received and sent bytes and its link speed, from the kernel's interface
/// list with 64-bit counters (NET_RT_IFLIST2).
private func interfaceData(only: String? = nil) -> [String: (received: UInt64, sent: UInt64, speed: UInt64)] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    let wanted = only.map { if_nametoindex($0) }
    var length = 0
    guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return [:] }
    var buffer = [UInt8](repeating: 0, count: length)
    guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }
    var result: [String: (UInt64, UInt64, UInt64)] = [:]
    var offset = 0
    buffer.withUnsafeBytes { raw in
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            if header.ifm_type == RTM_IFINFO2, wanted == nil || UInt32(header.ifm_index) == wanted {
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                    result[String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)] = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes,
                                                     UInt64(message.ifm_data.ifi_baudrate))
                }
            }
            offset += Int(header.ifm_msglen)
        }
    }
    return result
}

private func linkSpeeds() -> [String: UInt64] {
    interfaceData().filter { $0.key.hasPrefix("en") }.mapValues(\.speed)
}

// MARK: ping

/// One ICMP echo to each of `hosts` over a datagram socket, which macOS lets an unprivileged
/// process open, and each reply's round trip in ms, nil for none within `timeout`.
private func ping(_ hosts: [String], sequence: UInt16, timeout: Double) -> [String: Double] {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard fd >= 0 else { print("ICMP socket: errno \(errno)"); return [:] }
    defer { close(fd) }
    var sent: [String: ContinuousClock.Instant] = [:]
    for host in hosts {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { continue }
        var packet: [UInt8] = [8, 0, 0, 0, 0x5a, 0x42, UInt8(sequence >> 8), UInt8(sequence & 0xff)] + Array(repeating: 0, count: 8)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == packet.count { sent[host] = .now }
    }
    var replies: [String: Double] = [:]
    let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
    while replies.count < sent.count, ContinuousClock.now < deadline {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let left = deadline - ContinuousClock.now
        guard poll(&poller, 1, Int32(max(1, left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000))) > 0
        else { break }
        var buffer = [UInt8](repeating: 0, count: 256)
        var from = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &size) }
        }
        // The reply comes with its IP header.
        guard count > 20 else { continue }
        let header = Int(buffer[0] & 0x0f) * 4
        guard count >= header + 8, buffer[header] == 0,
              UInt16(buffer[header + 6]) << 8 | UInt16(buffer[header + 7]) == sequence else { continue }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        let host = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if let start = sent[host] { replies[host] = milliseconds(since: start) }
    }
    return replies
}

private func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for index in stride(from: 0, to: bytes.count, by: 2) {
        sum += UInt32(bytes[index]) << 8 | UInt32(index + 1 < bytes.count ? bytes[index + 1] : 0)
    }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
}

private func spawnPing(_ host: String) -> Double? {
    let output = run("/sbin/ping", ["-n", "-c", "1", "-W", "1000", host])
    guard let range = output.range(of: "time=") else { return nil }
    return Double(output[range.upperBound...].prefix { $0.isNumber || $0 == "." })
}

// MARK: stats

@MainActor private func statsProbe(seconds: Double, spawn: Bool) {
    let store = SCDynamicStoreCreate(nil, "zenithbar-probe" as CFString, nil, nil)!
    let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    guard let name = global?["PrimaryInterface"] as? String, let router = global?["Router"] as? String else {
        return print("no primary interface")
    }
    print("primary \(name), router \(router), pings \(spawn ? "through /sbin/ping" : "over an ICMP datagram socket")")
    var last = interfaceData()[name], lastTime = ContinuousClock.now
    let readStart = ContinuousClock.now, readCPU = rusageCPU(getpid()) ?? 0
    for _ in 0..<100 { _ = interfaceData(only: name) }
    let pingStart = ContinuousClock.now, pingCPU = rusageCPU(getpid()) ?? 0
    for index in 0..<100 { _ = ping([router, "1.1.1.1"], sequence: UInt16(1000 + index), timeout: 1) }
    print(String(format: "two pings, 100 times: %.3f ms each, %.3f ms CPU each", milliseconds(since: pingStart) / 100,
                 ((rusageCPU(getpid()) ?? 0) - pingCPU) / 100))
    print(String(format: "the interface list, 100 reads: %.3f ms each, %.3f ms CPU each", milliseconds(since: readStart) / 100,
                 ((rusageCPU(getpid()) ?? 0) - readCPU) / 100))
    let cpu = rusageCPU(getpid()) ?? 0
    var samples = 0, routerLost = 0, internetLost = 0, sampleTimes: [Double] = []
    let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < end {
        let start = ContinuousClock.now
        let data = interfaceData(only: name)[name]
        let replies: [String: Double] = spawn
            ? [router: spawnPing(router), "1.1.1.1": spawnPing("1.1.1.1")].compactMapValues { $0 }
            : ping([router, "1.1.1.1"], sequence: UInt16(samples & 0xffff), timeout: 1)
        sampleTimes.append(milliseconds(since: start))
        let elapsed = milliseconds(since: lastTime) / 1000
        if let data, let last {
            print(String(format: "%@ ↓ %.1f KB/s ↑ %.1f KB/s, totals %.2f / %.2f GB; router %@, internet %@; sample %.1f ms",
                         stamp(start), Double(data.received - last.received) / elapsed / 1024,
                         Double(data.sent - last.sent) / elapsed / 1024, Double(data.received) / 1e9,
                         Double(data.sent) / 1e9, replies[router].map { String(format: "%.1f ms", $0) } ?? "lost",
                         replies["1.1.1.1"].map { String(format: "%.1f ms", $0) } ?? "lost", sampleTimes.last!))
        }
        if replies[router] == nil { routerLost += 1 }
        if replies["1.1.1.1"] == nil { internetLost += 1 }
        last = data
        lastTime = .now
        samples += 1
        Thread.sleep(until: Date(timeIntervalSinceNow: max(0, 1.5 - milliseconds(since: start) / 1000)))
    }
    let spent = (rusageCPU(getpid()) ?? 0) - cpu
    print(String(format: "%d samples, lost router %d, internet %d; probe CPU %.2f ms a sample, %.2f ms a second", samples,
                 routerLost, internetLost, spent / Double(samples), spent / seconds))
}

// MARK: speed test

@MainActor private func speedProbe() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
    process.arguments = ["--json"]
    let pipe = Pipe(), errors = Pipe()
    process.standardOutput = pipe
    process.standardError = errors
    let start = ContinuousClock.now
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        print("\(stamp(start)) stdout \(data.count) bytes: \(String(decoding: data, as: UTF8.self).prefix(600))")
    }
    errors.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        print("\(stamp(start)) stderr: \(String(decoding: data, as: UTF8.self).prefix(600))")
    }
    let cpu = rusageCPU(getpid()) ?? 0
    try! process.run()
    process.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.2)
    print(String(format: "exit %d after %@; probe CPU %.0f ms", process.terminationStatus, stamp(start),
                 (rusageCPU(getpid()) ?? 0) - cpu))
}
