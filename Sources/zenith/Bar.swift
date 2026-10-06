import AppKit
import ZenithCore

/// What an item draws, between its padding.
struct Item: Equatable {
    enum Content: Equatable {
        case text(NSAttributedString)
        /// Drawn at `size` points, centered in the item.
        case image(CGImage, size: CGSize)
    }

    var content: Content
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    /// Up from centered.
    var lift: CGFloat = 0

    var width: CGFloat {
        switch content {
        case let .text(text): leading + ceil(text.size().width) + trailing
        case let .image(_, size): leading + size.width + trailing
        }
    }
}

/// A borderless panel that never takes key or activates Zenith (docs/overview.md, clicks).
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One display's bar: one panel, its fill and a layer per item. A change sets only the
/// layers whose items changed, and moves the rest only when a width changed
/// (docs/overview.md, an update's cost).
@MainActor final class Bar {
    static let height: CGFloat = 25
    static let insets: (left: Double, right: Double) = (20, 22)

    let display: CGDirectDisplayID
    let panel: BarPanel
    private let fill = CALayer()
    private var left: [(key: String, item: Item)] = []
    private var right: [(key: String, item: Item)] = []
    private var layers: [String: CALayer] = [:]
    /// Each item's frame in the bar, for hit testing.
    private(set) var frames: [String: CGRect] = [:]

    init(screen: NSScreen, view: NSView) {
        display = screen.displayID
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
        // without a private Space of Zenith's own (docs/overview.md, Spaces).
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        view.wantsLayer = true
        panel.contentView = view
        fill.frame = view.bounds
        view.layer?.addSublayer(fill)
        panel.orderFrontRegardless()
    }

    static func frame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    func move(to screen: NSScreen) {
        panel.setFrame(Self.frame(on: screen), display: false)
        fill.frame = CGRect(origin: .zero, size: panel.frame.size)
    }

    /// Shows `left` and `right`, each in order from its end of the bar inward.
    func show(left: [(key: String, item: Item)], right: [(key: String, item: Item)], background: CGColor, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = background
        let keys = Set((left + right).map(\.key))
        for (key, layer) in layers where !keys.contains(key) {
            layer.removeFromSuperlayer()
            layers[key] = nil
        }
        let old = Dictionary(self.left + self.right, uniquingKeysWith: { first, _ in first })
        var moved = left.map(\.key) != self.left.map(\.key) || right.map(\.key) != self.right.map(\.key)
        for (key, item) in left + right where old[key] != item || layers[key] == nil {
            moved = moved || old[key]?.width != item.width
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
        case let .text(text):
            let text = text.size()
            layer.contents = render(item, size: CGSize(width: ceil(text.width), height: ceil(text.height)), scale: layer.contentsScale)
        case let .image(image, _):
            layer.contents = image
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
        text.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private func place() {
        let edges = layout(left: left.map { Double($0.item.width) }, right: right.map { Double($0.item.width) },
                           width: Double(panel.frame.width), insets: Self.insets)
        frames = [:]
        for ((key, item), x) in Array(zip(left, edges.left)) + Array(zip(right, edges.right)) {
            let frame = CGRect(x: x, y: 0, width: item.width, height: Self.height)
            frames[key] = frame
            let size: CGSize = switch item.content {
            case let .text(text): CGSize(width: ceil(text.size().width), height: ceil(text.size().height))
            case let .image(_, size): size
            }
            layers[key]?.frame = CGRect(x: frame.minX + item.leading, y: ((Self.height - size.height) / 2 + item.lift).rounded(),
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
