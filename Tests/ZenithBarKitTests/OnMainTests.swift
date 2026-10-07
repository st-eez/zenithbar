import Foundation
import Testing
import ZenithBarKit

/// On the main thread `onMain` runs its body before it returns, as a callback on the main run
/// loop expects; from another thread it runs it on the main thread.
@MainActor @Test func entersTheMainActorFromAnyThread() async {
    final class Ran: @unchecked Sendable { var value = false }
    let ran = Ran()
    onMain { ran.value = true }
    #expect(ran.value)
    let onMainThread = await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            onMain { continuation.resume(returning: Thread.isMainThread) }
        }
    }
    #expect(onMainThread)
}
