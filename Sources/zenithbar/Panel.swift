import AppKit
import ZenithBarCore
import ZenithBarKit

/// A plugin item's or the network item's panel, under the item: a plugin's page drawn as rows,
/// or a view of controls, as the network panel's (docs/plugins.md, docs/network.md). Above
/// apps' windows and the bar, at a level of its own, as a window at the bar's level that takes
/// a click comes up over the bar (docs/overview.md, clicks).
@MainActor final class Popup {
    let panel: PopupPanel
    private let chrome: PopupChrome
    private let pages: PopupView
    /// The item it shows, and on which display.
    private(set) var shown: (key: String, display: CGDirectDisplayID)?
    /// The item's frame and its screen's, which the panel's place follows.
    private var place: (anchor: NSRect, screen: NSRect)?
    /// Called when a view `show` was given stops showing.
    private var closed: (() -> Void)?
    /// While the panel gives the keyboard back, when its resigning key is no click elsewhere.
    private var releasing = false

    init(selected: @escaping @MainActor (Int) -> Void, exited: @escaping @MainActor () -> Void) {
        pages = PopupView(selected: selected)
        chrome = PopupChrome(exited: exited)
        panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        panel.contentView = chrome
        // A click in another app's window takes the keyboard from the password field, and the
        // panel closes unless the pointer is on it.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in onMain { if self?.releasing == false { exited() } }
        }
    }

    /// Shows `page` of `item` under `anchor`, the item's frame on screen, its right edge on the
    /// item's and kept on `screen`.
    /// `icon`, when given, shows in place of the item's glyph, as the network's SF Symbol, a
    /// bitmap cropped to its ink (`inkImage`), as a symbol drawn into a rect of its size stretches.
    func show(_ item: PluginItem, page: Int, key: String, display: CGDirectDisplayID, anchor: NSRect, screen: NSRect,
              theme: Theme, icon: NSImage? = nil) {
        pages.item = item
        pages.icon = icon
        pages.page = page
        pages.theme = theme
        pages.frame.size = pages.size
        pages.needsDisplay = true
        show(pages, key: key, display: display, anchor: anchor, screen: screen, theme: theme)
    }

    /// Shows `content` at its frame's size; `closed` is called when it stops showing.
    func show(_ content: NSView, key: String, display: CGDirectDisplayID, anchor: NSRect, screen: NSRect, theme: Theme,
              closed: (() -> Void)? = nil) {
        if let shown, shown.key != key || chrome.content !== content { finish() }
        self.closed = closed
        chrome.theme = theme
        chrome.content = content
        panel.appearance = NSAppearance(named: theme.background.isDark ? .darkAqua : .aqua)
        place = (anchor, screen)
        fit()
        shown = (key, display)
        panel.orderFrontRegardless()
    }

    /// Places the panel for its content's size, its top kept under the item, as when the
    /// network list comes in or a password field opens.
    func fit() {
        guard let place, let content = chrome.content else { return }
        let size = content.frame.size
        let x = min(max(place.anchor.maxX - size.width, place.screen.minX + 4), place.screen.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x, y: place.anchor.minY - 4 - size.height, width: size.width, height: size.height),
                       display: true)
        content.frame = chrome.bounds
        chrome.needsDisplay = true
    }

    func close() {
        giveKeyboardBack(reorder: false)
        panel.orderOut(nil)
        finish()
    }

    private func finish() {
        shown = nil
        let closed = self.closed
        self.closed = nil
        closed?()
    }

    /// Whether someone is typing in it, when the pointer leaving keeps it open.
    var typing: Bool { panel.isKeyWindow }

    /// Makes the panel key with `field` taking keys, without activating ZenithBar: the front
    /// app stays front and WindowServer sends keys to ZenithBar (docs/network.md, the panel's
    /// focus).
    func takeKeyboard(for field: NSView) {
        panel.allowsKey = true
        panel.makeKey()
        panel.makeFirstResponder(field)
    }

    /// Gives keys back to the front app's window. Nothing public hands key to another app, so
    /// the panel orders out and in again with key refused, which the probe found returns keys
    /// to the front app (docs/network.md, the panel's focus).
    func giveKeyboardBack(reorder: Bool = true) {
        panel.allowsKey = false
        guard panel.isKeyWindow else { return }
        releasing = true
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        if reorder { panel.orderFrontRegardless() }
        DispatchQueue.main.async { [weak self] in onMain { self?.releasing = false } }
    }
}

/// A panel that takes key only while asked to, for a field someone types in.
final class PopupPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// The panel's fill and its accent border, with its content inside, and the pointer leaving it.
private final class PopupChrome: FlippedView {
    var theme = Theme.fallback
    var content: NSView? {
        didSet {
            guard content !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let content { addSubview(content) }
        }
    }
    private let exited: @MainActor () -> Void

    init(exited: @escaping @MainActor () -> Void) {
        self.exited = exited
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseExited(with event: NSEvent) { exited() }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        theme.background.nsColor.setFill()
        outline.fill()
        theme.accent.nsColor.setStroke()
        outline.lineWidth = 2
        outline.stroke()
    }
}

private final class PopupView: NSView {
    var item: PluginItem?
    var icon: NSImage?
    var page = 0
    var theme = Theme.fallback
    private let selected: @MainActor (Int) -> Void
    /// Each tab's span, for a click on one.
    private var tabs: [ClosedRange<CGFloat>] = []

    // The geometry and fonts of Steve's SketchyBar agents panel.
    private static let pad: CGFloat = 10, rowHeight: CGFloat = 23, noteHeight: CGFloat = 14
    /// Above a caption that follows other rows, so a group's last note stays clear of the next
    /// group's heading.
    private static let captionGap: CGFloat = 6
    private static let titleWidth: CGFloat = 128, meterWidth: CGFloat = 170, valueWidth: CGFloat = 62
    private static let width = 2 * pad + titleWidth + meterWidth + valueWidth

    init(selected: @escaping @MainActor (Int) -> Void) {
        self.selected = selected
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var current: PluginItem.Page? { item.flatMap { $0.pages.indices.contains(page) ? $0.pages[page] : $0.pages.first } }

    var size: NSSize {
        guard let current, let item else { return .zero }
        let rows = current.rows.enumerated().reduce(CGFloat(0)) { height, row in height + Self.height(row.element, at: row.offset) }
        return NSSize(width: Self.width, height: Self.pad + Self.rowHeight * (item.pages.count > 1 ? 2 : 1) + rows + Self.pad)
    }

    private static func height(_ row: PluginItem.Row, at index: Int) -> CGFloat {
        switch row {
        case .note: noteHeight
        case .caption: rowHeight + (index > 0 ? captionGap : 0)
        case .meter: rowHeight
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= Self.pad + Self.rowHeight, point.y < Self.pad + 2 * Self.rowHeight,
              let tab = tabs.firstIndex(where: { $0.contains(point.x) }) else { return }
        selected(tab)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item, let current else { return }

        let pad = Self.pad
        var top = pad
        let iconWidth: CGFloat
        if let icon {
            icon.draw(in: NSRect(x: pad, y: top + (Self.rowHeight - icon.size.height) / 2, width: icon.size.width,
                                 height: icon.size.height), from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
            iconWidth = icon.size.width
        } else {
            // Placed by its ink, as the robot glyph draws past its advance.
            let glyph = text(item.icon, size: 13, bold: true, color: theme.accent), ink = inkBounds(glyph)
            draw(glyph, x: pad - ink.minX, top: top, height: Self.rowHeight)
            iconWidth = ink.width
        }
        draw(text(current.title, size: 11.5, bold: true, color: theme.foreground), x: pad + iconWidth + 6, top: top,
             height: Self.rowHeight)
        top += Self.rowHeight
        tabs = []
        if item.pages.count > 1 {
            var x = pad
            for (index, page) in item.pages.enumerated() {
                let tab = text((index == self.page ? "● " : "○ ") + page.tab, size: 11.5, color: theme.dim)
                draw(tab, x: x, top: top, height: Self.rowHeight)
                tabs.append(x...(x + tab.size().width))
                x += tab.size().width + 24
            }
            top += Self.rowHeight
        }
        let now = Date()
        for (index, row) in current.rows.enumerated() {
            switch row {
            case let .caption(caption):
                if index > 0 { top += Self.captionGap }
                draw(text(caption, size: 9.5, color: theme.dim), x: pad, top: top, height: Self.rowHeight)
                top += Self.rowHeight
            case let .meter(label, value, detail, tone, bold):
                draw(text(label, size: 11.5, bold: bold, color: tone == .dim ? theme.dim : theme.foreground), x: pad, top: top,
                     height: Self.rowHeight)
                let track = NSRect(x: pad + Self.titleWidth, y: top + Self.rowHeight / 2 - 2, width: Self.meterWidth - 12, height: 4)
                theme.foreground.with(alpha: 0.08).nsColor.setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                (tone == .alert ? theme.alert : theme.accent).nsColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(4, track.width * value), height: 4),
                             xRadius: 2, yRadius: 2).fill()
                let value = text(detail, size: 11.5, bold: bold, color: tone == .alert ? theme.alert : theme.foreground)
                draw(value, x: bounds.width - pad - value.size().width, top: top, height: Self.rowHeight)
                top += Self.rowHeight
            case let .note(note, until, since, detail, tone):
                let color = switch tone {
                case .alert, .warning: theme.alert
                case .normal: theme.foreground
                case .dim: theme.dim
                }
                draw(text(noteText(note, until: until, since: since, detail: detail, now: now), size: 9.5, color: color), x: pad,
                     top: top, height: Self.noteHeight)
                top += Self.noteHeight
            }
        }
    }

    private func text(_ string: String, size: CGFloat, bold: Bool = false, color: RGBA) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: panelFont(size, bold: bold), .foregroundColor: color.nsColor])
    }

    /// Draws `text` with its capitals and figures centered in the row, as the bar centers its
    /// items. In a flipped view AppKit draws a line's top at the point, its ascender above the
    /// baseline.
    private func draw(_ text: NSAttributedString, x: CGFloat, top: CGFloat, height: CGFloat) {
        guard let font = text.firstFont else { return }
        text.draw(at: NSPoint(x: x, y: (top + height / 2 + font.capHeight / 2 - font.ascender).rounded()))
    }
}

extension RGBA {
    func with(alpha: Double) -> RGBA {
        var color = self
        color.alpha = alpha
        return color
    }

    /// Whether text on it should be light, by its relative luminance.
    var isDark: Bool { 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5 }
}
