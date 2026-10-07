/// A network service with an IPv4 address, from SystemConfiguration's dynamic store.
public struct NetworkService: Equatable, Sendable {
    public enum Kind: Sendable {
        case wifi, ethernet
        /// A VPN's tunnel, a bridge, or anything else without hardware of its own.
        case other
    }

    /// The service's ID, as in the store's keys and its service order.
    public var id: String
    /// The BSD name, as en0.
    public var interface: String
    public var kind: Kind
    public var address: String?
    public var router: String?

    public init(id: String, interface: String, kind: Kind, address: String?, router: String?) {
        (self.id, self.interface, self.kind, self.address, self.router) = (id, interface, kind, address, router)
    }
}

/// The service macOS routes traffic through: the one on the store's primary interface, or,
/// when that is a VPN's tunnel, the first service in `order`, the user's service order, on
/// hardware with a router, as the tunnel's own traffic leaves through it. Nil with no
/// primary interface, when nothing routes. Tailscale without an exit node left en0 primary
/// (docs/network.md).
public func primaryService(_ services: [NetworkService], primaryInterface: String?, order: [String]) -> NetworkService? {
    guard let primaryInterface else { return nil }
    if let service = services.first(where: { $0.interface == primaryInterface && $0.kind != .other }) { return service }
    return services.filter { $0.kind != .other && $0.router != nil }
        .min { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
}

/// What the network item shows.
public enum Route: Equatable, Sendable {
    case wifi(rssi: Int)
    case ethernet
    /// Nothing routes. `wifiPower` is nil on a Mac without Wi-Fi.
    case offline(wifiPower: Bool?)

    public init(primary: NetworkService?, wifiRSSI: Int, wifiPower: Bool?) {
        switch primary?.kind {
        case .wifi: self = .wifi(rssi: wifiRSSI)
        case .ethernet, .other: self = .ethernet
        case nil: self = .offline(wifiPower: wifiPower)
        }
    }
}

/// A signal level from 0 to 4 for an RSSI in dBm, in Android's steps for five levels
/// (`WifiManager.calculateSignalLevel`): 0 below -88 dBm, 4 from -55 dBm.
public func wifiLevel(rssi: Int) -> Int {
    min(4, max(0, (rssi + 100) * 4 / 45))
}

/// What the network item draws: an SF Symbol, filled to `value` from 0 to 1 when it has one,
/// or a Material Design glyph from Nerd Fonts, as SF Symbols has no Ethernet port.
public enum NetworkIcon: Equatable, Sendable {
    case symbol(String, value: Double?)
    case glyph(String)
}

/// The item's icon and whether it shows dim. Wi-Fi as the native menu bar draws it, its arcs
/// filled by level.
public func networkIcon(_ route: Route) -> (icon: NetworkIcon, dim: Bool) {
    switch route {
    case let .wifi(rssi): (.symbol("wifi", value: Double(wifiLevel(rssi: rssi)) / 4), false)
    case .ethernet: (.glyph("\u{F0200}"), false) // ethernet, Omarchy 4's
    case .offline(wifiPower: false): (.symbol("wifi.slash", value: nil), true)
    case .offline(wifiPower: true): (.symbol("wifi.exclamationmark", value: nil), true)
    case .offline(wifiPower: nil): (.symbol("network.slash", value: nil), true)
    }
}
