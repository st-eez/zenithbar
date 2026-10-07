// The native menu bar's status items, read from outside the apps that own them (docs/tray.md).
//
//   zenithbar-probe tray list [runs]
//       Reads the status items two ways through Accessibility: each running app's
//       AXExtrasMenuBar, and MenuBarAgent's windows, one per display. Prints every item with
//       its owner, its text and its frame, then times each read `runs` times (default 5),
//       with MenuBarAgent's CPU over those reads.
//   zenithbar-probe tray capture [runs]
//       Captures each of MenuBarAgent's windows with ScreenCaptureKit, `runs` times (default 5),
//       and reports for every item whether the capture holds anything drawn at its frame.
//       Writes the last captures to /tmp/zenithbar-probe-tray.
//   zenithbar-probe tray watch [seconds] [own]
//       Registers for Accessibility notifications on MenuBarAgent, its windows and items, and
//       on every status item app's extras menu bar and items, and logs each one that arrives.
//       Every second reads MenuBarAgent's items and captures its windows, and logs what
//       changed, to compare with the notifications. With `own`, the probe adds a status item
//       of its own at 3 s, swaps its template image at 8 s, widens it at 13 s, gives it a
//       colored image at 18 s and removes it at 23 s. Default: 30 s.
//   zenithbar-probe tray cost [seconds]
//       Polls once a second for `seconds` each (default 20): nothing, MenuBarAgent's frames and
//       owners, the same with each item's text, a capture of one MenuBarAgent window from a
//       window list read once, nothing again, and nothing while registered for MenuBarAgent's
//       notifications. Reports the CPU each costs MenuBarAgent, WindowServer and the probe.
//   zenithbar-probe tray press <bundle id>
//       Presses the app's first status item through Accessibility, logs the windows that open
//       and whether the top of the display changes, as when the hidden menu bar shows, then
//       cancels the menu. Press only an item whose click opens a menu and changes nothing.
@preconcurrency import ApplicationServices
import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor func tray(_ arguments: [String]) {
    guard let agent = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == agentBundle }) else {
        print("MenuBarAgent is not running")
        exit(1)
    }
    _ = NSApplication.shared
    print("menu bar hidden (_HIHideMenuBar): \(UserDefaults.standard.bool(forKey: "_HIHideMenuBar"))")
    switch arguments.first {
    case "list": trayList(agent: agent.processIdentifier, runs: arguments.dropFirst().first.flatMap(Int.init) ?? 5)
    case "capture": trayCapture(agent: agent.processIdentifier, runs: arguments.dropFirst().first.flatMap(Int.init) ?? 5)
    case "watch":
        trayWatch(agent: agent.processIdentifier, seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 30,
                  own: arguments.contains("own"))
    case "cost": trayCost(agent: agent.processIdentifier, seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 20)
    case "press" where arguments.count == 2: trayPress(bundle: arguments[1])
    default: usage()
    }
    exit(0)
}

private let agentBundle = "com.apple.MenuBarAgent"

// MARK: Reading through Accessibility

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

private func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
    (attribute(element, name) as? [AXUIElement]) ?? []
}

private func frame(of element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute)
    else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
}

private func owner(of element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
}

/// An element's role and the text Accessibility gives it, on one line.
private func describe(_ element: AXUIElement) -> String {
    var parts = [attribute(element, kAXRoleAttribute) as? String ?? "?"]
    for name in [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute] {
        guard let value = attribute(element, name) else { continue }
        let text = "\(value)".replacingOccurrences(of: "\n", with: " / ")
        if !text.isEmpty { parts.append("\(name.dropFirst(2).lowercased())=\"\(text)\"") }
    }
    return parts.joined(separator: " ")
}

private func appName(_ pid: pid_t) -> String {
    let app = NSRunningApplication(processIdentifier: pid)
    return app?.bundleIdentifier ?? app?.localizedName ?? "pid \(pid)"
}

private func show(_ rect: CGRect?) -> String {
    rect.map { "(\(Int($0.minX)), \(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "(no frame)"
}

/// An item as MenuBarAgent lists it: a slot in one display's bar window, whose frame is the
/// item's, holding the owner's element. The system items' text sits one level further in.
private struct AgentItem {
    let owner: pid_t
    let frame: CGRect
    let window: CGRect
    let text: String
    let element: AXUIElement

    var key: String { "\(appName(owner)) on \(show(window))" }
}

/// MenuBarAgent's items, with their text when `text` is set; without it only frames and owners.
private func agentItems(_ agent: AXUIElement, agentPID: pid_t, text: Bool) -> [AgentItem] {
    children(agent, kAXWindowsAttribute).flatMap { window -> [AgentItem] in
        let windowFrame = frame(of: window) ?? .zero
        return children(window).compactMap { slot in
            guard let slotFrame = frame(of: slot), let inner = children(slot).first else { return nil }
            let pid = owner(of: inner)
            let element = pid == agentPID ? children(inner).first ?? inner : inner
            return AgentItem(owner: pid, frame: slotFrame, window: windowFrame, text: text ? describe(element) : "",
                             element: element)
        }
    }
}

/// One app's status items as the app lists them under AXExtrasMenuBar, with the read's time
/// and result.
private struct AppRead {
    let pid: pid_t
    let result: AXError
    let ms: Double
    let items: [(text: String, frame: CGRect?)]
}

/// The items of the apps `only` names, or of every running app.
private func appItems(timeout: Float, only: Set<pid_t>? = nil) -> [AppRead] {
    NSWorkspace.shared.runningApplications.filter { only?.contains($0.processIdentifier) ?? true }.map { app in
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, timeout)
        let start = ContinuousClock.now
        var bar: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXExtrasMenuBarAttribute as CFString, &bar)
        let items = result == .success ? children(bar as! AXUIElement).map { (describe($0), frame(of: $0)) } : []
        return AppRead(pid: app.processIdentifier, result: result, ms: milliseconds(since: start), items: items)
    }
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func spread(_ values: [Double]) -> String {
    let sorted = values.sorted()
    return String(format: "min %.1f, median %.1f, max %.1f ms", sorted.first ?? 0, sorted[sorted.count / 2],
                  sorted.last ?? 0)
}

// MARK: list

@MainActor private func trayList(agent agentPID: pid_t, runs: Int) {
    let agent = AXUIElementCreateApplication(agentPID)
    let reads = appItems(timeout: 0.25)
    print("\n== each app's AXExtrasMenuBar (\(reads.count) running apps, 0.25 s timeout each)")
    for read in reads where !read.items.isEmpty {
        for item in read.items { print("  \(appName(read.pid))  \(show(item.frame))  \(item.text)") }
    }
    let failed = Dictionary(grouping: reads.filter { $0.result != .success }, by: \.result.rawValue)
    print("  apps with items: \(reads.filter { !$0.items.isEmpty }.count); errors by AXError: "
        + failed.map { "\($0.key): \($0.value.count)" }.joined(separator: ", "))
    print("  slowest: " + reads.sorted { $0.ms > $1.ms }.prefix(6)
        .map { String(format: "%@ %.0f ms (%d)", appName($0.pid), $0.ms, $0.result.rawValue) }.joined(separator: ", "))

    print("\n== MenuBarAgent's windows")
    for (window, items) in Dictionary(grouping: agentItems(agent, agentPID: agentPID, text: true), by: \.window)
        .sorted(by: { $0.key.minX < $1.key.minX }) {
        print("  window \(show(window))")
        for item in items.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            print("    \(appName(item.owner))  \(show(item.frame))  \(item.text)")
        }
    }
    let windows = ((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == agentPID }
    print("  window list: " + windows.map { row in
        "\(row[kCGWindowNumber as String] ?? "?") on screen \(row[kCGWindowIsOnscreen as String] as? Bool ?? false)"
    }.joined(separator: ", "))

    let owners = Set(reads.filter { !$0.items.isEmpty }.map(\.pid))
    print("\n== timings over \(runs) runs, with MenuBarAgent's CPU a read")
    let kinds: [(String, () -> Void)] = [
        ("every app's AXExtrasMenuBar", { _ = appItems(timeout: 0.25) }),
        ("AXExtrasMenuBar of the apps with items", { _ = appItems(timeout: 0.25, only: owners) }),
        ("MenuBarAgent, frames and owners", { _ = agentItems(agent, agentPID: agentPID, text: false) }),
        ("MenuBarAgent, with text", { _ = agentItems(agent, agentPID: agentPID, text: true) }),
    ]
    for (name, read) in kinds {
        let cpu = rusageCPU(agentPID) ?? 0
        let times = (0..<runs).map { _ in
            let start = ContinuousClock.now
            read()
            return milliseconds(since: start)
        }
        print("  \(name): \(spread(times)); MenuBarAgent "
            + String(format: "%.1f ms", ((rusageCPU(agentPID) ?? 0) - cpu) / Double(runs)))
    }
}

// MARK: capture

/// MenuBarAgent's windows as ScreenCaptureKit lists them, with the time the list took.
private func agentWindows(_ agentPID: pid_t) -> ([SCWindow], Double) {
    let start = ContinuousClock.now, done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var content: SCShareableContent?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { result, _ in
        content = result
        done.signal()
    }
    done.wait()
    let windows = content?.windows.filter { $0.owningApplication?.processID == agentPID } ?? []
    return (windows, milliseconds(since: start))
}

/// A capture of `window` alone, wherever it is and whether or not it shows, at 2 pixels a point.
private func capture(_ window: SCWindow) -> (Capture?, CGImage?) {
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width * 2)
    configuration.height = Int(window.frame.height * 2)
    configuration.showsCursor = false
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var image: CGImage?
    SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                     configuration: configuration) { result, error in
        if let error { print("  capture of window \(window.windowID) failed: \(error.localizedDescription)") }
        image = result
        done.signal()
    }
    done.wait()
    return (image.flatMap { Capture($0, origin: window.frame.origin, scale: 2) }, image)
}

/// Every item's ink in the capture of its window: the pixels not clear, and their hash.
private func inks(_ items: [AgentItem], _ captures: [(SCWindow, Capture?)]) -> [String: (pixels: Int, hash: Int)] {
    var result: [String: (pixels: Int, hash: Int)] = [:]
    for item in items {
        guard let shot = captures.first(where: { $0.0.frame.intersects(item.frame) })?.1 else { continue }
        result[item.key + " " + item.text] = shot.ink(in: item.frame)
    }
    return result
}

@MainActor private func trayCapture(agent agentPID: pid_t, runs: Int) {
    let agent = AXUIElementCreateApplication(agentPID)
    var listing: [Double] = [], shots: [Double] = []
    var last: [(SCWindow, Capture?, CGImage?)] = []
    for _ in 0..<runs {
        let (windows, ms) = agentWindows(agentPID)
        listing.append(ms)
        last = windows.map { window in
            let start = ContinuousClock.now
            let (shot, image) = capture(window)
            shots.append(milliseconds(since: start))
            return (window, shot, image)
        }
    }
    print("listing shareable content: \(spread(listing)); one window's capture: \(spread(shots))")
    let directory = URL(fileURLWithPath: "/tmp/zenithbar-probe-tray")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (window, _, image) in last {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { continue }
        try? png.write(to: directory.appendingPathComponent("\(window.windowID).png"))
        print("window \(window.windowID) \(show(window.frame)) on screen \(window.isOnScreen): wrote \(window.windowID).png")
    }
    let items = agentItems(agent, agentPID: agentPID, text: true)
    let ink = inks(items, last.map { ($0.0, $0.1) })
    for item in items.sorted(by: { ($0.window.minX, $0.frame.minX) < ($1.window.minX, $1.frame.minX) }) {
        let pixels = ink[item.key + " " + item.text]?.pixels ?? -1
        print("  \(pixels > 20 ? "drawn" : "BLANK")  \(pixels) px  \(appName(item.owner))  \(show(item.frame))  \(item.text)")
    }
}

// MARK: watch

nonisolated(unsafe) private var watchStart = ContinuousClock.now

private let notifications = [
    kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
    kAXValueChangedNotification, kAXTitleChangedNotification, kAXLayoutChangedNotification,
    kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
    kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXAnnouncementRequestedNotification,
]

private func observe(_ pid: pid_t, elements: [AXUIElement], into observers: inout [pid_t: AXObserver]) -> [String: Int] {
    if observers[pid] == nil {
        var observer: AXObserver?
        let created = AXObserverCreate(pid, { _, element, name, _ in
            print("\(stamp(watchStart))  AX \(name) from \(appName(owner(of: element))): \(describe(element)) "
                + show(frame(of: element)))
        }, &observer)
        guard created == .success, let observer else { return ["AXObserverCreate \(created.rawValue)": 1] }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }
    var results: [String: Int] = [:]
    for element in elements {
        for name in notifications {
            let result = AXObserverAddNotification(observers[pid]!, element, name as CFString, nil)
            results["\(name) \(result == .success ? "ok" : "\(result.rawValue)")", default: 0] += 1
        }
    }
    return results
}

/// Registers for every notification on MenuBarAgent, its windows, their slots and its own items.
private func observeAgent(_ agent: AXUIElement, agentPID: pid_t, into observers: inout [pid_t: AXObserver]) -> [String: Int] {
    let windows = children(agent, kAXWindowsAttribute)
    let items = agentItems(agent, agentPID: agentPID, text: false).filter { $0.owner == agentPID }.map(\.element)
    let bar = attribute(agent, kAXExtrasMenuBarAttribute) as! AXUIElement
    return observe(agentPID, elements: [agent, bar] + windows + windows.flatMap { children($0) } + items, into: &observers)
}

/// The probe's own status item and the steps `watch own` puts it through.
@MainActor private final class OwnItem {
    private var item: NSStatusItem?

    static func image(_ size: NSSize, template: Bool, draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = template
        return image
    }

    func step(_ second: Int) {
        switch second {
        case 3:
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.image = Self.image(NSSize(width: 16, height: 16), template: true) {
                NSBezierPath(ovalIn: $0.insetBy(dx: 1, dy: 1)).fill()
            }
            print("\(stamp(watchStart))  own item: added, a filled template circle")
        case 8:
            item?.button?.image = Self.image(NSSize(width: 16, height: 16), template: true) {
                NSBezierPath(rect: $0.insetBy(dx: 2, dy: 2)).fill()
            }
            print("\(stamp(watchStart))  own item: a filled template square, the same width")
        case 13:
            item?.button?.image = Self.image(NSSize(width: 40, height: 16), template: true) {
                NSBezierPath(rect: $0.insetBy(dx: 2, dy: 2)).fill()
            }
            print("\(stamp(watchStart))  own item: a template bar 40 pt wide")
        case 18:
            item?.button?.image = Self.image(NSSize(width: 40, height: 16), template: false) { rect in
                NSColor.systemRed.setFill()
                NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)).fill()
            }
            print("\(stamp(watchStart))  own item: a red bar, not a template")
        case 23:
            item.map(NSStatusBar.system.removeStatusItem)
            item = nil
            print("\(stamp(watchStart))  own item: removed")
        default: break
        }
    }
}

@MainActor private func trayWatch(agent agentPID: pid_t, seconds: Double, own: Bool) {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    let agent = AXUIElementCreateApplication(agentPID)
    var observers: [pid_t: AXObserver] = [:]
    var registered = observeAgent(agent, agentPID: agentPID, into: &observers)
    print("MenuBarAgent registrations: "
        + registered.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    registered = [:]
    for read in appItems(timeout: 0.25) where !read.items.isEmpty && read.pid != agentPID {
        let app = AXUIElementCreateApplication(read.pid)
        let bar = attribute(app, kAXExtrasMenuBarAttribute) as! AXUIElement
        registered.merge(observe(read.pid, elements: [app, bar] + children(bar), into: &observers), uniquingKeysWith: +)
    }
    print("status item apps: \(observers.count - 1); registrations: "
        + registered.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))

    watchStart = .now
    let ownItem = own ? OwnItem() : nil
    var lastItems: [String: String] = [:], lastInk: [String: (pixels: Int, hash: Int)] = [:]
    var second = 0, readTimes: [Double] = [], captureTimes: [Double] = []
    let cpuBefore = rusageCPU(agentPID)
    let timer = Timer(timeInterval: 1, repeats: true) { _ in
        MainActor.assumeIsolated {
            second += 1
            ownItem?.step(second)
            var start = ContinuousClock.now
            let items = agentItems(agent, agentPID: agentPID, text: true)
            readTimes.append(milliseconds(since: start))
            let now = Dictionary(items.map { ($0.key + " " + $0.text, show($0.frame)) }, uniquingKeysWith: { a, _ in a })
            for (key, place) in now where lastItems[key] != place {
                print("\(stamp(watchStart))  read: \(lastItems[key] == nil ? "new" : "moved") \(key) at \(place)")
            }
            for key in lastItems.keys where now[key] == nil { print("\(stamp(watchStart))  read: gone \(key)") }
            lastItems = now
            start = .now
            let captures = agentWindows(agentPID).0.map { ($0, capture($0).0) }
            captureTimes.append(milliseconds(since: start))
            let ink = inks(items, captures)
            for (key, value) in ink where lastInk[key] != nil && lastInk[key]!.hash != value.hash {
                print("\(stamp(watchStart))  capture: \(key) drew differently, \(lastInk[key]!.pixels) → \(value.pixels) px")
            }
            lastInk = ink
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    pumpEvents(seconds)
    print("read with text: \(spread(readTimes)); listing and capturing every window: \(spread(captureTimes))")
    if let before = cpuBefore, let after = rusageCPU(agentPID) {
        print(String(format: "MenuBarAgent CPU over %.0f s: %.0f ms", seconds, after - before))
    }
}

// MARK: cost

@MainActor private func trayCost(agent agentPID: pid_t, seconds: Double) {
    let agent = AXUIElementCreateApplication(agentPID)
    let server = pid(of: "WindowServer")!
    let window = agentWindows(agentPID).0.first { $0.frame.origin == .zero } ?? agentWindows(agentPID).0[0]
    let polls: [(name: String, poll: () -> Void)] = [
        ("nothing", {}),
        ("frames and owners", { _ = agentItems(agent, agentPID: agentPID, text: false) }),
        ("with text", { _ = agentItems(agent, agentPID: agentPID, text: true) }),
        ("capture of window \(window.windowID)", { _ = capture(window) }),
    ]
    /// CPU in ms of MenuBarAgent, WindowServer and the probe while `poll` runs once a second.
    func measure(_ poll: @escaping () -> Void, for stretch: Double) -> [Double] {
        let read = { [rusageCPU(agentPID) ?? 0, psCPU(server) ?? 0, rusageCPU(getpid()) ?? 0] }
        let before = read()
        nonisolated(unsafe) let poll = poll
        let timer = Timer(timeInterval: 1, repeats: true) { _ in poll() }
        RunLoop.main.add(timer, forMode: .common)
        pumpEvents(stretch)
        timer.invalidate()
        return zip(read(), before).map { $0 - $1 }
    }
    func report(_ name: String, _ totals: [Double]) {
        print(String(format: "%@: a second, MenuBarAgent %.1f ms, WindowServer %.1f ms, probe %.1f ms", name,
                     totals[0] / seconds, totals[1] / seconds, totals[2] / seconds))
    }
    // MenuBarAgent's own load comes and goes with what Steve does, so the polls take turns in
    // 5 s stretches.
    var totals = polls.map { _ in [0.0, 0, 0] }
    for _ in 0..<Int(seconds / 5) {
        for (index, poll) in polls.enumerated() {
            totals[index] = zip(totals[index], measure(poll.poll, for: 5)).map { $0 + $1 }
        }
    }
    for (index, poll) in polls.enumerated() { report(poll.name, totals[index]) }
    var observers: [pid_t: AXObserver] = [:]
    watchStart = .now
    _ = observeAgent(agent, agentPID: agentPID, into: &observers)
    report("nothing, observing MenuBarAgent's notifications", measure({}, for: seconds))
}

// MARK: press

@MainActor private func trayPress(bundle: String) {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else {
        print("\(bundle) is not running")
        return
    }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 1)
    guard let bar = attribute(element, kAXExtrasMenuBarAttribute), let item = children(bar as! AXUIElement).first,
          let itemFrame = frame(of: item) else {
        print("\(bundle) has no status item")
        return
    }
    print("item \(show(itemFrame)) \(describe(item)), front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
    let screen = NSScreen.screens.first { CGDisplayBounds($0.displayID).contains(CGPoint(x: itemFrame.midX, y: itemFrame.minY)) }
        ?? NSScreen.screens[0]
    let strip = CGRect(x: CGDisplayBounds(screen.displayID).minX, y: CGDisplayBounds(screen.displayID).minY,
                       width: CGDisplayBounds(screen.displayID).width, height: 40)
    let before = topStrip(strip, on: screen)
    let baseline = Set(onScreenRows().map(\.id))

    let start = ContinuousClock.now
    nonisolated(unsafe) var pressed: (AXError, Double)?
    // The press blocks while the menu it opens stays open.
    DispatchQueue.global().async {
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        pressed = (result, milliseconds(since: start))
    }
    var seen = Set<UInt32>(), menuSeen = false
    while milliseconds(since: start) < 3000, !menuSeen {
        pumpEvents(0.05)
        for row in onScreenRows() where !baseline.contains(row.id) && !seen.contains(row.id) {
            seen.insert(row.id)
            print("\(stamp(start))  new window \(row.id) of \(appName(row.owner)), layer \(row.layer), \(show(row.bounds))")
            if row.owner == app.processIdentifier, row.layer >= Int(CGWindowLevelForKey(.popUpMenuWindow)) { menuSeen = true }
        }
    }
    if let pressed { print("\(stamp(start))  AXPress returned \(pressed.0.rawValue) after \(String(format: "%.0f", pressed.1)) ms") }
    pumpEvents(0.3)
    if let before, let during = topStrip(strip, on: screen) {
        print("\(stamp(start))  top 40 pt of \(screen.localizedName): \(changedShare(before, during, strip))% of points changed")
    }
    // NSMenu takes AXCancel on the open menu; Escape through the HID tap is the fallback.
    let menus = children(item).filter { attribute($0, kAXRoleAttribute) as? String == kAXMenuRole }
    let cancelled = menus.first.map { AXUIElementPerformAction($0, kAXCancelAction as CFString) }
    print("\(stamp(start))  open menus under the item: \(menus.count), AXCancel: \(cancelled.map { "\($0.rawValue)" } ?? "none")")
    if cancelled != .success {
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap) }
        print("\(stamp(start))  posted Escape")
    }
    pumpEvents(0.5)
    let left = onScreenRows().filter { seen.contains($0.id) }
    print("\(stamp(start))  windows the press opened still on screen: \(left.count); AXPress "
        + (pressed.map { "returned \($0.0.rawValue) after \(String(format: "%.0f", $0.1)) ms" } ?? "has not returned"))
}

private func onScreenRows() -> [(id: UInt32, owner: pid_t, layer: Int, bounds: CGRect)] {
    ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { row in
        guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let owner = row[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = (row[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
        else { return nil }
        return (id, owner, row[kCGWindowLayer as String] as? Int ?? 0, bounds)
    }
}

/// A capture of everything in `rect` on `screen`, as it shows.
@MainActor private func topStrip(_ rect: CGRect, on screen: NSScreen) -> Capture? {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var content: SCShareableContent?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { result, _ in
        content = result
        done.signal()
    }
    done.wait()
    guard let display = content?.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = rect.offsetBy(dx: -rect.minX, dy: -rect.minY)
    configuration.width = Int(rect.width * 2)
    configuration.height = Int(rect.height * 2)
    configuration.showsCursor = false
    nonisolated(unsafe) var image: CGImage?
    SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                     configuration: configuration) { result, _ in
        image = result
        done.signal()
    }
    done.wait()
    return image.flatMap { Capture($0, origin: rect.origin, scale: 2) }
}

/// The share of points in `rect`, sampled every 2 pt, whose luminance differs by more than 24.
private func changedShare(_ a: Capture, _ b: Capture, _ rect: CGRect) -> Int {
    var changed = 0, total = 0
    for x in stride(from: rect.minX, to: rect.maxX, by: 2) {
        for y in stride(from: rect.minY, to: rect.maxY, by: 2) {
            guard let one = a.luminance(CGPoint(x: x, y: y)), let two = b.luminance(CGPoint(x: x, y: y)) else { continue }
            total += 1
            if abs(one - two) > 24 { changed += 1 }
        }
    }
    return total == 0 ? 0 : changed * 100 / total
}
