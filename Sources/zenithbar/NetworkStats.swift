import Foundation
import ZenithBarCore
import ZenithBarKit

/// The network panel's live figures, read only while it is open: every 1.5 s, as Omarchy's
/// panel polls, the primary interface's byte counters and link speed from the kernel's
/// interface list, and one ICMP echo each to the router and to 1.1.1.1. A sample cost the
/// probe about 1 ms of CPU, against 10 ms for running /sbin/ping twice (docs/network.md, the
/// panel's cost).
@MainActor final class NetworkSampler {
    struct Sample {
        var counters: Counters?
        /// Bits a second, 0 when the kernel gives none.
        var linkSpeed: UInt64
        /// Each host pinged, with its round trip in ms, nil for no reply within a second.
        var replies: [String: Double?]
    }

    nonisolated static let internet = "1.1.1.1"
    private let queue = DispatchQueue(label: "io.github.st-eez.zenithbar.stats")
    private var timer: Timer?
    private var busy = false
    private var sequence: UInt16 = 0
    private var target: (interface: String, router: String?)?
    private let sampled: @MainActor (Sample) -> Void

    init(sampled: @escaping @MainActor (Sample) -> Void) { self.sampled = sampled }

    /// Samples `interface` now and every 1.5 s until `stop`, a sample asked for while one
    /// runs skipped.
    func start(interface: String, router: String?) {
        let changed = target?.interface != interface || target?.router != router
        target = (interface, router)
        if timer == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { _ in MainActor.assumeIsolated { self.sample() } }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            sample()
        } else if changed {
            sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        target = nil
    }

    private func sample() {
        guard let target, !busy else { return }
        busy = true
        sequence &+= 1
        let sequence = self.sequence
        queue.async {
            let data = interfaceData(target.interface)
            let hosts = [target.router, Self.internet].compactMap { $0 }
            let replies = ping(hosts, sequence: sequence, timeout: 1)
            let sample = Sample(
                counters: data.map {
                    Counters(interface: target.interface, received: $0.received, sent: $0.sent,
                             time: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
                },
                linkSpeed: data?.speed ?? 0,
                replies: Dictionary(uniqueKeysWithValues: hosts.map { ($0, replies[$0]) }))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    // A sample for an interface the panel has left, or after it closed, is dropped.
                    if self.target?.interface == target.interface { self.sampled(sample) }
                }
            }
        }
    }
}

/// `name`'s received and sent bytes and link speed, from the kernel's interface list with
/// 64-bit counters (NET_RT_IFLIST2). The probe read it in 0.6 ms of CPU.
private func interfaceData(_ name: String) -> (received: UInt64, sent: UInt64, speed: UInt64)? {
    let index = if_nametoindex(name)
    guard index != 0 else { return nil }
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var length = 0
    guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: length)
    guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
    return buffer.withUnsafeBytes { raw in
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            if header.ifm_type == RTM_IFINFO2, UInt32(header.ifm_index) == index {
                let data = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self).ifm_data
                return (data.ifi_ibytes, data.ifi_obytes, UInt64(data.ifi_baudrate))
            }
            guard header.ifm_msglen > 0 else { break }
            offset += Int(header.ifm_msglen)
        }
        return nil
    }
}

/// One ICMP echo to each of `hosts`, IPv4 addresses, over a datagram socket, which macOS lets
/// a process without privileges open, and each reply's round trip in ms; a host without a
/// reply within `timeout` seconds is left out.
private func ping(_ hosts: [String], sequence: UInt16, timeout: Double) -> [String: Double] {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard fd >= 0 else {
        log.error("Could not open an ICMP socket: errno \(errno)")
        return [:]
    }
    defer { close(fd) }
    var sent: [String: UInt64] = [:]
    for host in hosts {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { continue }
        var packet: [UInt8] = [8, 0, 0, 0, 0x5a, 0x42, UInt8(sequence >> 8), UInt8(sequence & 0xff)]
            + Array(repeating: 0, count: 8)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == packet.count { sent[host] = DispatchTime.now().uptimeNanoseconds }
    }
    var replies: [String: Double] = [:]
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1e9)
    while replies.count < sent.count {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { break }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(max(1, (deadline - now) / 1_000_000))) > 0 else { break }
        var buffer = [UInt8](repeating: 0, count: 256)
        var from = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &size) }
        }
        // The reply comes with its IP header; an echo reply is type 0, matched by its sequence.
        guard count > 20 else { continue }
        let header = Int(buffer[0] & 0x0f) * 4
        guard count >= header + 8, buffer[header] == 0,
              UInt16(buffer[header + 6]) << 8 | UInt16(buffer[header + 7]) == sequence else { continue }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        let host = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if let start = sent[host] { replies[host] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
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

/// macOS's speed test, `networkQuality --json`, which prints a reading about every 200 ms
/// and ran about 20 s, moving some 600 MB, on Steve's Ethernet (docs/network.md, the speed test).
@MainActor final class SpeedTest {
    enum State: Equatable {
        case idle
        case running(SpeedTestReading, started: Date)
        case done(SpeedTestReading, at: Date)
        case failed(String)
    }

    private(set) var state = State.idle
    private var process: Process?
    private let changed: @MainActor () -> Void

    init(changed: @escaping @MainActor () -> Void) { self.changed = changed }

    var running: Bool { process != nil }

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = ["--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let started = Date()
        state = .running(SpeedTestReading(), started: started)
        let output = pipe.fileHandleForReading
        do {
            try process.run()
            self.process = process
        } catch {
            log.error("Could not run networkQuality: \(error, privacy: .public)")
            state = .failed("Speed test failed")
            return changed()
        }
        // Read on a thread of its own to the end of the output, then wait for the exit, so the
        // last line is read before the result is.
        Thread.detachNewThread { [weak self] in
            var parsed = SpeedTestOutput(), tail = Data()
            while true {
                let data = output.availableData
                if data.isEmpty { break }
                tail = (tail + data).suffix(2000)
                let readings = parsed.append(data)
                if !readings.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { self?.read(readings) } } }
            }
            process.waitUntilExit()
            let status = process.terminationStatus, summary = String(decoding: tail, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(status: status, last: summary) } }
        }
        changed()
    }

    private func read(_ readings: [SpeedTestReading]) {
        guard case .running(var reading, let started) = state else { return }
        for next in readings { reading.merge(next) }
        state = .running(reading, started: started)
        changed()
    }

    private func finish(status: Int32, last: String) {
        log.info("networkQuality exited \(status); its output ended: \(last, privacy: .public)")
        process = nil
        if case let .running(reading, _) = state, status == 0, reading.downMbps != nil {
            state = .done(reading, at: Date())
        } else {
            state = .failed("Speed test failed")
        }
        changed()
    }
}
