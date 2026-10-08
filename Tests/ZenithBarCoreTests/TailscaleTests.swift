import Foundation
import Testing
@testable import ZenithBarCore

// `tailscale status --json` on Steve's Mac on 2026-10-08 (docs/tailscale.md), cut to the fields
// read: the iPhone, which hides its host name as "localhost", Linux machines online, the Windows
// PC offline, and a machine of another owner from a daemon too old to grade Taildrop.
private let status = Data("""
    {"BackendState": "Running",
     "Self": {"HostName": "Steve’s MacBook Pro", "DNSName": "steves-macbook-pro.tail1a2b3c.ts.net.", "OS": "macOS",
       "UserID": 6011223344556677, "Capabilities": ["https://tailscale.com/cap/file-sharing", "https"]},
     "Peer": {
       "a": {"HostName": "localhost", "DNSName": "iphone.tail1a2b3c.ts.net.", "OS": "iOS",
         "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"], "Online": true, "TaildropTarget": 1,
         "UserID": 6011223344556677},
       "b": {"HostName": "desktop", "DNSName": "desktop-pc.tail1a2b3c.ts.net.", "OS": "windows",
         "TailscaleIPs": ["fd7a:115c:a1e0::3", "100.64.0.3"], "Online": false, "TaildropTarget": 5,
         "UserID": 6011223344556677},
       "c": {"HostName": "devbox", "DNSName": "devbox-vm.tail1a2b3c.ts.net.", "OS": "linux",
         "TailscaleIPs": ["100.64.0.4"], "Online": true, "TaildropTarget": 1, "UserID": 6011223344556677},
       "d": {"HostName": "guest", "DNSName": "guest.tail1a2b3c.ts.net.", "OS": "linux",
         "TailscaleIPs": ["100.64.0.9"], "Online": true, "UserID": 1}}}
    """.utf8)

@Test func readsTheMachinesFromTailscaleStatus() throws {
    let read = try #require(tailscaleStatus(json: status))
    #expect(read.running)
    #expect(read.name == "Steve’s MacBook Pro")
    #expect(read.online.map(\.name) == ["devbox", "guest", "iphone"])
    #expect(read.offline.map(\.name) == ["desktop"])
    #expect(read.online[0] == TailscalePeer(name: "devbox", dnsName: "devbox-vm.tail1a2b3c.ts.net", ip: "100.64.0.4",
                                            os: "linux", online: true, taildrop: true))
    // Its IPv4 address, wherever it is listed.
    #expect(read.offline[0].ip == "100.64.0.3")
    // Taildrop: an offline machine and another owner's take no files.
    #expect(read.offline[0].taildrop == false)
    #expect(read.online[1].taildrop == false)
    #expect(tailscaleStatus(json: Data("nope".utf8)) == nil)
}

@Test func sendsNothingWithoutTheFileSharingCapability() throws {
    let text = String(decoding: status, as: UTF8.self).replacingOccurrences(of: "\"https://tailscale.com/cap/file-sharing\", ", with: "")
    let read = try #require(tailscaleStatus(json: Data(text.utf8)))
    #expect(read.online.allSatisfy { !$0.taildrop })
}

@Test func namesAMachineThatHidesItsHostName() {
    #expect(tailscaleName(host: "localhost", dns: "iphone.tail1a2b3c.ts.net.") == "iphone")
    #expect(tailscaleName(host: "LocalHost", dns: "ipad.tail1a2b3c.ts.net") == "ipad")
    #expect(tailscaleName(host: "media-pc", dns: "media-pc.tail1a2b3c.ts.net.") == "media-pc")
    #expect(tailscaleName(host: "", dns: nil) == "")
}

@Test func findsTailscalesServiceByItsSubtype() {
    let interfaces: [String: [String: Any]] = [
        "Setup:/Network/Service/7B1E5D20-8C3A-4F6B-B1D2-6A7C8E9F0A13/Interface": ["SubType": "ch.protonvpn.mac", "Type": "VPN"],
        "Setup:/Network/Service/3F2A1C9E-4B7D-4E21-9A6C-1D2E3F405162/Interface": ["SubType": "io.tailscale.ipn.macsys", "Type": "VPN"],
        "Setup:/Network/Service/5E4D3C2B-1A09-4F8E-8D7C-6B5A49382716/Interface": ["DeviceName": "en6", "Type": "Ethernet"],
    ]
    #expect(tailscaleServiceID(interfaces) == "3F2A1C9E-4B7D-4E21-9A6C-1D2E3F405162")
    #expect(tailscaleServiceID([:]) == nil)
}

@Test func showsEachOS() {
    #expect(tailscaleOS("iOS").name == "iOS")
    #expect(tailscaleOS("linux") == ("\u{F033D}", "Linux"))
    #expect(tailscaleOS("freebsd").name == "Freebsd")
}
