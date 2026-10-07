// Native popups from a bar panel (docs/plugins.md).
//
//   zenithbar-probe popups [seconds]
//       A small probe bar in the middle of the display under the pointer, a nonactivating panel as ZenithBar's
//       bars are, with two items: Popover opens an NSPopover, the system's bubble with an
//       arrow, holding a mock of the agents panel; Menu pops up an NSMenu with the same data as
//       a native menu, a meter in a custom view among its items. Logs whether each opening made
//       the probe the front app. Default: 120 s.
import AppKit

private final class PopupBar: NSView {
    var clicked: ((String, NSRect) -> Void)?
    let items = ["Popover", "Menu"]

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func frame(of index: Int) -> NSRect { NSRect(x: 12 + CGFloat(index) * 110, y: 0, width: 100, height: bounds.height) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        for (index, item) in items.enumerated() {
            let text = NSAttributedString(string: "▾ " + item, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
            ])
            text.draw(at: NSPoint(x: frame(of: index).minX + 10, y: (bounds.height - text.size().height) / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = items.indices.first(where: { frame(of: $0).contains(point) }) { clicked?(items[index], frame(of: index)) }
    }
}

/// A row of the mock agents panel: a label, a bar and a value.
@MainActor private func meterRow(_ label: String, _ value: Double, _ detail: String, width: CGFloat = 280) -> NSView {
    let name = NSTextField(labelWithString: label)
    name.font = .systemFont(ofSize: 12, weight: .medium)
    let bar = NSProgressIndicator()
    bar.isIndeterminate = false
    bar.style = .bar
    bar.controlSize = .small
    bar.doubleValue = value * 100
    let amount = NSTextField(labelWithString: detail)
    amount.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    amount.alignment = .right
    let row = NSStackView(views: [name, bar, amount])
    row.spacing = 10
    name.widthAnchor.constraint(equalToConstant: 80).isActive = true
    amount.widthAnchor.constraint(equalToConstant: 56).isActive = true
    row.widthAnchor.constraint(equalToConstant: width).isActive = true
    return row
}

@MainActor private func caption(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 10, weight: .semibold)
    label.textColor = .secondaryLabelColor
    return label
}

@MainActor private func popoverContent() -> NSViewController {
    let title = NSTextField(labelWithString: "Claude Code  ·  Max 20x")
    title.font = .systemFont(ofSize: 13, weight: .bold)
    let tabs = NSSegmentedControl(labels: ["Claude Code", "Codex"], trackingMode: .selectOne, target: nil, action: nil)
    tabs.selectedSegment = 0
    tabs.controlSize = .small
    let footer = NSTextField(labelWithString: "Updated just now  ·  2 devices  ·  343 sessions")
    footer.font = .systemFont(ofSize: 10)
    footer.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [
        title, tabs, caption("LIMITS"), meterRow("Session", 0.10, "10%"), meterRow("Weekly", 0.26, "26%"),
        caption("TOKENS BY DAY"), meterRow("Mon", 0.26, "1.4B"), meterRow("Today", 0.15, "803.8M"),
        caption("TOKENS BY MODEL"), meterRow("Opus 5.5", 1, "21.4B"), meterRow("Fable 5", 0.56, "12.0B"), footer,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    let controller = NSViewController()
    controller.view = stack
    return controller
}

@MainActor private func menu() -> NSMenu {
    let menu = NSMenu()
    let header = NSMenuItem(title: "Claude Code  ·  Max 20x", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())
    for (label, value, detail) in [("Session", 0.10, "10%"), ("Weekly", 0.26, "26%")] {
        let item = NSMenuItem()
        let view = meterRow(label, value, detail, width: 260)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 24))
        view.frame = NSRect(x: 16, y: 2, width: 260, height: 20)
        holder.addSubview(view)
        item.view = holder
        menu.addItem(item)
    }
    menu.addItem(.separator())
    let claude = NSMenuItem(title: "Claude Code", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    claude.state = .on
    claude.target = nil
    claude.action = nil
    menu.addItem(claude)
    menu.addItem(NSMenuItem(title: "Codex", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    let refresh = NSMenuItem(title: "Refresh Now", action: nil, keyEquivalent: "r")
    menu.addItem(refresh)
    let models = NSMenuItem(title: "Tokens by Model", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    for line in ["Opus 5.5    21.4B", "Opus 5    14.7B", "Fable 5    12.0B"] { sub.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: "")) }
    models.submenu = sub
    menu.addItem(models)
    return menu
}

@MainActor func popups(seconds: Double) -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.screens[0]
    let size = NSSize(width: 236, height: 26)
    let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY + 200, width: size.width, height: size.height)
    let bar = BarPanel(frame: frame, level: .statusBar, behavior: [.canJoinAllSpaces, .stationary])
    let view = PopupBar(frame: NSRect(origin: .zero, size: size))
    bar.contentView = view
    bar.orderFrontRegardless()
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = popoverContent()
    view.clicked = { item, rect in
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        if item == "Popover" {
            if popover.isShown { popover.close() } else { popover.show(relativeTo: rect, of: view, preferredEdge: .minY) }
        } else {
            menu().popUp(positioning: nil, at: NSPoint(x: rect.minX, y: -4), in: view)
        }
        let now = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        print("\(item): front app \(front == now ? "unchanged, \(now)" : "changed from \(front) to \(now)")")
    }
    print("Click Popover or Menu on the probe bar on \(screen.localizedName); it closes after \(Int(seconds)) s.")
    pumpEvents(seconds)
    exit(0)
}
