import Foundation
import ZenithCore

/// Runs each plugin every `interval` seconds and when an event asks, and hands each item it
/// prints to `received` on the main actor (docs/plugins.md). A plugin that runs past 2 minutes
/// is stopped; a run that is asked for while one goes is dropped, as that run will report.
@MainActor final class Plugins {
    private let received: @MainActor (PluginItem) -> Void
    private var plugins: [Config.Plugin] = []
    private var timers: [Timer] = []
    private var running: [Int: Process] = [:]
    /// Which plugin printed each item, so a click on the item reaches its plugin.
    private var owners: [String: Int] = [:]

    init(received: @escaping @MainActor (PluginItem) -> Void) {
        self.received = received
    }

    /// Runs `plugins` now and on their intervals, in place of any before.
    func configure(_ plugins: [Config.Plugin]) {
        guard plugins != self.plugins else { return }
        self.plugins = plugins
        for timer in timers { timer.invalidate() }
        owners = [:]
        timers = plugins.indices.map { index in
            let timer = Timer(timeInterval: plugins[index].interval, repeats: true) { _ in
                MainActor.assumeIsolated { self.run(index, event: "interval") }
            }
            timer.tolerance = plugins[index].interval / 10
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
        for index in plugins.indices { run(index, event: "launch") }
    }

    /// Runs every plugin early, as after a wake, when what they show may have moved on.
    func runAll(event: String) {
        for index in plugins.indices { run(index, event: event) }
    }

    /// Runs the plugin that shows `item`, telling it why in `ZENITH_EVENT`.
    func run(item: String, event: String) {
        if let index = owners[item] { run(index, event: event) }
    }

    private func run(_ index: Int, event: String) {
        guard running[index] == nil, index < plugins.count, let program = plugins[index].command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: (program as NSString).expandingTildeInPath)
        process.arguments = Array(plugins[index].command.dropFirst())
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
                    self?.owners[item.item] = index
                    self?.received(item)
                }
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in lines.feed(handle.availableData) }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            lines.feed(output.fileHandleForReading.readDataToEndOfFile())
            lines.finish()
            if process.terminationStatus != 0 {
                log.notice("Plugin \(program, privacy: .public) exited with \(process.terminationStatus)")
            }
            Task { @MainActor in self?.running[index] = nil }
        }
        do {
            try process.run()
        } catch {
            return log.error("Could not run plugin \(program, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        running[index] = process
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
