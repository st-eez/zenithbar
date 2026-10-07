import Foundation
import ZenithCore

/// Runs each plugin every `interval` seconds and when an event asks, and hands each item it
/// prints to `received` on the main actor (docs/plugins.md). A plugin that runs past 2 minutes
/// is stopped; a run that is asked for while one goes is dropped, as that run will report.
@MainActor public final class Plugins {
    private let received: @MainActor (PluginItem) -> Void
    private var plugins: [Config.Plugin] = []
    private var timers: [Timer] = []
    /// Each plugin is known by its command, so a change to config.json leaves runs going on
    /// and items printed in the plugin's hands.
    private var running: [[String]: Process] = [:]
    /// Which plugin printed each item, so a click on the item reaches its plugin.
    private var owners: [String: [String]] = [:]

    public init(received: @escaping @MainActor (PluginItem) -> Void) {
        self.received = received
    }

    /// Runs `plugins` now and on their intervals, in place of any before. Items of a plugin no
    /// longer listed lose their owner, and what its run prints after is dropped.
    public func configure(_ plugins: [Config.Plugin]) {
        guard plugins != self.plugins else { return }
        self.plugins = plugins
        for timer in timers { timer.invalidate() }
        owners = owners.filter { listed($0.value) }
        timers = plugins.map { plugin in
            let timer = Timer(timeInterval: plugin.interval, repeats: true) { _ in
                MainActor.assumeIsolated { self.run(plugin.command, event: "interval") }
            }
            timer.tolerance = plugin.interval / 10
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
        for plugin in plugins { run(plugin.command, event: "launch") }
    }

    /// Whether a plugin in the list printed `item`.
    public func owns(_ item: String) -> Bool { owners[item] != nil }

    private func listed(_ command: [String]) -> Bool { plugins.contains { $0.command == command } }

    /// Runs every plugin early, as after a wake, when what they show may have moved on.
    public func runAll(event: String) {
        for plugin in plugins { run(plugin.command, event: event) }
    }

    /// Runs the plugin that shows `item`, telling it why in `ZENITH_EVENT`.
    public func run(item: String, event: String) {
        if let command = owners[item] { run(command, event: event) }
    }

    private func run(_ command: [String], event: String) {
        guard running[command] == nil, let program = command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: (program as NSString).expandingTildeInPath)
        process.arguments = Array(command.dropFirst())
        process.environment = ProcessInfo.processInfo.environment.merging(["ZENITH_EVENT": event]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        let lines = LineReader { [weak self] line in
            guard let item = PluginItem.decode(line) else {
                return log.error("A plugin printed a line that is not an item: \(String(decoding: line.prefix(200), as: UTF8.self), privacy: .public)")
            }
            // In order, as a plugin may print a cached item before a fresh one.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.listed(command) else { return }
                    self.owners[item.item] = command
                    self.received(item)
                }
            }
        }
        // Read to the pipe's end, which comes when the plugin and any child it left holding its
        // standard output have exited. The handler holds the pipe open until then.
        output.fileHandleForReading.readabilityHandler = { _ in
            let data = output.fileHandleForReading.availableData
            guard data.isEmpty else { return lines.feed(data) }
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            lines.finish()
        }
        // The run ends when the plugin exits, so a child still writing, as `cmd &` or ssh, holds
        // back no later run.
        process.terminationHandler = { [weak self] process in
            if process.terminationStatus != 0 {
                log.notice("Plugin \(program, privacy: .public) exited with \(process.terminationStatus)")
            }
            Task { @MainActor in self?.running[command] = nil }
        }
        do {
            try process.run()
        } catch {
            // Otherwise the pipe's ends stay open, 3 fds a failed launch.
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            return log.error("Could not run plugin \(program, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        running[command] = process
        // Reaches the plugin alone, not its children (docs/plugins.md, ceiling).
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }
}

/// Splits a plugin's output into lines as it arrives, on the pipe's own thread.
private final class LineReader: @unchecked Sendable {
    private let line: @Sendable (Data) -> Void
    private var buffer = Data()
    private let lock = NSLock()

    init(line: @escaping @Sendable (Data) -> Void) { self.line = line }

    func feed(_ data: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(buffer[buffer.startIndex..<end])
                buffer.removeSubrange(buffer.startIndex...end)
            }
            return lines
        }
        for next in lines where !next.isEmpty { line(Data(next)) }
    }

    /// Hands on a last line that ended without a newline.
    func finish() {
        let rest = lock.withLock { defer { buffer = Data() }; return buffer }
        if !rest.isEmpty { line(rest) }
    }
}
