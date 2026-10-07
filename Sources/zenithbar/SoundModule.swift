import AppKit
import ZenithBarCore
import ZenithBarKit

/// The speaker and the microphone items and the sound panel (docs/sound.md), after Omarchy's:
/// a left or middle click on the speaker opens the panel and a right click mutes it; a click on
/// the microphone mutes it and a middle click opens the panel; scrolling on either steps its
/// level by 5%.
@MainActor final class SoundModule: BarModule {
    let keys = ["volume", "mic"]
    private var sound: Sound!
    private var host: ModuleHost!
    /// config.json's `keepBuiltInMic`, which may be read before `start`.
    private var keepBuiltInMic = true
    /// Scroll steps carried between events, for the speaker and the microphone.
    private var scrolls: [String: ScrollSteps] = [:]
    private var images = DrawingCache<Item?>()
    private lazy var panel: SoundPanel = {
        let panel = SoundPanel(sound: sound)
        panel.resized = host.panel.resized
        return panel
    }()
    #if DEBUG
    /// The microphone item as a test hook draws it.
    private var micShown: MicState?
    #endif

    func start(_ host: ModuleHost) {
        self.host = host
        sound = Sound { host.changed(true) }
        sound.keepBuiltInMic = keepBuiltInMic
    }

    func configure(_ config: Config) {
        keepBuiltInMic = config.keepBuiltInMic
        sound?.keepBuiltInMic = keepBuiltInMic
    }

    func wake() { sound.read() }

    /// The speaker, then the microphone while it shows.
    func items(scale: CGFloat, theme: Theme) -> [(key: String, item: Item)] {
        var items: [(key: String, item: Item)] = []
        let output = sound.state.defaultDevice(.output)
        let speaker = outputSymbol(output, bluetooth: output.flatMap { sound.bluetooth(for: $0) })
        if let item = images.symbolItem(speaker.name, slot: "volume", color: speaker.dim ? theme.dim : theme.foreground,
                                        scale: scale) {
            items.append(("volume", item))
        }
        var micState = sound.state.mic
        #if DEBUG
        micState = micShown ?? micState
        #endif
        if let mic = micState.symbol,
           let item = images.symbolItem(mic.name, slot: "mic", color: mic.alert ? theme.alert : theme.foreground, scale: scale) {
            items.append(("mic", item))
        }
        return items
    }

    func clicked(_ key: String, button: MouseButton) -> Click {
        switch (key, button) {
        case ("volume", .left), ("volume", .middle), ("mic", .middle): return .togglePanel
        case ("volume", .right): sound.toggleMute(.output, because: "speaker right click")
        case ("mic", .left): sound.toggleMic()
        default: break
        }
        return .handled
    }

    func scrolled(_ key: String, delta: Double, precise: Bool, momentum: Bool) {
        let steps = scrolls[key, default: ScrollSteps()].steps(delta: delta, precise: precise, momentum: momentum)
        guard steps != 0 else { return }
        if key == "volume" { sound.stepOutput(steps) } else { sound.stepInput(steps) }
    }

    /// One panel, under the speaker or the microphone, whichever opened it.
    func panel(for key: String, theme: Theme) -> NSView? {
        panel.theme = theme
        panel.update()
        return panel
    }

    func refreshPanel() { panel.update() }

    #if DEBUG
    /// `mic live|muted|off|real` draws the microphone item that way, or as it is, for captures.
    func test(_ words: [String]) -> Bool {
        guard words.first == "mic", let state = words.dropFirst().first else { return false }
        micShown = ["live": .live, "muted": .muted, "off": .hidden][state]
        host.changed(true)
        return true
    }
    #endif
}
