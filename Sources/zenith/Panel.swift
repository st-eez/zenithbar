import AppKit
import ZenithCore
import ZenithKit

/// A plugin item's or the network item's panel, under the item: its page's title, the tabs
/// naming the other pages, and its rows, drawn when it opens and when what it shows changes
/// (docs/plugins.md, docs/network.md). Above apps' windows and the bar, at a level of its
/// own, as a window at the bar's level that takes a click comes up over the bar
/// (docs/overview.md, clicks).
@MainActor final class Popup {
    let panel: BarPanel
    private let view: PopupView
    /// The item it shows, and on which display.
    private(set) var shown: (key: String, display: CGDirectDisplayID)?

    init(selected: @escaping @MainActor (Int) -> Void, exited: @escaping @MainActor () -> Void) {
        view = PopupView(selected: selected, exited: exited)
        panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        panel.contentView = view
    }

    /// Shows `page` of `item` under `anchor`, the item's frame on screen, its right edge on the
    /// item's and kept on `screen`.
    /// `icon`, when given, shows in place of the item's glyph, as the network's SF Symbol.
    func show(_ item: PluginItem, page: Int, key: String, display: CGDirectDisplayID, anchor: NSRect, screen: NSRect,
              theme: Theme, icon: NSImage? = nil) {
        view.item = item
        view.icon = icon
        view.page = page
        view.theme = theme
        let size = view.size
        let x = min(max(anchor.maxX - size.width, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x, y: anchor.minY - 4 - size.height, width: size.width, height: size.height), display: false)
        view.needsDisplay = true
        shown = (key, display)
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        shown = nil
    }
}

private final class PopupView: NSView {
    var item: PluginItem?
    var icon: NSImage?
    var page = 0
    var theme = Theme.fallback
    private let selected: @MainActor (Int) -> Void
    private let exited: @MainActor () -> Void
    /// Each tab's span, for a click on one.
    private var tabs: [ClosedRange<CGFloat>] = []

    // The geometry and fonts of Steve's SketchyBar agents panel.
    private static let pad: CGFloat = 10, rowHeight: CGFloat = 23, noteHeight: CGFloat = 14
    /// Above a caption that follows other rows, so a group's last note stays clear of the next
    /// group's heading.
    private static let captionGap: CGFloat = 6
    private static let titleWidth: CGFloat = 128, meterWidth: CGFloat = 170, valueWidth: CGFloat = 62
    private static let width = 2 * pad + titleWidth + meterWidth + valueWidth

    init(selected: @escaping @MainActor (Int) -> Void, exited: @escaping @MainActor () -> Void) {
        self.selected = selected
        self.exited = exited
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseExited(with event: NSEvent) { exited() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= Self.pad + Self.rowHeight, point.y < Self.pad + 2 * Self.rowHeight,
              let tab = tabs.firstIndex(where: { $0.contains(point.x) }) else { return }
        selected(tab)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item, let current else { return }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        theme.background.nsColor.setFill()
        outline.fill()
        theme.accent.nsColor.setStroke()
        outline.lineWidth = 2
        outline.stroke()

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
        let font = NSFont(name: bold ? "JetBrainsMonoNF-Bold" : "JetBrainsMonoNF-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color.nsColor])
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
}
