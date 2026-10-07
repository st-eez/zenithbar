import AppKit
import ZenithBarCore
import ZenithBarKit

/// What an item draws. Items are laid out by their ink, the part of the drawing that shows,
/// so every gap is the same whatever side bearings a font gives its glyphs: the app glyphs
/// of sketchybar-app-font carry several points of blank on their right (docs/overview.md).
struct Item: Equatable {
    enum Content: Equatable {
        case text(NSAttributedString)
        /// Drawn at `size` points, centered, its ink between `ink`'s bounds.
        case image(CGImage, size: CGSize, ink: ClosedRange<CGFloat>)
    }

    /// What a text item centers on the bar's middle line.
    enum Center: Equatable {
        /// The height of its first font's capitals and figures, so items' baselines agree and
        /// a descender, as in "Ghostty", moves nothing, as Omarchy's shell centers labels.
        case figures
        /// Its glyphs' ink, for an icon.
        case ink
    }

    var content: Content
    var center = Center.figures

    /// Blank above and below text in its bitmap, for glyphs raised or lowered to line up.
    static let pad: CGFloat = 3

    /// The drawing's size in points. Text's bitmap spans its advance and its ink, as a glyph,
    /// as Nerd Font's robot, can draw past its advance on either side.
    var size: CGSize {
        switch content {
        case let .text(text):
            let ink = inkBounds(text)
            return CGSize(width: ceil(max(text.size().width, ink.maxX) + inset), height: ceil(text.size().height) + 2 * Self.pad)
        case let .image(_, size, _): return size
        }
    }

    /// How far right text is drawn in its bitmap, to hold ink that starts left of its origin.
    var inset: CGFloat {
        guard case let .text(text) = content else { return 0 }
        return ceil(max(0, -inkBounds(text).minX))
    }

    /// Where the drawing's ink starts and ends, from its left edge.
    var ink: ClosedRange<CGFloat> {
        switch content {
        case let .text(text):
            let bounds = inkBounds(text)
            return bounds.minX...bounds.maxX
        case let .image(_, _, ink): return ink
        }
    }

    /// The drawing's bottom edge on a bar `height` tall, from the bar's bottom.
    func bottom(height: CGFloat) -> CGFloat {
        guard case let .text(text) = content else { return (height - size.height) / 2 }
        let middle = switch center {
        case .figures: (text.firstFont?.capHeight ?? 0) / 2
        case .ink: inkBounds(text).midY
        }
        // AppKit puts the baseline the line's descent above where it draws.
        return height / 2 - middle - Self.pad - descent(text)
    }
}

private func descent(_ text: NSAttributedString) -> CGFloat {
    var descent: CGFloat = 0
    CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, &descent, nil)
    return descent
}

/// A borderless panel that never takes key or activates ZenithBar (docs/overview.md, clicks).
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One display's bar: one panel, its fill and a layer per item. A change sets only the
/// layers whose items changed, and moves the rest only when a width changed
/// (docs/overview.md, an update's cost).
@MainActor final class Bar {
    static let height = CGFloat(BarStyle.height)

    let panel: BarPanel
    private let fill = CAShapeLayer()
    /// The style and width the fill's outline was drawn for.
    private var outlined: (style: BarStyle, width: CGFloat)?
    /// The display's scale the items were drawn at.
    private var scale: CGFloat?
    /// The left edge of the display's notch, from the display's left, where the left run ends.
    private var notch: Double?
    private var left: [(key: String, item: Item)] = []
    private var right: [(key: String, item: Item)] = []
    private var layers: [String: CALayer] = [:]
    /// Each item's frame in the bar, for hit testing.
    private(set) var frames: [String: CGRect] = [:]

    init(screen: NSScreen, view: NSView) {
        panel = BarPanel(contentRect: Self.frame(on: screen), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // SketchyBar's level, under apps' windows and the revealed menu bar, and on every Space
        // without a private Space of ZenithBar's own (docs/overview.md, Spaces).
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        view.wantsLayer = true
        panel.contentView = view
        fill.frame = view.bounds
        view.layer?.addSublayer(fill)
        notch = Self.notch(on: screen)
        panel.orderFrontRegardless()
    }

    static func frame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    /// The notch is 32 pt tall, so the bar sits inside it and ink there is hidden. The area
    /// beside it is in global coordinates: on the built-in display, its frame's top at y 0, it
    /// read y -32 (2026-10-06).
    private static func notch(on screen: NSScreen) -> Double? {
        screen.auxiliaryTopLeftArea.map { Double($0.maxX - screen.frame.minX) }
    }

    func move(to screen: NSScreen) {
        panel.setFrame(Self.frame(on: screen), display: false)
        fill.frame = CGRect(origin: .zero, size: panel.frame.size)
        if Self.notch(on: screen) != notch {
            notch = Self.notch(on: screen)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            place()
            CATransaction.commit()
        }
    }

    /// Shows `left` and `right`, each in order from its end of the bar inward.
    func show(left: [(key: String, item: Item)], right: [(key: String, item: Item)], style: BarStyle,
              background: CGColor, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.fillColor = background
        var moved = false
        if outlined?.style != style || outlined?.width != panel.frame.width {
            fill.path = style.outline(width: Double(panel.frame.width))
            outlined = (style, panel.frame.width)
            moved = true
        }
        // A display that changes between HiDPI and 1x modes keeps its ID and its bar.
        var old = Dictionary(self.left + self.right, uniquingKeysWith: { first, _ in first })
        if self.scale != scale {
            for layer in layers.values { layer.contentsScale = scale }
            self.scale = scale
            old = [:]
        }
        let keys = Set((left + right).map(\.key))
        for (key, layer) in layers where !keys.contains(key) {
            layer.removeFromSuperlayer()
            layers[key] = nil
        }
        moved = moved || left.map(\.key) != self.left.map(\.key) || right.map(\.key) != self.right.map(\.key)
        for (key, item) in left + right where old[key] != item || layers[key] == nil {
            moved = moved || old[key]?.ink != item.ink
            draw(item, into: layer(key, scale: scale))
        }
        self.left = left
        self.right = right
        if moved { place() }
        CATransaction.commit()
    }

    private func layer(_ key: String, scale: CGFloat) -> CALayer {
        if let layer = layers[key] { return layer }
        let layer = CALayer()
        layer.contentsScale = scale
        layer.contentsGravity = .center
        fill.addSublayer(layer)
        layers[key] = layer
        return layer
    }

    private func draw(_ item: Item, into layer: CALayer) {
        switch item.content {
        case .text: layer.contents = render(item, size: item.size, scale: layer.contentsScale)
        case let .image(image, _, _): layer.contents = image
        }
    }

    /// Text drawn once into a bitmap the layer keeps, so moving the item draws nothing.
    private func render(_ item: Item, size: CGSize, scale: CGFloat) -> CGImage? {
        guard case let .text(text) = item.content, size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: item.inset, y: Item.pad))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Between the ink of neighbouring items, the 16 pt Steve's SketchyBar config put between
    /// workspaces.
    static let gap = 16.0

    private func place() {
        let starts = layout(left: left.map { Double($0.item.ink.upperBound - $0.item.ink.lowerBound) },
                            right: right.map { Double($0.item.ink.upperBound - $0.item.ink.lowerBound) },
                            width: Double(panel.frame.width), insets: (outlined?.style ?? .standard).insets,
                            gap: Self.gap, notch: notch)
        for (index, (key, _)) in left.enumerated() { layers[key]?.isHidden = index >= starts.left.count }
        frames = [:]
        for ((key, item), x) in zip(left.prefix(starts.left.count) + right, starts.left + starts.right) {
            let ink = item.ink, width = ink.upperBound - ink.lowerBound, half = CGFloat(Self.gap / 2)
            frames[key] = CGRect(x: x - half, y: 0, width: width + 2 * half, height: Self.height)
            let size = item.size
            // On the pixel grid, as a bitmap moved by part of a pixel draws its text blurred.
            let scale = panel.backingScaleFactor
            layers[key]?.frame = CGRect(x: ((x - ink.lowerBound - item.inset) * scale).rounded() / scale,
                                        y: (item.bottom(height: Self.height) * scale).rounded() / scale,
                                        width: size.width, height: size.height)
        }
    }

    func item(at point: CGPoint) -> String? { frames.first { $0.value.contains(point) }?.key }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
