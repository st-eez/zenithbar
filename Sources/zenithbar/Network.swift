import Foundation
@preconcurrency import CoreWLAN
import SystemConfiguration
import ZenithBarCore
import ZenithBarKit

/// The interface macOS routes traffic through, from SystemConfiguration's dynamic store and
/// its notifications, and the Wi-Fi's power and signal from CoreWLAN's power, link and link
/// quality events, with no polling (docs/network.md).
@MainActor final class Network {
    private(set) var route = Route.offline(wifiPower: nil)
    private var services: [NetworkService] = []
    private(set) var primary: NetworkService?
    /// Nil on a Mac without Wi-Fi.
    private(set) var wifiPower: Bool?
    /// 0 off a network, as CoreWLAN gives it.
    private(set) var rssi = 0
    let client = CWWiFiClient.shared()
    private lazy var events = WifiEvents { [weak self] event in onMain { self?.received(event) } }
    private var store: SCDynamicStore?
    /// Called at each change, with whether the item's icon or color changed.
    private let changed: @MainActor (_ glyph: Bool) -> Void

    init(changed: @escaping @MainActor (_ glyph: Bool) -> Void) {
        self.changed = changed
        client.delegate = events
        watchStore()
        monitorWifi()
        read()
    }

    /// The primary interface and every service's address, notified on change.
    private func watchStore() {
        store = SCDynamicStoreCreate(nil, "zenithbar" as CFString, { _, _, _ in onMain { networkChanged?() } }, nil)
        guard let store else { return log.error("Could not open SystemConfiguration's dynamic store") }
        networkChanged = { [weak self] in self?.read() }
        SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/IPv4"] as CFArray,
                                          ["State:/Network/Service/.*/IPv4"] as CFArray)
        CFRunLoopAddSource(CFRunLoopGetMain(), SCDynamicStoreCreateRunLoopSource(nil, store, 0), .defaultMode)
    }

    private func monitorWifi() {
        for event in [CWEventType.powerDidChange, .linkDidChange, .linkQualityDidChange] {
            do { try client.startMonitoringEvent(with: event) } catch {
                log.error("Could not monitor Wi-Fi event \(event.rawValue): \(error, privacy: .public)")
            }
        }
    }

    /// Reads everything again, as after a wake.
    func read() {
        readWifi()
        readStore()
        update()
    }

    private func readWifi() {
        let interface = client.interface()
        wifiPower = interface?.powerOn()
        rssi = interface?.rssiValue() ?? 0
    }

    private func readStore() {
        guard let store else { return }
        let kinds = Self.kinds()
        let found = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/IPv4"] as CFArray)
            as? [String: [String: Any]] ?? [:]
        services = found.compactMap { key, value in
            guard let interface = value["InterfaceName"] as? String else { return nil }
            // State:/Network/Service/<id>/IPv4
            return NetworkService(id: key.split(separator: "/")[3].description, interface: interface,
                                  kind: kinds[interface] ?? .other, address: (value["Addresses"] as? [String])?.first,
                                  router: value["Router"] as? String)
        }.sorted { $0.interface < $1.interface }
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let order = (SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any])?[
            "ServiceOrder"] as? [String] ?? []
        primary = primaryService(services, primaryInterface: global?["PrimaryInterface"] as? String, order: order)
    }

    /// Each hardware interface's kind by its BSD name. 2 ms, so read only when the store
    /// changes, which it did not in 180 s of steady Wi-Fi (docs/network.md).
    private static func kinds() -> [String: NetworkService.Kind] {
        var kinds: [String: NetworkService.Kind] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) else { continue }
            if type == kSCNetworkInterfaceTypeIEEE80211 { kinds[name] = .wifi }
            if type == kSCNetworkInterfaceTypeEthernet { kinds[name] = .ethernet }
        }
        return kinds
    }

    private func received(_ event: WifiEvents.Event) {
        switch event {
        // A link quality event's own RSSI read 6 to 7 dB above rssiValue() at the same moment,
        // so the item reads rssiValue() each time to keep one scale (docs/network.md).
        case .changed: readWifi()
        case .interrupted:
            log.error("CoreWLAN's connection to airportd was interrupted; monitoring Wi-Fi again")
            monitorWifi()
            readWifi()
        }
        update()
    }

    private func update() {
        let next = Route(primary: primary, wifiRSSI: rssi, wifiPower: wifiPower)
        let before = networkIcon(route), after = networkIcon(next)
        route = next
        changed(before.icon != after.icon || before.dim != after.dim)
    }
}

/// The store's callback, a C function, reaches the one Network through this.
@MainActor private var networkChanged: (@MainActor () -> Void)?

/// CoreWLAN's delegate, which it calls on a queue of its own.
private final class WifiEvents: NSObject, CWEventDelegate, Sendable {
    enum Event: Sendable {
        /// Power, link or link quality.
        case changed
        case interrupted
    }

    private let received: @Sendable (Event) -> Void

    init(_ received: @escaping @Sendable (Event) -> Void) { self.received = received }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { received(.changed) }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { received(.changed) }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        received(.changed)
    }
    func clientConnectionInterrupted() { received(.interrupted) }
}
