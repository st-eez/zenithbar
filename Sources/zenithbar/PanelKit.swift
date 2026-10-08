import AppKit
import ZenithBarCore
import ZenithBarKit

// The pieces the bar's interactive panels are built from: labels, buttons, a switch, a slider,
// rows, a scrolling list and a password field, drawn in the theme's colors and the bar's fonts, solid,
// as the plugin panel is (docs/plugins.md, docs/network.md, the panel). Every control takes
// the first click, as the panel is never active (docs/overview.md, clicks).

/// The bar's font: JetBrains Mono Nerd Font, as Steve's SketchyBar config.
func panelFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "JetBrainsMonoNF-Bold" : "JetBrainsMonoNF-Regular", size: size)
        ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
}

extension Theme {
    /// Behind a hovered control or row.
    var hover: NSColor { foreground.with(alpha: 0.08).nsColor }
    /// Behind the current row, as the connected network.
    var current: NSColor { accent.with(alpha: 0.16).nsColor }
}

/// One line of text, cut with "…" when it does not fit. `kern` spaces the letters, as
/// Omarchy's captions are.
final class PanelLabel: NSTextField {
    init(size: CGFloat, bold: Bool = false, alignment: NSTextAlignment = .left) {
        super.init(frame: .zero)
        font = panelFont(size, bold: bold)
        self.alignment = alignment
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, color: NSColor, kern: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let next = NSAttributedString(string: text, attributes: [
            .font: font as Any, .foregroundColor: color, .kern: kern, .paragraphStyle: paragraph,
        ])
        if next != attributedStringValue { attributedStringValue = next }
    }

    /// Its height for one line, measured once, as its font does not change and measuring set
    /// the text out again at each of the network panel's samples.
    private(set) lazy var lineHeight: CGFloat = {
        let cell = NSTextFieldCell(textCell: "Hg")
        cell.font = font
        return ceil(cell.cellSize.height)
    }()

    // A label passes clicks to the row under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view that lays its subviews out from the top, as the panels do.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// An SF Symbol, or any image, drawn at its own size, centered.
final class PanelImage: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        image.draw(in: NSRect(x: ((bounds.width - image.size.width) / 2).rounded(), y: ((bounds.height - image.size.height) / 2).rounded(),
                              width: image.size.width, height: image.size.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The SF Symbol `name`, filled to `value` when it has one, cropped to its ink at `scale`, as
/// the bar draws its icons (`inkImage`), so it draws at its size without stretching. Kept once
/// drawn, as cropping scans every pixel and the open network panel spent 12 ms a second
/// drawing its symbols again at each sample (docs/network.md, the panel's cost).
@MainActor func panelSymbol(_ name: String, value: Double? = nil, pointSize: CGFloat, color: RGBA,
                            scale: CGFloat) -> NSImage? {
    let key = SymbolKey(name: name, value: value, pointSize: pointSize, color: color, scale: scale)
    if let image = symbolCache[key] { return image }
    let image = symbol(name, value: value, pointSize: pointSize, color: color.nsColor).flatMap { inkImage($0, scale: scale) }
        .map { NSImage(cgImage: $0.0, size: $0.1) }
    symbolCache[key] = image
    return image
}

private struct SymbolKey: Hashable {
    var name: String
    var value: Double?
    var pointSize: CGFloat
    var color: RGBA
    var scale: CGFloat
}

/// A few dozen at most: the panels' symbols, in the theme's colors, at each signal level.
@MainActor private var symbolCache: [SymbolKey: NSImage?] = [:]

/// The Nerd Font glyph `text` in the bar's font at `size`, cropped to its ink at `scale`, as
/// the Bluetooth and Tailscale panels draw theirs; kept once drawn, as `panelSymbol` is.
@MainActor func panelGlyph(_ text: String, size: CGFloat, color: RGBA, scale: CGFloat) -> NSImage? {
    let key = SymbolKey(name: text, value: nil, pointSize: size, color: color, scale: scale)
    if let image = glyphCache[key] { return image }
    let image = inkImage(glyph(text, font: panelFont(size), color: color.nsColor), scale: scale).map { NSImage(cgImage: $0.0, size: $0.1) }
    glyphCache[key] = image
    return image
}

/// A dozen at most: the Bluetooth glyphs and the machines' OS logos, in the theme's colors.
@MainActor private var glyphCache: [SymbolKey: NSImage?] = [:]

/// A control: it shows a hover, takes the first click, and acts when the button comes up
/// inside it.
class PanelControl: FlippedView {
    var action: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }
    var theme = Theme.fallback { didSet { needsDisplay = true } }
    private(set) var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false }
    }
}

/// An icon button: an SF Symbol on a rounded fill that shows on hover.
final class PanelButton: PanelControl {
    var symbolName: String { didSet { if symbolName != oldValue { needsDisplay = true } } }
    let pointSize: CGFloat
    /// Drawn in the accent color, as a button whose action is running.
    var active = false { didSet { needsDisplay = true } }

    init(symbol: String, pointSize: CGFloat = 13, action: (() -> Void)? = nil) {
        symbolName = symbol
        self.pointSize = pointSize
        super.init(frame: .zero)
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovered && isEnabled {
            theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color = !isEnabled ? theme.dim : active ? theme.accent : theme.foreground
        guard let image = panelSymbol(symbolName, pointSize: pointSize, color: color,
                                      scale: window?.backingScaleFactor ?? 2) else { return }
        image.draw(in: NSRect(x: ((bounds.width - image.size.width) / 2).rounded(),
                              y: ((bounds.height - image.size.height) / 2).rounded(), width: image.size.width,
                              height: image.size.height))
    }
}

/// A button that copies a value, and shows a check for a second after.
final class CopyButton: PanelControl {
    var value: String? { didSet { isHidden = value == nil } }
    /// Called with the value once copied, as for a caption that says so.
    var copied: ((String) -> Void)?
    private let button: PanelButton

    init(pointSize: CGFloat = 10) {
        button = PanelButton(symbol: "doc.on.doc", pointSize: pointSize)
        super.init(frame: .zero)
        button.autoresizingMask = [.width, .height]
        addSubview(button)
        button.action = { [weak self] in self?.copy() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var theme: Theme { didSet { button.theme = theme } }

    override func layout() {
        super.layout()
        button.frame = bounds
    }

    private func copy() {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied?(value)
        button.symbolName = "checkmark"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            onMain { self?.button.symbolName = "doc.on.doc" }
        }
    }
}

/// An on and off switch: the accent's track with the knob at the right when on.
final class PanelSwitch: PanelControl {
    var isOn = false { didSet { needsDisplay = true } }
    static let size = NSSize(width: 28, height: 16)

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: (bounds.width - Self.size.width) / 2, y: (bounds.height - Self.size.height) / 2,
                           width: Self.size.width, height: Self.size.height)
        (isOn ? theme.accent.nsColor : theme.foreground.with(alpha: hovered ? 0.3 : 0.2).nsColor).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let knob = track.height - 4
        (isOn ? theme.background.nsColor : theme.foreground.nsColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: isOn ? track.maxX - 2 - knob : track.minX + 2, y: track.minY + 2, width: knob,
                                    height: knob)).fill()
    }
}

/// A slider from 0 to 1, after Omarchy's `PanelSlider`: a track filled to the value in the
/// foreground and a round knob, which a click or a drag moves. `moved` is called at each step
/// of a drag. While dragging, the knob follows the pointer alone: a `value` set meanwhile, as the
/// listener's echo of the change, is kept for after, so the knob does not jump back
/// (docs/sound.md, the panel).
final class PanelSlider: PanelControl {
    var value = 0.0 { didSet { if value != oldValue, dragged == nil { needsDisplay = true } } }
    /// Drawn at half strength, as a muted channel's.
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    var moved: ((Double) -> Void)?
    var rightClicked: (() -> Void)?
    /// The value under the pointer while dragging.
    private(set) var dragged: Double?
    var shown: Double { dragged ?? value }
    static let knob: CGFloat = 14

    private var track: NSRect {
        // Inset for the knob at either end, grown on hover and with its border.
        NSRect(x: 10, y: (bounds.height - 4) / 2, width: max(1, bounds.width - 20), height: 4)
    }

    private func value(at event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        return min(1, max(0, Double((x - track.minX) / track.width)))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        drag(to: value(at: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, dragged != nil else { return }
        drag(to: value(at: event))
    }

    /// Keeps the last dragged value as the value, for the moment until the listener reads it back.
    override func mouseUp(with event: NSEvent) {
        guard let dragged else { return }
        self.dragged = nil
        value = dragged
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if isEnabled { rightClicked?() }
    }

    /// Ends a drag without a release, as when the device it moves goes.
    func cancelDrag() {
        dragged = nil
        needsDisplay = true
    }

    private func drag(to next: Double) {
        guard next != dragged else { return }
        dragged = next
        needsDisplay = true
        moved?(next)
    }

    override func draw(_ dirtyRect: NSRect) {
        let strength = !isEnabled ? 0.35 : dimmed ? 0.5 : 1
        let track = self.track
        theme.foreground.with(alpha: 0.18).nsColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        guard isEnabled else { return }
        let x = track.minX + track.width * shown
        theme.foreground.with(alpha: strength).nsColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: x - track.minX, height: track.height), xRadius: 2,
                     yRadius: 2).fill()
        let size = Self.knob * (hovered || dragged != nil ? 1.15 : 1)
        let knob = NSBezierPath(ovalIn: NSRect(x: x - size / 2, y: (bounds.height - size) / 2, width: size, height: size))
        theme.foreground.with(alpha: strength).nsColor.setFill()
        knob.fill()
        theme.background.nsColor.setStroke()
        knob.lineWidth = 2
        knob.stroke()
    }
}

/// A row of a list: a rounded fill on hover, and on the current row, as the connected network.
class PanelRow: PanelControl {
    var current = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor? = current ? theme.current : hovered && isEnabled ? theme.hover : nil
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// A thin line across a panel.
final class PanelDivider: NSView {
    var theme = Theme.fallback { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        theme.foreground.with(alpha: 0.12).nsColor.setFill()
        NSRect(x: 0, y: (bounds.height - 1) / 2, width: bounds.width, height: 1).fill()
    }
}

/// A vertical list that scrolls past `maxHeight`, its scroller a thin knob in the theme's
/// dim color, shown while scrolling.
final class ScrollList: NSScrollView {
    let maxHeight: CGFloat
    var spacing: CGFloat = 4
    private let rows = FlippedView()
    private let scroller = ThemedScroller()

    init(maxHeight: CGFloat) {
        self.maxHeight = maxHeight
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        verticalScroller = scroller
        scrollerStyle = .overlay
        autohidesScrollers = true
        verticalScrollElasticity = .none
        documentView = rows
    }

    required init?(coder: NSCoder) { fatalError() }

    var theme = Theme.fallback { didSet { scroller.color = theme.dim.nsColor } }

    /// Stacks `views`, each its height, the width of the list, and returns the list's height.
    @discardableResult func set(_ views: [(view: NSView, height: CGFloat)], width: CGFloat) -> CGFloat {
        for view in rows.subviews where !views.contains(where: { $0.view === view }) { view.removeFromSuperview() }
        var y: CGFloat = 0
        for (index, (view, height)) in views.enumerated() {
            if index > 0 { y += spacing }
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            if view.superview !== rows { rows.addSubview(view) }
            y += height
        }
        rows.frame = NSRect(x: 0, y: 0, width: width, height: y)
        return min(y, maxHeight)
    }

    /// Keeps `view` in sight, as a row that opened its password field.
    func reveal(_ view: NSView) { rows.scrollToVisible(view.frame) }
}

private final class ThemedScroller: NSScroller {
    var color = NSColor.gray

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob).insetBy(dx: 4, dy: 2)
        color.setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }
}

/// A password field on a rounded fill with the accent's border. Return submits and Escape
/// cancels. A click in it asks for the keyboard first, as the panel takes key only while
/// someone types (docs/network.md, the panel's focus).
final class PasswordField: FlippedView, NSTextFieldDelegate {
    var submitted: ((String) -> Void)?
    var cancelled: (() -> Void)?
    var wantsKeyboard: (() -> Void)?
    var theme = Theme.fallback { didSet { style() } }
    let field = SecureField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = panelFont(11.5)
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.clicked = { [weak self] in self?.wantsKeyboard?() }
        addSubview(field)
        style()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func style() {
        field.textColor = theme.foreground.nsColor
        field.caret = theme.foreground.nsColor
        field.placeholderAttributedString = NSAttributedString(string: "Password", attributes: [
            .font: panelFont(11.5), .foregroundColor: theme.dim.nsColor,
        ])
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let height = ceil(field.cell?.cellSize.height ?? 16)
        field.frame = NSRect(x: 8, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 16, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        theme.foreground.with(alpha: 0.06).nsColor.setFill()
        box.fill()
        theme.accent.nsColor.setStroke()
        box.lineWidth = 1
        box.stroke()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if !field.stringValue.isEmpty { submitted?(field.stringValue) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelled?()
            return true
        default: return false
        }
    }

    /// The secure field, which turns on Secure Input while it holds the keyboard, as Kosmos's
    /// log showed (docs/network.md, the panel's focus).
    final class SecureField: NSSecureTextField {
        var clicked: (() -> Void)?
        var caret = NSColor.white

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            clicked?()
            super.mouseDown(with: event)
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            (currentEditor() as? NSTextView)?.insertionPointColor = caret
            return became
        }
    }
}
