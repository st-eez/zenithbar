import Foundation

// What the network panel shows, apart from AppKit and the system's reads, after Omarchy 4's
// network panel (`shell/plugins/panels/network/Model.js`) (docs/network.md, the panel).

/// "512 B", "3.6 KB", "1.09 GB", as Omarchy writes byte counts, in 1024s.
public func formatBytes(_ bytes: Double) -> String {
    let n = bytes.isFinite && bytes > 0 ? bytes : 0
    if n < 1024 { return "\(Int(n.rounded())) B" }
    if n < 1024 * 1024 { return String(format: "%.1f KB", n / 1024) }
    if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", n / (1024 * 1024)) }
    return String(format: "%.2f GB", n / (1024 * 1024 * 1024))
}

public func formatRate(_ bytesPerSecond: Double) -> String { formatBytes(bytesPerSecond) + "/s" }

/// "--" before the first reply or loss, "Timeout" when every recent echo went unanswered,
/// "1.2 ms" under 10 ms, "18 ms" from 10.
public func formatPing(_ ms: Double?, hasSamples: Bool) -> String {
    guard hasSamples else { return "--" }
    guard let ms else { return "Timeout" }
    return String(format: ms < 10 ? "%.1f ms" : "%.0f ms", ms)
}

/// A link's speed in bits a second as Omarchy's header writes it: "100mbit", "1gbit",
/// "2.5gbit"; nil when the kernel gives none.
public func formatLinkSpeed(_ bitsPerSecond: UInt64) -> String? {
    let mbit = Int(bitsPerSecond / 1_000_000)
    guard mbit > 0 else { return nil }
    if mbit >= 1000 { return mbit % 1000 == 0 ? "\(mbit / 1000)gbit" : String(format: "%.1fgbit", Double(mbit) / 1000) }
    return "\(mbit)mbit"
}

/// "93.6 Mbps", "940 Mbps", "1.2 Gbps".
public func formatMbps(_ mbps: Double) -> String {
    if mbps >= 1000 { return String(format: "%.1f Gbps", mbps / 1000) }
    return String(format: mbps < 100 ? "%.1f Mbps" : "%.0f Mbps", mbps)
}

public enum WifiBand: Sendable {
    case ghz2, ghz5, ghz6

    /// "2.4ghz", as Omarchy's header writes a frequency.
    public var label: String {
        switch self {
        case .ghz2: "2.4ghz"
        case .ghz5: "5ghz"
        case .ghz6: "6ghz"
        }
    }
}

/// The header's title: the Wi-Fi network's name with its band, "Ethernet" with its link speed,
/// as "Ethernet (1gbit)", or what there is without a connection.
public func networkTitle(_ route: Route, ssid: String?, band: WifiBand?, linkSpeed: UInt64) -> String {
    switch route {
    case .wifi:
        let name = ssid ?? "Wi-Fi"
        return band.map { "\(name) (\($0.label))" } ?? name
    case .ethernet: return formatLinkSpeed(linkSpeed).map { "Ethernet (\($0))" } ?? "Ethernet"
    case .offline(wifiPower: false): return "Wi-Fi off"
    case .offline: return "Disconnected"
    }
}

/// Omarchy's captions under the title while connected, one every 2.8 s.
public let connectionPhrases = ["Wiring bits", "Handling packets", "Sorting frames", "Hauling bytes", "Routing crumbs",
                                "Counting collisions", "Bending light"]

/// The echoes of one host while the panel is open, oldest first, nil for each lost: the
/// latency is the mean of the last 5 answered within them, the loss the share of the last 24
/// lost, as Omarchy's `pingLatencyState`.
public struct PingHistory: Equatable, Sendable {
    public private(set) var samples: [Double?] = []
    public static let window = 24, averaged = 5

    public init() {}

    public mutating func append(_ ms: Double?) {
        samples.append(ms)
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    public var hasSamples: Bool { !samples.isEmpty }

    /// Nil when the last 5 echoes all went unanswered.
    public var latency: Double? {
        let answered = samples.suffix(Self.averaged).compactMap { $0 }
        return answered.isEmpty ? nil : answered.reduce(0, +) / Double(answered.count)
    }

    /// From 0 to 100.
    public var lossPercent: Int {
        samples.isEmpty ? 0 : Int((Double(samples.filter { $0 == nil }.count) / Double(samples.count) * 100).rounded())
    }
}

/// An interface's byte counters at a moment.
public struct Counters: Equatable, Sendable {
    public var interface: String
    public var received: UInt64, sent: UInt64
    /// Seconds, on any steady clock.
    public var time: Double

    public init(interface: String, received: UInt64, sent: UInt64, time: Double) {
        (self.interface, self.received, self.sent, self.time) = (interface, received, sent, time)
    }

    /// Bytes a second received and sent since `previous`, nil after a change of interface or
    /// with no time between, so the first sample after an open makes no spike. A counter
    /// that went back, as when an interface comes back, reads 0.
    public func rates(since previous: Counters?) -> (received: Double, sent: Double)? {
        guard let previous, previous.interface == interface, time > previous.time else { return nil }
        let span = time - previous.time
        return (received >= previous.received ? Double(received - previous.received) / span : 0,
                sent >= previous.sent ? Double(sent - previous.sent) / span : 0)
    }
}

/// A network a scan found.
public struct WifiNetwork: Equatable, Sendable {
    /// Nil for a hidden network, and for every network while Location Services withholds names.
    public var ssid: String?
    public var rssi: Int
    public var secure: Bool
    /// WPA or WPA2 Enterprise, which needs a user name as well.
    public var enterprise: Bool
    public var known: Bool
    public var connected: Bool

    public init(ssid: String?, rssi: Int, secure: Bool, enterprise: Bool = false, known: Bool, connected: Bool) {
        (self.ssid, self.rssi, self.secure, self.enterprise, self.known, self.connected) =
            (ssid, rssi, secure, enterprise, known, connected)
    }
}

/// One row a name, the strongest of its access points, the connected network first, then the
/// known ones, then by signal, as Omarchy's `sortWifiRows`. Hidden networks keep a row each.
public func wifiRows(_ found: [WifiNetwork]) -> [WifiNetwork] {
    var named: [String: WifiNetwork] = [:], hidden: [WifiNetwork] = []
    for network in found {
        guard let ssid = network.ssid, !ssid.isEmpty else { hidden.append(network); continue }
        if let kept = named[ssid] {
            var best = network.rssi > kept.rssi ? network : kept
            best.connected = kept.connected || network.connected
            named[ssid] = best
        } else {
            named[ssid] = network
        }
    }
    return (Array(named.values) + hidden).sorted { a, b in
        if a.connected != b.connected { return a.connected }
        if a.known != b.known { return a.known }
        if a.rssi != b.rssi { return a.rssi > b.rssi }
        return (a.ssid ?? "") < (b.ssid ?? "")
    }
}

/// The heading over row `index` of `rows`, as Omarchy's `wifiSectionTitle`: "KNOWN NETWORKS"
/// over the first known, "OTHER NETWORKS" over the first other.
public func wifiSection(_ rows: [WifiNetwork], at index: Int) -> String? {
    guard rows.indices.contains(index) else { return nil }
    let known = rows[index].known || rows[index].connected
    if index == 0 { return known ? "KNOWN NETWORKS" : "OTHER NETWORKS" }
    let before = rows[index - 1].known || rows[index - 1].connected
    return before && !known ? "OTHER NETWORKS" : nil
}

/// What a click on a row does, as Omarchy's row: the connected network disconnects, a secured
/// network the Mac does not know asks for its password, any other connects.
public enum WifiClick: Equatable, Sendable {
    case disconnect, askPassword, connect
    /// A hidden network, which a name must be typed for.
    case none
}

public func wifiClick(_ network: WifiNetwork) -> WifiClick {
    if network.ssid == nil { return .none }
    if network.connected { return .disconnect }
    if network.secure && !network.known { return .askPassword }
    return .connect
}

/// `networkQuality --json`'s output as it comes: a progress object a line, about every 200 ms,
/// then a summary printed over many lines, whose last line was "}" on 2026-10-07
/// (docs/network.md, the speed test).
public struct SpeedTestOutput: Sendable {
    private var pending = Data()
    /// The lines of a summary begun with a line "{" and not yet closed.
    private var block: [Data]?

    public init() {}

    /// The readings in `data`, from each whole line and each closed summary.
    public mutating func append(_ data: Data) -> [SpeedTestReading] {
        pending.append(data)
        var readings: [SpeedTestReading] = []
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(pending[pending.startIndex..<end])
            pending.removeSubrange(pending.startIndex...end)
            let trimmed = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if block != nil {
                block?.append(line)
                if trimmed == "}", let lines = block {
                    block = nil
                    SpeedTestReading(line: Data(lines.joined(separator: Data("\n".utf8)))).map { readings.append($0) }
                }
            } else if trimmed == "{" {
                block = [line]
            } else if let reading = SpeedTestReading(line: line) {
                readings.append(reading)
            }
        }
        return readings
    }
}

/// A reading of networkQuality's: the capacities and responsiveness found so far.
public struct SpeedTestReading: Equatable, Sendable {
    public var downMbps: Double?
    public var upMbps: Double?
    /// Round trips a minute under load.
    public var responsiveness: Double?

    public init(downMbps: Double? = nil, upMbps: Double? = nil, responsiveness: Double? = nil) {
        (self.downMbps, self.upMbps, self.responsiveness) = (downMbps, upMbps, responsiveness)
    }

    /// The reading on `line`: a progress event's `downlink_capacity_mbps`,
    /// `uplink_capacity_mbps` and `downlink_responsiveness_rpm`, or a summary's
    /// `dl_throughput` and `ul_throughput` in bits a second and `responsiveness`, as `-c`
    /// prints it. Nil for a line that is neither.
    public init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let number = { (key: String) in (object[key] as? NSNumber)?.doubleValue }
        downMbps = number("downlink_capacity_mbps") ?? number("dl_throughput").map { $0 / 1e6 }
        upMbps = number("uplink_capacity_mbps") ?? number("ul_throughput").map { $0 / 1e6 }
        responsiveness = number("responsiveness") ?? number("downlink_responsiveness_rpm").flatMap { $0 > 0 ? $0 : nil }
        if downMbps == nil, upMbps == nil, responsiveness == nil { return nil }
    }

    /// Later readings replace what they carry.
    public mutating func merge(_ next: SpeedTestReading) {
        downMbps = next.downMbps ?? downMbps
        upMbps = next.upMbps ?? upMbps
        responsiveness = next.responsiveness ?? responsiveness
    }

    /// "↓ 168 Mbps  ↑ 183 Mbps  950 RPM", with what it has.
    public var summary: String {
        var parts: [String] = []
        if let downMbps { parts.append("↓ " + formatMbps(downMbps)) }
        if let upMbps { parts.append("↑ " + formatMbps(upMbps)) }
        if let responsiveness { parts.append("\(Int(responsiveness.rounded())) RPM") }
        return parts.joined(separator: "  ")
    }
}
