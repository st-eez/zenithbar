// Probes for macOS behaviour the bar's design depends on. Each probe touches only windows it
// creates itself, apart from `cost sketchybar`, `tray press`, `network launchd`, which loads a
// LaunchAgent of its own, and `sound write`, which sets and restores a virtual audio device's
// input mute and level; the header of its file says what it measures.
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let commands: [(name: String, usage: String, run: @MainActor ([String]) -> Void)] = [
    ("cost", "cost [updates] [text|image|still|windows|sketchybar...]", { arguments in
        let count = arguments.first.flatMap(Int.init)
        cost(updates: count ?? 300, modes: Array(arguments.dropFirst(count == nil ? 0 : 1)))
    }),
    ("shape", "shape [visual|masked|skylight|tint...]", { shape($0) }),
    ("watch", "watch [seconds]", { watch(seconds: $0.first.flatMap(Double.init) ?? 120) }),
    ("clicks", "clicks", { _ in clicks() }),
    ("focus", "focus", { _ in focusProbe() }),
    // Drives ZenithBar's panels without the pointer, through its test hooks (Controller.watchTestHooks).
    ("send", "send <command>", { arguments in
        DistributedNotificationCenter.default().postNotificationName(
            .init("io.github.st-eez.zenithbar.test"), object: arguments.joined(separator: " "), userInfo: nil,
            deliverImmediately: true)
        exit(0)
    }),
    ("popups", "popups [seconds]", { popups(seconds: $0.first.flatMap(Double.init) ?? 120) }),
    ("tray", "tray list|capture [runs] | tray watch [seconds] [own] | tray press <bundle id>", { tray($0) }),
    ("network", "network read [runs] | network watch|cost [seconds] | network launchd <arguments> | network wifi | network stats [seconds] [spawn] | network speedtest", { network($0) }),
    ("sound", "sound read [runs] | sound watch|cost [seconds] | sound write <virtual device name>", { sound($0) }),
]

func usage() -> Never {
    print("usage: zenithbar-probe " + commands.map(\.usage).joined(separator: " | "))
    exit(2)
}

guard let command = commands.first(where: { $0.name == CommandLine.arguments.dropFirst().first }) else { usage() }
command.run(Array(CommandLine.arguments.dropFirst(2)))
