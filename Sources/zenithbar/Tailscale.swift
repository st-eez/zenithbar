import Foundation
import SystemConfiguration
import ZenithBarCore
import ZenithBarKit

/// Whether Tailscale's tunnel is up, from SystemConfiguration's store and its notifications on
/// the keys the network item watches, and the machines from Tailscale's CLI, read only when the
/// panel opens or asks (docs/tailscale.md). Nothing polls.
@MainActor final class Tailscale {
    /// Nil without Tailscale's VPN service, as on a Mac without the app; else whether its
    /// tunnel has an address.
    private(set) var on: Bool?
    /// The last `tailscale status --json` read.
    private(set) var status: TailscaleStatus?
    private(set) var reading = false
    /// While `tailscale up` or `down` runs.
    private(set) var switching = false
    private var store: SCDynamicStore?
    /// Called at each change, with whether the item's icon changed.
    private let changed: @MainActor (_ icon: Bool) -> Void

    /// The app's own binary, which /usr/local/bin/tailscale runs. It acts as the CLI only with
    /// TERM set: without it, as launchd starts ZenithBar, it answered "The Tailscale GUI failed
    /// to start" (2026-10-08, docs/tailscale.md).
    private static let cli = URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale")

    init(changed: @escaping @MainActor (_ icon: Bool) -> Void) {
        self.changed = changed
        watchStore()
        readStore()
    }

    /// Tailscale's service appearing, as the app installs, and its tunnel's address coming and
    /// going, as `State:/Network/Service/<id>/IPv4` does with the tunnel (docs/tailscale.md).
    private func watchStore() {
        store = SCDynamicStoreCreate(nil, "zenithbar.tailscale" as CFString, { _, _, _ in onMain { tailscaleChanged?() } }, nil)
        guard let store else { return log.error("Could not open SystemConfiguration's dynamic store for Tailscale") }
        tailscaleChanged = { [weak self] in self?.readStore() }
        SCDynamicStoreSetNotificationKeys(store, nil, [Self.interfaces, Self.addresses] as CFArray)
        CFRunLoopAddSource(CFRunLoopGetMain(), SCDynamicStoreCreateRunLoopSource(nil, store, 0), .defaultMode)
    }

    private static let interfaces = "Setup:/Network/Service/.*/Interface", addresses = "State:/Network/Service/.*/IPv4"

    /// 0.29 ms, median of 200 (docs/tailscale.md).
    func readStore() {
        guard let store else { return }
        let interfaces = SCDynamicStoreCopyMultiple(store, nil, [Self.interfaces] as CFArray) as? [String: [String: Any]] ?? [:]
        let next = tailscaleServiceID(interfaces).map {
            SCDynamicStoreCopyValue(store, "State:/Network/Service/\($0)/IPv4" as CFString) != nil
        }
        guard next != on else { return }
        log.info("Tailscale's tunnel: \(next.map { $0 ? "up" : "down" } ?? "no service", privacy: .public)")
        on = next
        changed(true)
    }

    /// Reads the machines, about 80 ms off the main thread, once at a time; `done` says whether
    /// it read them.
    func readStatus(done: (@MainActor (Bool) -> Void)? = nil) {
        guard !reading else { return }
        reading = true
        changed(false)
        run(["status", "--json"], timeout: 15, errors: false) { [weak self] code, output in
            guard let self else { return }
            self.reading = false
            let next = code == 0 ? tailscaleStatus(json: output) : nil
            if let next { self.status = next } else {
                log.error("Could not read tailscale status: exit \(code), \(String(decoding: output.prefix(300), as: UTF8.self), privacy: .public)")
            }
            self.changed(false)
            done?(next != nil)
        }
    }

    /// `tailscale up` or `down`, as Omarchy turns it on and off; the store's notification then
    /// moves the icon. `done` gets the CLI's error, nil when it worked.
    func turn(on: Bool, done: (@MainActor (String?) -> Void)? = nil) {
        guard !switching else { return }
        switching = true
        changed(false)
        run([on ? "up" : "down"], timeout: 30, errors: true) { [weak self] code, output in
            guard let self else { return }
            self.switching = false
            let error = code == 0 ? nil : Self.message(output, or: "tailscale \(on ? "up" : "down") failed")
            if let error { log.error("Could not turn Tailscale \(on ? "on" : "off"): \(error, privacy: .public)") }
            self.changed(false)
            done?(error)
        }
    }

    /// Sends `files` to `peer` with Taildrop, as Omarchy's omarchy-tailscale-send, for as long as
    /// it takes. `done` gets the CLI's error, nil when it worked.
    func send(_ files: [URL], to peer: TailscalePeer, done: @escaping @MainActor (String?) -> Void) {
        guard let ip = peer.ip else { return done("No address") }
        run(["file", "cp", "--update-interval=0", "--"] + files.map(\.path) + [ip + ":"], timeout: nil, errors: true) { code, output in
            let error = code == 0 ? nil : Self.message(output, or: "Taildrop failed")
            if let error {
                log.error("Could not send \(files.count) files to \(peer.name, privacy: .public): \(error, privacy: .public)")
            } else {
                log.notice("Sent \(files.count) files to \(peer.name, privacy: .public)")
            }
            done(error)
        }
    }

    /// The CLI's last line of output, for the panel's caption.
    private static func message(_ output: Data, or fallback: String) -> String {
        String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? fallback
    }

    /// Runs the CLI with `arguments` off the main thread, stopping it after `timeout` seconds,
    /// as the CLI can hang on a network coming and going (Omarchy's `pollWatchdog`), and hands
    /// back its exit status and output, with its errors when `errors` is set.
    private func run(_ arguments: [String], timeout: TimeInterval?, errors: Bool,
                     done: @escaping @MainActor (Int32, Data) -> Void) {
        let process = Process()
        process.executableURL = Self.cli
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["TERM": "dumb"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errors ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            log.error("Could not run Tailscale's CLI: \(error.localizedDescription, privacy: .public)")
            return done(-1, Data(error.localizedDescription.utf8))
        }
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
        }
        let output = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            let data = output.readDataToEndOfFile()
            process.waitUntilExit()
            let code = process.terminationStatus
            onMain { done(code, data) }
        }
    }
}

/// The store's callback, a C function, reaches the one Tailscale through this.
@MainActor private var tailscaleChanged: (@MainActor () -> Void)?
