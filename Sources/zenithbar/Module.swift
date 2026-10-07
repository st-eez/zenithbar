import AppKit
import ZenithBarCore
import ZenithBarKit

/// A built-in item of the bar's right run, with its clicks, scrolling and panel, as the calendar,
/// the battery, the network, Bluetooth and the sound (docs/overview.md, modules). The controller
/// keeps them in bar order and hands each what its items' keys receive. A module runs from
/// `start` until ZenithBar exits.
@MainActor protocol BarModule: AnyObject {
    /// The keys of the items it may show, by which the controller hands it clicks, scrolls and
    /// its panel.
    var keys: [String] { get }
    /// Starts reading and watching what it shows; it asks for redraws and its panel's needs
    /// through `host`.
    func start(_ host: ModuleHost)
    /// Its items for a display at `scale`, from the bar's end inward, leaving out one it hides,
    /// as the microphone while nothing records or is muted.
    func items(scale: CGFloat, theme: Theme) -> [(key: String, item: Item)]
    /// Acts on a click on item `key`, or answers that the click opens or closes the item's panel.
    func clicked(_ key: String, button: MouseButton) -> Click
    func scrolled(_ key: String, delta: Double, precise: Bool, momentum: Bool)
    /// The view item `key`'s panel shows, in `theme` and laid out; nil for an item without one.
    func panel(for key: String, theme: Theme) -> NSView?
    /// Its panel now shows: what runs only while it shows starts.
    func panelOpened()
    func panelClosed()
    /// What it shows changed while its panel shows.
    func refreshPanel()
    /// The Mac woke, and what it shows may have changed meanwhile.
    func wake()
    /// config.json was read.
    func configure(_ config: Config)
    #if DEBUG
    /// A test hook's words (`Controller.watchTestHooks`); false when they are not its.
    func test(_ words: [String]) -> Bool
    #endif
}

enum MouseButton { case left, right, middle }

enum Click {
    case handled
    /// Opens the item's panel, or closes it when it shows.
    case togglePanel
}

extension BarModule {
    func clicked(_ key: String, button: MouseButton) -> Click { .handled }
    func scrolled(_ key: String, delta: Double, precise: Bool, momentum: Bool) {}
    func panel(for key: String, theme: Theme) -> NSView? { nil }
    func panelOpened() {}
    func panelClosed() {}
    func refreshPanel() {}
    func configure(_ config: Config) {}
    #if DEBUG
    func test(_ words: [String]) -> Bool { false }
    #endif
}

/// What the controller does for a module.
struct ModuleHost {
    /// Redraws the bars when `icon` says its items changed, and refreshes its panel while it
    /// shows either way.
    let changed: @MainActor (_ icon: Bool) -> Void
    let panel: PanelHost
}

/// What the popup does for a panel: takes and gives back the keyboard for a password field,
/// places the panel again when its height changes, and closes it once the pointer is off it.
struct PanelHost {
    let takeKeyboard: @MainActor (NSView) -> Void
    let giveKeyboardBack: @MainActor () -> Void
    let resized: @MainActor () -> Void
    let pointerMayHaveLeft: @MainActor () -> Void
}

/// A symbol's or a glyph's name and color, what its item shows.
private struct Tinted: Equatable {
    var name: String
    var color: RGBA
}

extension DrawingCache<Item?> {
    /// An image item for `slot` at `scale`, from `draw` only when what it `shows` changes.
    mutating func image<Shows: Equatable>(_ slot: String, scale: CGFloat, shows: Shows,
                                          draw: () -> (CGImage, CGSize, ClosedRange<CGFloat>)?) -> Item? {
        drawing(slot, scale: scale, shows: shows) { draw().map { Item(content: .image($0.0, size: $0.1, ink: $0.2)) } }
    }

    /// The SF Symbol `name` at 14 pt, as the network's icon, cropped to its ink.
    mutating func symbolItem(_ name: String, slot: String, color: RGBA, scale: CGFloat) -> Item? {
        image(slot, scale: scale, shows: Tinted(name: name, color: color)) {
            symbol(name, value: nil, pointSize: 14, color: color.nsColor).flatMap { inkImage($0, scale: scale) }
        }
    }

    /// `text` in the bar's font at 16 pt, as the Ethernet glyph, cropped to its ink.
    mutating func glyphItem(_ text: String, slot: String, color: RGBA, scale: CGFloat) -> Item? {
        image(slot, scale: scale, shows: Tinted(name: text, color: color)) {
            inkImage(glyph(text, font: barFont(16), color: color.nsColor), scale: scale)
        }
    }
}
