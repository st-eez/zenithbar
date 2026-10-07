import Foundation

/// Runs `body` on the main actor: at once on the main thread, and on the main queue's next turn
/// from any other. Every callback macOS makes enters the main actor through this, from a
/// nonisolated entry, a `@Sendable` closure or a `nonisolated` method, whatever thread it was
/// given or picks: IOBluetooth called a main-actor method on CoreBluetooth's queue, and the
/// isolation check trapped at every launch (docs/overview.md, threads).
public func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}
