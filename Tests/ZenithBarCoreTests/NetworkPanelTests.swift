import Foundation
import Testing
@testable import ZenithBarCore

@Test func formatsAsOmarchyDoes() {
    #expect(formatBytes(512) == "512 B")
    #expect(formatBytes(3686) == "3.6 KB")
    #expect(formatBytes(1.09 * 1024 * 1024 * 1024) == "1.09 GB")
    #expect(formatBytes(-.infinity) == "0 B")
    #expect(formatRate(550_000) == "537.1 KB/s")
    #expect(formatPing(nil, hasSamples: false) == "--")
    #expect(formatPing(nil, hasSamples: true) == "Timeout")
    #expect(formatPing(1.24, hasSamples: true) == "1.2 ms")
    #expect(formatPing(18.4, hasSamples: true) == "18 ms")
    #expect(formatLinkSpeed(1_000_000_000) == "1gbit")
    #expect(formatLinkSpeed(2_500_000_000) == "2.5gbit")
    #expect(formatLinkSpeed(100_000_000) == "100mbit")
    #expect(formatLinkSpeed(0) == nil)
    #expect(formatMbps(93.59) == "93.6 Mbps")
    #expect(formatMbps(940.2) == "940 Mbps")
    #expect(formatMbps(1234) == "1.2 Gbps")
}

@Test func titleNamesTheConnection() {
    #expect(networkTitle(.ethernet, ssid: "Home", band: .ghz5, linkSpeed: 1_000_000_000) == "Ethernet (1gbit)")
    #expect(networkTitle(.ethernet, ssid: nil, band: nil, linkSpeed: 0) == "Ethernet")
    #expect(networkTitle(.wifi(rssi: -50), ssid: "Home", band: .ghz5, linkSpeed: 0) == "Home (5ghz)")
    #expect(networkTitle(.wifi(rssi: -50), ssid: nil, band: .ghz2, linkSpeed: 0) == "Wi-Fi (2.4ghz)")
    #expect(networkTitle(.offline(wifiPower: false), ssid: nil, band: nil, linkSpeed: 0) == "Wi-Fi off")
    #expect(networkTitle(.offline(wifiPower: true), ssid: nil, band: nil, linkSpeed: 0) == "Disconnected")
}

@Test func pingHistoryAveragesAndCountsLoss() {
    var history = PingHistory()
    #expect(!history.hasSamples)
    #expect(history.lossPercent == 0)
    for ms in [10.0, nil, 20, 30, 40, 50] as [Double?] { history.append(ms) }
    // The last 5: nil, 20, 30, 40, 50.
    #expect(history.latency == 35)
    #expect(history.lossPercent == 17)
    for _ in 0..<5 { history.append(nil) }
    #expect(history.latency == nil)
    for _ in 0..<30 { history.append(1) }
    #expect(history.samples.count == PingHistory.window)
    #expect(history.lossPercent == 0)
}

@Test func ratesNeedTheSameInterfaceAndTime() {
    let first = Counters(interface: "en6", received: 1000, sent: 500, time: 10)
    #expect(Counters(interface: "en6", received: 4000, sent: 800, time: 11.5).rates(since: first)! == (2000, 200))
    #expect(Counters(interface: "en0", received: 4000, sent: 800, time: 11.5).rates(since: first) == nil)
    #expect(first.rates(since: nil) == nil)
    #expect(first.rates(since: first) == nil)
    #expect(Counters(interface: "en6", received: 10, sent: 10, time: 11).rates(since: first)! == (0, 0))
}

@Test func rowsKeepTheStrongestOfANameAndSortAsOmarchy() {
    let rows = wifiRows([
        WifiNetwork(ssid: "Cafe", rssi: -80, secure: false, known: false, connected: false),
        WifiNetwork(ssid: "Home", rssi: -70, secure: true, known: true, connected: false),
        WifiNetwork(ssid: "Home", rssi: -50, secure: true, known: true, connected: true),
        WifiNetwork(ssid: "Home", rssi: -40, secure: true, known: true, connected: false),
        WifiNetwork(ssid: "Office", rssi: -60, secure: true, known: true, connected: false),
        WifiNetwork(ssid: nil, rssi: -30, secure: true, known: false, connected: false),
        WifiNetwork(ssid: "Neighbour", rssi: -65, secure: true, known: false, connected: false),
    ])
    #expect(rows.map(\.ssid) == ["Home", "Office", nil, "Neighbour", "Cafe"])
    #expect(rows[0].rssi == -40 && rows[0].connected)
    #expect((0..<rows.count).map { wifiSection(rows, at: $0) } == ["KNOWN NETWORKS", nil, "OTHER NETWORKS", nil, nil])
    #expect(wifiSection([WifiNetwork(ssid: "A", rssi: -50, secure: true, known: false, connected: false)], at: 0)
        == "OTHER NETWORKS")
    #expect(wifiSection(rows, at: 9) == nil)
}

@Test func clicksFollowOmarchy() {
    #expect(wifiClick(WifiNetwork(ssid: "Home", rssi: -50, secure: true, known: true, connected: true)) == .disconnect)
    #expect(wifiClick(WifiNetwork(ssid: "Home", rssi: -50, secure: true, known: true, connected: false)) == .connect)
    #expect(wifiClick(WifiNetwork(ssid: "New", rssi: -50, secure: true, known: false, connected: false)) == .askPassword)
    #expect(wifiClick(WifiNetwork(ssid: "Cafe", rssi: -50, secure: false, known: false, connected: false)) == .connect)
    #expect(wifiClick(WifiNetwork(ssid: nil, rssi: -50, secure: true, known: false, connected: false)) == .none)
}

@Test func speedTestReadsProgressAndSummary() throws {
    // Lines of `networkQuality --json` on 2026-10-07; the first carries no capacity yet.
    let lines = """
        {"event_type":"progress","idle_latency_ms":39.1,"interface_name":"en6"}
        {"downlink_capacity_mbps":141.06,"downlink_flows":1,"event_type":"progress","uplink_flows":1}
        {"downlink_capacity_mbps":163.8,"downlink_responsiveness_rpm":0,"event_type":"progress","uplink_capacity_mbps":73.6}
        {"downlink_capacity_mbps":170.66,"downlink_responsiveness_rpm":892.56,"event_type":"progress","uplink_capacity_mbps":78.0}
        """.split(separator: "\n")
    var reading = SpeedTestReading()
    #expect(SpeedTestReading(line: Data(lines[0].utf8)) == nil)
    for line in lines { SpeedTestReading(line: Data(line.utf8)).map { reading.merge($0) } }
    #expect(reading == SpeedTestReading(downMbps: 170.66, upMbps: 78.0, responsiveness: 892.56))
    #expect(reading.summary == "↓ 171 Mbps  ↑ 78.0 Mbps  893 RPM")
    let summary = try #require(SpeedTestReading(line: Data(#"{"dl_throughput":93590278,"ul_throughput":182608825,"responsiveness":107.0}"#.utf8)))
    #expect(summary == SpeedTestReading(downMbps: 93.590278, upMbps: 182.608825, responsiveness: 107))
    #expect(SpeedTestReading(line: Data("not json".utf8)) == nil)
}

@Test func speedTestOutputJoinsTheSummary() {
    var output = SpeedTestOutput()
    // A progress line split across two reads, then a summary over several lines.
    #expect(output.append(Data(#"{"downlink_capacity_mbps":141.0,"event_type":"pro"#.utf8)).isEmpty)
    #expect(output.append(Data("gress\"}\n{\n  \"dl_throughput\" : 97700000,\n".utf8))
        == [SpeedTestReading(downMbps: 141.0)])
    #expect(output.append(Data("  \"responsiveness\" : 173.4,\n  \"ul_throughput\" : 183000000\n}\n".utf8))
        == [SpeedTestReading(downMbps: 97.7, upMbps: 183, responsiveness: 173.4)])
}
