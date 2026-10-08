import AppKit
import ZenithBarCore
import ZenithBarKit

/// The Tailscale item and its panel (docs/tailscale.md): Tailscale's mark, dim while its tunnel
/// is down; a left click opens the panel and a right click turns Tailscale on or off, as on
/// Omarchy.
@MainActor final class TailscaleModule: BarModule {
    let keys = ["tailscale"]
    private var tailscale: Tailscale!
    private var host: ModuleHost!
    private var images = DrawingCache<Item?>()
    private lazy var panel: TailscalePanel = {
        let panel = TailscalePanel(tailscale: tailscale)
        panel.host = host.panel
        return panel
    }()

    func start(_ host: ModuleHost) {
        self.host = host
        tailscale = Tailscale { icon in host.changed(icon) }
    }

    func wake() { tailscale.readStore() }

    func items(scale: CGFloat, theme: Theme) -> [(key: String, item: Item)] {
        guard let on = tailscale.on else { return [] }
        let color = on ? theme.foreground : theme.dim
        guard let item = images.image("tailscale", scale: scale, shows: color, draw: {
            inkImage(tailscaleMark(size: 12, color: color.nsColor), scale: scale)
        }) else { return [] }
        return [("tailscale", item)]
    }

    func clicked(_ key: String, button: MouseButton) -> Click {
        switch button {
        case .left: return .togglePanel
        case .right: if let on = tailscale.on { tailscale.turn(on: !on) }
        case .middle: break
        }
        return .handled
    }

    func panel(for key: String, theme: Theme) -> NSView? {
        panel.theme = theme
        return panel
    }

    func panelOpened() { panel.open() }
    func panelClosed() { panel.close() }
    func refreshPanel() { panel.update() }
}

/// Tailscale's mark, a 3 by 3 grid of dots with the middle row and the bottom's middle dot
/// full and the rest faint, drawn as Omarchy's `TailscaleIcon.qml` draws it, `size` points
/// square.
func tailscaleMark(size: CGFloat, color: NSColor) -> NSImage {
    let dot = size * 0.27, step = (size - dot) / 2
    let full: Set<Int> = [3, 4, 5, 7]
    return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        for index in 0..<9 {
            color.withAlphaComponent(color.alphaComponent * (full.contains(index) ? 1 : 0.24)).setFill()
            NSBezierPath(ovalIn: NSRect(x: CGFloat(index % 3) * step, y: CGFloat(index / 3) * step, width: dot,
                                        height: dot)).fill()
        }
        return true
    }
}
