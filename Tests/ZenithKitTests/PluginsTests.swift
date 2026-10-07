import Foundation
import Testing
@testable import ZenithCore
import ZenithKit

/// Real `/bin/sh` plugins, one at a time, as the open fd count is the process's.
@MainActor @Suite(.serialized) struct PluginsTests {
    /// The items a `Plugins` hands on, in order.
    final class Received {
        var items: [PluginItem] = []
        func has(_ item: String, icon: String? = nil) -> Bool {
            items.contains { $0.item == item && (icon == nil || $0.icon == icon) }
        }
    }

    /// A plugin running `script` in `sh`, which prints items whose icon is `$ZENITH_EVENT`
    /// with `item NAME`. `$1` is `arg`.
    static func plugin(_ script: String, arg: String = "") -> Config.Plugin {
        let item = #"item() { printf '{"item":"%s","icon":"%s"}\n' "$1" "$ZENITH_EVENT"; }; "#
        return Config.Plugin(command: ["/bin/sh", "-c", item + script, "sh", arg], interval: 3600)
    }

    /// Waits up to `seconds` for `condition`, letting the main queue deliver items meanwhile.
    static func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date() + seconds
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    static func openFDs() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }

    @Test func failedLaunchesLeakNoFDs() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appending(path: "plain")
        try Data("echo hi\n".utf8).write(to: plain)
        let plugins = Plugins { _ in }
        // Once first, so what Foundation opens once and keeps is in the count before.
        plugins.configure([Config.Plugin(command: [folder.appending(path: "missing").path], interval: 3600),
                           Config.Plugin(command: [plain.path], interval: 3600)])
        let before = try Self.openFDs()
        for _ in 0..<100 { plugins.runAll(event: "refresh") }
        let after = try Self.openFDs()
        plugins.configure([])
        // A leak was 3 fds a launch, 600 here.
        #expect(after <= before)
    }

    @Test func childHoldingOutputHoldsBackNoRun() async throws {
        let received = Received()
        let plugins = Plugins { received.items.append($0) }
        defer { plugins.configure([]) }
        plugins.configure([Self.plugin("item held; (sleep 2; item child) &")])
        #expect(await Self.eventually { received.has("held", icon: "launch") })
        let start = Date()
        // The launch run ended at the plugin's exit, so a refresh starts while its child sleeps.
        let refreshed = await Self.eventually(within: 1.5) {
            plugins.runAll(event: "refresh")
            return received.has("held", icon: "refresh")
        }
        #expect(refreshed)
        #expect(Date().timeIntervalSince(start) < 1.5)
        #expect(!received.has("child"))
        // What the child prints after the plugin exits still arrives.
        #expect(await Self.eventually { received.has("child", icon: "launch") })
        #expect(await Self.eventually { received.has("child", icon: "refresh") })
    }

    @Test func linesArriveWholeAndInOrder() async throws {
        let received = Received()
        let plugins = Plugins { received.items.append($0) }
        defer { plugins.configure([]) }
        // A line split across two reads, then a last line without a newline.
        plugins.configure([Self.plugin(#"printf '{"item":"split",'; sleep 0.3; printf '"icon":"1"}\n{"item":"last","icon":"2"}'"#)])
        #expect(await Self.eventually { received.items.count == 2 })
        #expect(received.items.map(\.item) == ["split", "last"])
        #expect(received.items.map(\.icon) == ["1", "2"])
    }

    @Test func configChangeKeepsRunsAndOwners() async throws {
        let runs = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: runs) }
        let received = Received()
        let plugins = Plugins { received.items.append($0) }
        defer { plugins.configure([]) }
        let a = Self.plugin(#"echo run >> "$1"; item a1; sleep 0.5; item a2"#, arg: runs.path)
        let b = Self.plugin("item b")
        plugins.configure([a])
        #expect(await Self.eventually { received.has("a1") })
        // While A's launch run sleeps, B goes in before it.
        plugins.configure([b, a])
        #expect(await Self.eventually { received.has("b", icon: "launch") })
        #expect(await Self.eventually { received.has("a2", icon: "launch") })
        #expect(try String(contentsOf: runs, encoding: .utf8) == "run\n")
        #expect(plugins.owns("a2") && plugins.owns("b"))
        // A click on A's item runs A, once its launch run has ended.
        #expect(await Self.eventually {
            plugins.run(item: "a2", event: "refresh")
            return received.has("a1", icon: "refresh")
        })
        #expect(!received.has("b", icon: "refresh"))
        // A taken out while its refresh run sleeps: its items are gone, B's stay, and what the
        // run prints after is dropped.
        plugins.configure([b])
        #expect(!plugins.owns("a1") && !plugins.owns("a2"))
        #expect(plugins.owns("b"))
        try await Task.sleep(for: .seconds(1))
        #expect(!received.has("a2", icon: "refresh"))
    }
}
