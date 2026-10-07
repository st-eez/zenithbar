import AppKit
import ZenithBarCore
import ZenithBarKit

/// The Bluetooth item and its panel (docs/bluetooth.md): Omarchy's glyph for on, connected and
/// off, and on a left click the Bluetooth panel.
@MainActor final class BluetoothModule: BarModule {
    let keys = ["bluetooth"]
    private var bluetooth: Bluetooth!
    private var host: ModuleHost!
    private var images = DrawingCache<Item?>()
    private lazy var panel: BluetoothPanel = {
        let panel = BluetoothPanel(bluetooth: bluetooth)
        panel.resized = host.panel.resized
        return panel
    }()

    func start(_ host: ModuleHost) {
        self.host = host
        bluetooth = Bluetooth { host.changed(true) }
    }

    func wake() { bluetooth.read() }

    func items(scale: CGFloat, theme: Theme) -> [(key: String, item: Item)] {
        guard let icon = bluetooth.state.icon,
              let item = images.glyphItem(icon.glyph, slot: "bluetooth", color: icon == .off ? theme.dim : theme.foreground,
                                          scale: scale) else { return [] }
        return [("bluetooth", item)]
    }

    func clicked(_ key: String, button: MouseButton) -> Click { button == .left ? .togglePanel : .handled }

    func panel(for key: String, theme: Theme) -> NSView? {
        panel.theme = theme
        return panel
    }

    func panelOpened() { panel.open() }
    func panelClosed() { panel.close() }
    func refreshPanel() { panel.update() }

    #if DEBUG
    /// `bluetooth connected <percent> <name>` draws a paired device connected, the name last as
    /// it has spaces.
    func test(_ words: [String]) -> Bool {
        guard words.first == "bluetooth", words.dropFirst().first == "connected" else { return false }
        let rest = words.count > 2 ? words[2].split(separator: " ", maxSplits: 1).map(String.init) : []
        if rest.count == 2 { bluetooth.pretend(connected: rest[1], battery: Int(rest[0])) }
        return true
    }
    #endif
}
