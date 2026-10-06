// Where a bar window joined to every Space shows (docs/overview.md).
//
//   zenith-probe watch [seconds]
//       A probe bar along the top of every display, joined to every Space, at SketchyBar's
//       level kCGBackstopMenuLevel. Every 100 ms reads whether
//       WindowServer has each bar on screen and in which Spaces, the active Space, the front
//       app, and MenuBarAgent's windows, and logs each change. Switch workspaces, open
//       Mission Control, enter native fullscreen and reveal the hidden menu bar while it runs.
//       Default: 120 s.
import AppKit
import CZenith

@MainActor func watch(seconds: Double) -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
    let bars = NSScreen.screens.map { screen -> (String, BarPanel) in
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - 28, width: screen.frame.width, height: 28)
        let bar = BarPanel(frame: frame, level: windowLevel, behavior: behavior)
        let view = layerView(NSRect(origin: .zero, size: frame.size))
        view.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.85).cgColor
        let label = CATextLayer()
        label.string = "zenith-probe watch"
        label.fontSize = 13
        label.alignmentMode = .center
        label.contentsScale = screen.backingScaleFactor
        label.frame = CGRect(x: 0, y: 6, width: frame.width, height: 18)
        view.layer?.addSublayer(label)
        bar.contentView = view
        bar.orderFrontRegardless()
        return (screen.localizedName, bar)
    }
    print("level \(windowLevel.rawValue), behavior \(behavior.rawValue), \(bars.count) bars: "
        + bars.map { "\($0.0) window \($0.1.id)" }.joined(separator: ", "))
    let start = ContinuousClock.now
    var last: [String] = []
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated {
            var lines = bars.map { name, bar in
                "\(name): \(isOnScreen(bar.id) ? "on screen" : "OFF screen"), spaces \(spaces(of: bar.id))"
            }
            lines.append("active space \(SLSGetActiveSpace(SLSMainConnectionID())), front "
                + (NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"))
            let menuBar = ((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [])
                .filter { $0[kCGWindowOwnerName as String] as? String == "MenuBarAgent" }
                .map { row -> String in
                    let bounds = (row[kCGWindowBounds as String] as? NSDictionary)
                        .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
                    let shown = (row[kCGWindowIsOnscreen as String] as? Bool) == true ? "on" : "off"
                    return "\(row[kCGWindowNumber as String] ?? "?") layer \(row[kCGWindowLayer as String] ?? "?") "
                        + "\(shown) alpha \(row[kCGWindowAlpha as String] ?? "?") y \(Int(bounds.minY)) h \(Int(bounds.height))"
                }
            lines.append("MenuBarAgent: " + menuBar.joined(separator: "; "))
            for (index, line) in lines.enumerated() where index >= last.count || last[index] != line {
                print("\(stamp(start))  \(line)")
            }
            last = lines
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    pumpEvents(seconds)
    exit(0)
}
