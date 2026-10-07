import AppKit
import ZenithBarCore
import ZenithBarKit

/// The network item and its panel (docs/network.md): the interface macOS routes through, and
/// on a left click the network panel.
@MainActor final class NetworkModule: BarModule {
    let keys = ["network"]
    private var network: Network!
    private var host: ModuleHost!
    private var images = DrawingCache<Item?>()
    private var locationLog: LocationLog?
    private lazy var panel: NetworkPanel = {
        let panel = NetworkPanel(network: network)
        panel.host = host.panel
        return panel
    }()

    func start(_ host: ModuleHost) {
        self.host = host
        network = Network { glyph in host.changed(glyph) }
        locationLog = LocationLog()
    }

    func wake() { network.read() }

    func items(scale: CGFloat, theme: Theme) -> [(key: String, item: Item)] {
        let route = networkIcon(network.route), color = route.dim ? theme.dim : theme.foreground
        guard let item = images.image("network", scale: scale, shows: Drawn(icon: route.icon, color: color), draw: {
            Self.drawing(route.icon, color: color.nsColor).flatMap { inkImage($0, scale: scale) }
        }) else { return [] }
        return [("network", item)]
    }

    private struct Drawn: Equatable {
        var icon: NetworkIcon
        var color: RGBA
    }

    /// At 14 pt, about 12 pt tall, as the battery; at 16 pt the Wi-Fi's arcs outweighed the
    /// speaker beside it.
    private static func drawing(_ icon: NetworkIcon, color: NSColor) -> NSImage? {
        switch icon {
        case let .symbol(name, value): symbol(name, value: value, pointSize: 14, color: color)
        // The glyph at 16 pt, as the bar's other Nerd Font icons.
        case let .glyph(text): glyph(text, font: barFont(16), color: color)
        }
    }

    func clicked(_ key: String, button: MouseButton) -> Click { button == .left ? .togglePanel : .handled }

    func panel(for key: String, theme: Theme) -> NSView? {
        panel.theme = theme
        return panel
    }

    func panelOpened() { panel.open() }
    func panelClosed() { panel.close() }
    func refreshPanel() { panel.refresh() }

    #if DEBUG
    /// `network speedtest`, `network allow` and `network password <name>`, as clicks on them.
    func test(_ words: [String]) -> Bool {
        switch (words.first, words.dropFirst().first) {
        case ("network", "speedtest"): panel.pressSpeedTest()
        case ("network", "allow"): panel.pressAllow()
        case ("network", "password"): if words.count > 2 { panel.pressPassword(words[2]) }
        default: return false
        }
        return true
    }
    #endif
}
