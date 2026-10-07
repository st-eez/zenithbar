import Foundation
import Testing
import ZenithBarKit

/// Three quick launches run, the fourth stops and clears the count so the next start runs, and a
/// healthy run clears it too.
@Test func stopsAfterThreeQuickLaunches() {
    let folder = FileManager.default.temporaryDirectory.appending(path: "zenithbar-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let launches = LaunchGuard(file: folder.appending(path: "quick-launches"))
    #expect([launches.launch(), launches.launch(), launches.launch()] == [true, true, true])
    #expect(!launches.launch())
    #expect(launches.launch())
    launches.clear()
    #expect([launches.launch(), launches.launch(), launches.launch()] == [true, true, true])
    #expect(!launches.launch())
}
