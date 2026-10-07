import Foundation

/// Ends a crash loop. The LaunchAgent starts ZenithBar again whenever it exits unsuccessfully,
/// at most every 10 s, so a crash at launch left no bar and a crash report every 10 s
/// (2026-10-07). Each launch counts in `file`, and a run that lasts `healthy` clears the count;
/// the launch after `limit` quick ones in a row exits successfully, which launchd does not
/// restart (`KeepAlive`'s `SuccessfulExit`), and clears the count, so the next start, by
/// `launchctl kickstart`, at login or by `script/install.sh`, tries again (docs/overview.md,
/// install). launchd has no limit of its own on restarts.
public struct LaunchGuard: Sendable {
    public static let standard = LaunchGuard(
        file: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/ZenithBar/quick-launches"))

    public let file: URL
    public let limit: Int
    /// Seconds.
    public let healthy: TimeInterval

    public init(file: URL, limit: Int = 3, healthy: TimeInterval = 30) {
        self.file = file
        self.limit = limit
        self.healthy = healthy
    }

    /// Counts this launch; false when the last `limit` launches each ended within `healthy`,
    /// and ZenithBar should stop.
    public func launch() -> Bool {
        let quick = (try? String(contentsOf: file, encoding: .utf8)).flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        } ?? 0
        guard quick < limit else {
            clear()
            return false
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(quick + 1).write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// This run lasted `healthy`.
    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
