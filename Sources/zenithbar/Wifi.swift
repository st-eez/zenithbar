import Foundation
@preconcurrency import CoreLocation
@preconcurrency import CoreWLAN
import ZenithBarCore
import ZenithBarKit

/// What the network panel asks of the Wi-Fi: scans, joins, leaves, forgets and power, each on
/// a queue of its own, as a scan took 6.9 s and a join blocks until it ends
/// (docs/network.md, the panel).
@MainActor final class Wifi {
    private let client: CWWiFiClient
    private let queue = DispatchQueue(label: "io.github.st-eez.zenithbar.wifi")
    private let locator = Locator()

    init(client: CWWiFiClient) { self.client = client }

    var interface: CWInterface? { client.interface() }

    /// Nil while Location Services withholds it (docs/network.md, the network's name).
    var ssid: String? { interface?.ssid() }

    var band: WifiBand? {
        switch interface?.wlanChannel()?.channelBand {
        case .band2GHz?: .ghz2
        case .band5GHz?: .ghz5
        case .band6GHz?: .ghz6
        default: nil
        }
    }

    /// The networks this Mac joins on its own, whose names CoreWLAN gives without Location
    /// Services.
    var known: Set<String> {
        Set((interface?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap(\.ssid))
    }

    var namesAllowed: Bool { locator.allowed }
    /// Whether macOS will still ask Steve, as it asks once.
    var namesUndecided: Bool { locator.undecided }

    /// Asks Location Services for the networks' names; `changed` is called when the answer changes.
    func askForNames(changed: @escaping @MainActor () -> Void) {
        locator.changed = changed
        locator.request()
    }

    func watchNames(changed: @escaping @MainActor () -> Void) { locator.changed = changed }

    /// The last scan's results, which airportd keeps, at once.
    var cached: [CWNetwork] { Array(interface?.cachedScanResults() ?? []) }

    func scan(done: @escaping @MainActor ([CWNetwork]?) -> Void) {
        let interface = self.interface
        queue.async {
            let found: Set<CWNetwork>?
            do { found = try interface?.scanForNetworks(withSSID: nil) } catch {
                log.error("Wi-Fi scan failed: \(error, privacy: .public)")
                found = nil
            }
            let networks = found.map(Array.init)
            onMain { done(networks) }
        }
    }

    /// Joins `network`, with no password for an open network or one the Mac knows, which
    /// airportd joins from its own keychain item. Untested: Steve's Mac was in use
    /// (docs/network.md, untested).
    func connect(_ network: CWNetwork, password: String?, done: @escaping @MainActor (String?) -> Void) {
        run(done) { interface in try interface.associate(to: network, password: password) }
    }

    /// Leaves the joined network, as the native menu's Disconnect does. Untested.
    func disconnect(done: @escaping @MainActor (String?) -> Void) {
        run(done) { interface in interface.disassociate() }
    }

    func setPower(_ on: Bool, done: @escaping @MainActor (String?) -> Void) {
        run(done) { interface in try interface.setPower(on) }
    }

    /// Forgets `ssid` through networksetup, which an admin user runs without a prompt when
    /// System Settings asks no password for system preferences; it answered for a name it did
    /// not know in 92 ms without one. Removing a known network is untested (docs/network.md).
    func forget(_ ssid: String, done: @escaping @MainActor (String?) -> Void) {
        let name = interface?.interfaceName ?? "en0"
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            process.arguments = ["-removepreferredwirelessnetwork", name, ssid]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var failure: String?
            do {
                try process.run()
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus != 0 || !output.contains("Removed") {
                    failure = output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch { failure = "\(error)" }
            if let failure { log.error("Could not forget \(ssid, privacy: .public): \(failure, privacy: .public)") }
            onMain { done(failure == nil ? nil : "Failed") }
        }
    }

    /// Runs `work` on the queue and reports its error, nil when it worked.
    private func run(_ done: @escaping @MainActor (String?) -> Void,
                     _ work: @escaping @Sendable (CWInterface) throws -> Void) {
        guard let interface else { return done("No Wi-Fi") }
        queue.async {
            var failure: String?
            do { try work(interface) } catch {
                log.error("Wi-Fi action failed: \(error, privacy: .public)")
                failure = switch (error as NSError).code {
                // Challenge failure, invalid PMK and the supplicant's timeout, as a wrong passphrase ends.
                case -3912, -3924, -3925: "Wrong password"
                case -3930: "Not permitted"
                default: "Failed"
                }
            }
            onMain { done(failure) }
        }
    }
}

/// Logs Location Services' answer at launch, 3 when allowed and 0 when nobody was asked, so the
/// log shows whether the grant survived `script/install.sh` replacing the app (docs/network.md,
/// the network's name). From the delegate's first call, as a new manager's status read at once
/// was 0 before locationd had verified the app. Asking for it prompts nothing.
@MainActor final class LocationLog: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    /// On the run loop of the thread that made the manager, the main one; it touches no
    /// main-actor state.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        log.notice("Location Services authorization: \(manager.authorizationStatus.rawValue)")
    }
}

/// Location Services' answer for ZenithBar, which airportd asks before it gives networks'
/// names (docs/network.md, the network's name).
@MainActor private final class Locator: NSObject, CLLocationManagerDelegate {
    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    var changed: (@MainActor () -> Void)?

    var allowed: Bool { [.authorizedAlways, .authorized].contains(manager.authorizationStatus) }
    var undecided: Bool { manager.authorizationStatus == .notDetermined }

    func request() {
        log.info("Asking Location Services for Wi-Fi names, status \(self.manager.authorizationStatus.rawValue)")
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        log.info("Location Services status \(manager.authorizationStatus.rawValue)")
        onMain { self.changed?() }
    }
}
