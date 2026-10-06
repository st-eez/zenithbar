// Probes for macOS behaviour the bar's design depends on. Each probe touches only windows it
// creates itself, apart from `cost sketchybar`, and the header of its file says what it measures.
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let commands: [(name: String, usage: String, run: @MainActor ([String]) -> Void)] = [
    ("cost", "cost [updates] [text|image|sketchybar...]", { arguments in
        let count = arguments.first.flatMap(Int.init)
        cost(updates: count ?? 300, modes: Array(arguments.dropFirst(count == nil ? 0 : 1)))
    }),
    ("shape", "shape [visual|masked|skylight|tint...]", { shape($0) }),
    ("watch", "watch [seconds] [fullscreen] [level=<n>]", { arguments in
        watch(seconds: arguments.first.flatMap(Double.init) ?? 120, fullscreen: arguments.contains("fullscreen"),
              level: arguments.first { $0.hasPrefix("level=") }.flatMap { Int($0.dropFirst(6)) })
    }),
    ("clicks", "clicks", { _ in clicks() }),
]

func usage() -> Never {
    print("usage: zenith-probe " + commands.map(\.usage).joined(separator: " | "))
    exit(2)
}

guard let command = commands.first(where: { $0.name == CommandLine.arguments.dropFirst().first }) else { usage() }
command.run(Array(CommandLine.arguments.dropFirst(2)))
