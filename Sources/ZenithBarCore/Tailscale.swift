import Foundation

// What the Tailscale item and panel show, after Omarchy 4's Tailscale panel
// (`shell/plugins/panels/tailscale/Model.js`) (docs/tailscale.md): whether Tailscale's tunnel is
// up, from SystemConfiguration's store, and the machines, from `tailscale status --json`.

/// The ID of Tailscale's VPN service among the store's `Setup:/Network/Service/<id>/Interface`
/// values, by its subtype: `io.tailscale.ipn.macsys` for the standalone app, as on Steve's Mac,
/// and, unconfirmed, `io.tailscale.ipn.macos` for the App Store's. Nil without the app.
public func tailscaleServiceID(_ interfaces: [String: [String: Any]]) -> String? {
    interfaces.first { ($0.value["SubType"] as? String)?.hasPrefix("io.tailscale.ipn") == true }
        .map { $0.key.split(separator: "/")[3].description }
}

/// A machine on the tailnet, as the panel lists it.
public struct TailscalePeer: Equatable, Sendable {
    public var name: String
    /// Without the trailing dot, as "devbox-vm.tail1a2b3c.ts.net".
    public var dnsName: String
    /// Its first IPv4 address, in 100.64.0.0/10.
    public var ip: String?
    /// As Tailscale names it: "macOS", "iOS", "linux", "windows", "android".
    public var os: String
    public var online: Bool
    /// Whether Taildrop can send it files now.
    public var taildrop: Bool

    public init(name: String, dnsName: String = "", ip: String? = nil, os: String = "", online: Bool = true,
                taildrop: Bool = false) {
        (self.name, self.dnsName, self.ip, self.os, self.online, self.taildrop) = (name, dnsName, ip, os, online, taildrop)
    }
}

public struct TailscaleStatus: Equatable, Sendable {
    /// Tailscale's `BackendState`: "Running", "Stopped", "NeedsLogin" and the like.
    public var backendState: String
    /// This Mac's name, as "Steve’s MacBook Pro".
    public var name: String
    /// By name.
    public var peers: [TailscalePeer]

    public init(backendState: String = "Running", name: String = "", peers: [TailscalePeer] = []) {
        (self.backendState, self.name, self.peers) = (backendState, name, peers)
    }

    public var running: Bool { backendState == "Running" }
    public var online: [TailscalePeer] { peers.filter(\.online) }
    public var offline: [TailscalePeer] { peers.filter { !$0.online } }
}

/// `tailscale status --json` as the panel shows it, or nil when it is unreadable.
public func tailscaleStatus(json: Data) -> TailscaleStatus? {
    guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
          let backendState = root["BackendState"] as? String else { return nil }
    let me = root["Self"] as? [String: Any] ?? [:]
    // Taildrop is a tailnet feature its admin can turn off, which this Mac's capabilities show.
    let capability = "https://tailscale.com/cap/file-sharing"
    let sharing = (me["Capabilities"] as? [String] ?? []).contains(capability)
        || (me["CapMap"] as? [String: Any])?[capability] != nil
    let owner = me["UserID"] as? Int
    let peers = (root["Peer"] as? [String: [String: Any]] ?? [:]).values.map { peer in
        let online = peer["Online"] as? Bool == true
        // Tailscale grades each peer itself, 1 being available, as Omarchy's `isTaildropTarget`
        // reads it; a daemon too old to say leaves 0, and then the same owner is.
        let target = peer["TaildropTarget"] as? Int ?? 0
        let sendable = target == 0 ? owner != nil && peer["UserID"] as? Int == owner : target == 1
        return TailscalePeer(name: tailscaleName(host: peer["HostName"] as? String, dns: peer["DNSName"] as? String),
                             dnsName: trimmedDNS(peer["DNSName"] as? String),
                             ip: (peer["TailscaleIPs"] as? [String])?.first { $0.contains(".") },
                             os: peer["OS"] as? String ?? "", online: online, taildrop: sharing && online && sendable)
    }
    return TailscaleStatus(backendState: backendState,
                           name: tailscaleName(host: me["HostName"] as? String, dns: me["DNSName"] as? String),
                           peers: peers.sorted { a, b in
                               let order = a.name.localizedStandardCompare(b.name)
                               return order == .orderedSame ? a.dnsName < b.dnsName : order == .orderedAscending
                           })
}

private func trimmedDNS(_ name: String?) -> String {
    let name = name ?? ""
    return name.hasSuffix(".") ? String(name.dropLast()) : name
}

/// A machine's name: its host name, or the first label of its DNS name when the host name is
/// "localhost", as an iPhone gives, which hides its own, or empty.
public func tailscaleName(host: String?, dns: String?) -> String {
    if let host, !host.isEmpty, host.lowercased() != "localhost" { return host }
    let label = trimmedDNS(dns).split(separator: ".").first.map(String.init) ?? ""
    return label.isEmpty ? host ?? "" : label
}

/// A machine's OS as the panel shows it: Material's logo in Nerd Fonts, Omarchy's `osIcon`,
/// and its name.
public func tailscaleOS(_ os: String) -> (glyph: String, name: String) {
    switch os.lowercased() {
    case "linux": ("\u{F033D}", "Linux")
    case "macos": ("\u{F0035}", "macOS")
    case "ios": ("\u{F0035}", "iOS")
    case "windows": ("\u{F0372}", "Windows")
    case "android": ("\u{F0032}", "Android")
    default: ("\u{F07C0}", os.isEmpty ? "Unknown" : os.prefix(1).uppercased() + os.dropFirst())
    }
}

/// Omarchy's captions under this Mac's name while Tailscale is on, one every 2.8 s.
public let tailscalePhrases = ["Encrypting connections", "Sending secrets", "Guarding wires", "Braiding packets",
                               "Polishing tunnels", "Hiding routes", "Sealing ports", "Sorting tailnets",
                               "Shuffling keys", "Watching machines"]
