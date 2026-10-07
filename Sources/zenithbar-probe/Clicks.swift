// Which window takes a click on a bar's parts (docs/overview.md).
//
//   zenithbar-probe clicks
//       A probe bar in the middle of the built-in display, a tab with flared corners whose
//       clear areas outside the outline show a catcher window of the probe's behind it, both
//       nonactivating panels at the status level. Posts left clicks through the HID tap on an
//       item, on the bar's fill, on its clear corners and on the catcher alone, and reports
//       which window took each, whether the front app changed, and whether the two windows
//       swapped order. Moves the pointer and puts it back. Needs Accessibility for the host
//       terminal, to post the clicks.
import AppKit

/// A view that records each mouse down it receives, in its own coordinates.
private final class Recorder: NSView {
    var downs: [CGPoint] = []
    override func mouseDown(with event: NSEvent) { downs.append(convert(event.locationInWindow, from: nil)) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor func clicks() -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let screen = builtInScreen()
    let width: CGFloat = 400, height: CGFloat = 40, flare: CGFloat = 20, radius: CGFloat = 12
    let size = NSSize(width: width + 2 * flare, height: height)
    let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY, width: size.width, height: size.height)
    let catcher = BarPanel(frame: frame.insetBy(dx: -40, dy: -40), level: .statusBar, behavior: [.canJoinAllSpaces])
    let catcherView = Recorder()
    catcherView.wantsLayer = true
    catcherView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.5).cgColor
    catcher.contentView = catcherView
    catcher.orderFrontRegardless()

    let bar = BarPanel(frame: frame, level: .statusBar, behavior: [.canJoinAllSpaces])
    let barView = Recorder()
    barView.wantsLayer = true
    let fill = CAShapeLayer()
    fill.path = tabPath(width: width, height: height, flare: flare, radius: radius)
    fill.fillColor = NSColor(white: 0.1, alpha: 0.9).cgColor
    barView.layer?.addSublayer(fill)
    let item = CALayer()
    item.frame = CGRect(x: flare + 20, y: 8, width: 60, height: height - 16)
    item.backgroundColor = NSColor.systemBlue.cgColor
    item.cornerRadius = 6
    barView.layer?.addSublayer(item)
    bar.contentView = barView
    bar.orderFrontRegardless()
    pumpEvents(0.5)

    let targets: [(String, CGPoint, NSWindow)] = [
        ("item", CGPoint(x: item.frame.midX, y: item.frame.midY), bar),
        ("fill", CGPoint(x: flare + width / 2, y: height / 2), bar),
        // Inside the circle the top left flare carves away, so outside the outline.
        ("flare carve", CGPoint(x: flare * 0.25, y: height - flare * 0.75), bar),
        // Outside the bottom right corner's radius.
        ("corner carve", CGPoint(x: flare + width - 2, y: 2), bar),
        ("catcher", CGPoint(x: 20, y: 20), catcher),
    ]
    let home = CGEvent(source: nil)?.location ?? .zero
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
    let order = { () -> String in
        let ids = onScreenOrder()
        guard let b = ids.firstIndex(of: bar.id), let c = ids.firstIndex(of: catcher.id) else { return "missing" }
        return b < c ? "bar over catcher" : "CATCHER over bar"
    }
    print("front app \(front), \(order())")
    for (name, point, window) in targets {
        let before = (barView.downs.count, catcherView.downs.count)
        let location = globalPoint(point, in: window)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            pumpEvents(0.05)
        }
        pumpEvents(0.3)
        let taker = barView.downs.count > before.0 ? "bar" : catcherView.downs.count > before.1 ? "catcher" : "neither"
        let nowFront = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        print("\(name): taken by \(taker), front app \(nowFront == front ? "unchanged" : "now \(nowFront)"), \(order()), "
            + "bar key \(bar.isKeyWindow)")
    }
    CGWarpMouseCursorPosition(home)
    exit(0)
}
