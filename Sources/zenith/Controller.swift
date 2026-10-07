import AppKit
import CZenith
import ZenithCore

/// Holds what the bars show, and redraws them on each change: Kosmos's state, the clock,
/// the battery, the volume and the hovered item.
@MainActor final class Controller {
    private var bars: [CGDirectDisplayID: Bar] = [:]
    /// Kosmos's number for each display (docs/overview.md).
    private var numbers: [CGDirectDisplayID: Int] = [:]
    private var rows: [Int: WorkspaceRow] = [:]
    private var theme = Theme.fallback
    private var config = Config()
    private var settingsWatches: [DispatchSourceFileSystemObject] = []
    private var battery = Battery.read()
    private var volume: Volume!
    private var hovered: String?
    private var clock: Timer?
    private lazy var kosmos = KosmosLink { [weak self] state in
        Task { @MainActor in self?.received(state) }
    }

    func start() {
        guard kosmos.start() else {
            log.error("Another process holds \(KosmosLink.portName, privacy: .public), as another Zenith does; exiting")
            exit(1)
        }
        readSettings()
        watchSettings()
        volume = Volume { [weak self] in self?.render() }
        Battery.watch { [weak self] in
            self?.battery = Battery.read()
            self?.render()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { _ in MainActor.assumeIsolated { self.placeBars() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated {
                self.battery = Battery.read()
                self.volume.read()
                self.tick()
                self.kosmos.refresh()
            }
        }
        placeBars()
        tick()
    }

    static let settings = URL(fileURLWithPath: NSHomeDirectory() + "/.config/zenith")

    /// `config.json` and `theme.json`, each keeping what it had when its file is missing or
    /// unreadable.
    private func readSettings() {
        if let data = try? Data(contentsOf: Self.settings.appending(path: "theme.json")) {
            if let theme = Theme(json: data) { self.theme = theme } else { log.error("Could not read theme.json") }
        }
        if let data = try? Data(contentsOf: Self.settings.appending(path: "config.json")) {
            if let config = Config(json: data) { self.config = config } else { log.error("Could not read config.json") }
        }
    }

    /// Reads the settings again when their folder changes, as when an editor saves by
    /// replacing a file or `theme-set` relinks one, or when a file is written in place. A
    /// change to the folder watches its files again, as they may be new.
    private func watchSettings() {
        try? FileManager.default.createDirectory(at: Self.settings, withIntermediateDirectories: true)
        for watch in settingsWatches { watch.cancel() }
        settingsWatches = [Self.settings.path, Self.settings.appending(path: "config.json").path,
                           Self.settings.appending(path: "theme.json").path].compactMap { path in
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                   eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    // Watched again first, so a write while the settings are read is seen.
                    self?.watchSettings()
                    self?.readSettings()
                    self?.render()
                }
            }
            source.setCancelHandler { close(fd) }
            source.activate()
            return source
        }
    }

    private func received(_ state: KosmosState) {
        let next = workspaceRows(state, icons: appIcons)
        guard next != rows else { return }
        rows = next
        render()
    }

    /// Redraws at each minute's start, on a timer set for it rather than a tick each second.
    private func tick() {
        clock?.invalidate()
        render()
        let timer = Timer(fire: nextMinute(after: Date()), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    /// A bar for each screen, numbered as Kosmos numbers displays.
    private func placeBars() {
        let screens = NSScreen.screens
        let managed = (SLSCopyManagedDisplays(SLSMainConnectionID())?.takeRetainedValue() as? [String]) ?? []
        numbers = [:]
        for screen in screens {
            let id = screen.displayID
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            numbers[id] = displayNumber(uuid: uuid ?? "", active: screens.count, managed: managed)
            if let bar = bars[id] { bar.move(to: screen) } else { bars[id] = Bar(screen: screen, view: BarView(controller: self, display: id)) }
        }
        for (id, bar) in bars where !screens.contains(where: { $0.displayID == id }) {
            bar.panel.orderOut(nil)
            bars[id] = nil
        }
        render()
    }

    private func render() {
        for (id, bar) in bars {
            let scale = NSScreen.screens.first { $0.displayID == id }?.backingScaleFactor ?? 2
            bar.show(left: leftItems(numbers[id].flatMap { rows[$0] }), right: rightItems(scale: scale),
                     style: config.style, background: theme.background.cgColor, scale: scale)
        }
    }

    // The fonts and sizes of Steve's SketchyBar config.

    private func leftItems(_ row: WorkspaceRow?) -> [(key: String, item: Item)] {
        guard let row else { return [] }
        var items = row.pills.map { pill -> (key: String, item: Item) in
            let key = "space." + pill.name
            let color = switch pill.emphasis {
            case .focused, .shown: theme.selected
            case .hidden: hovered == key ? theme.foreground : theme.dim
            }
            var text = NSAttributedString(
                string: pill.name, attributes: [.font: font(14, bold: pill.emphasis == .focused), .foregroundColor: color.nsColor])
            if !pill.glyphs.isEmpty {
                text = joined(text, NSAttributedString(string: pill.glyphs, attributes: [
                    .font: NSFont(name: "sketchybar-app-font", size: 14) ?? font(14), .foregroundColor: color.nsColor,
                ]), gap: 8, centered: true)
            }
            return (key, Item(content: .text(text)))
        }
        if let app = row.frontApp {
            let text = NSAttributedString(string: app, attributes: [.font: font(13), .foregroundColor: theme.foreground.nsColor])
            items.append(("front", Item(content: .text(text))))
        }
        return items
    }

    /// From the bar's right end inward: the calendar, the battery, the volume.
    private func rightItems(scale: CGFloat) -> [(key: String, item: Item)] {
        var items: [(key: String, item: Item)] = []
        let (date, time) = clockText(Date())
        let bold = [NSAttributedString.Key.font: font(13, bold: true), .foregroundColor: theme.foreground.nsColor]
        let calendar = joined(NSAttributedString(string: date, attributes: bold),
                              NSAttributedString(string: time, attributes: bold), gap: 8)
        items.append(("calendar", Item(content: .text(calendar))))
        if let battery, let (image, size, ink) = batteryImage(battery, scale: scale) {
            items.append(("battery", Item(content: .image(image, size: size, ink: ink))))
        }
        let speaker = volumeGlyph(volume.level, muted: volume.muted)
        let glyph = NSAttributedString(string: speaker.glyph, attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: (speaker.dim ? theme.dim : theme.foreground).nsColor,
        ])
        items.append(("volume", Item(content: .text(glyph), center: .ink)))
        return items
    }

    private struct BatteryDrawing: Hashable {
        var battery: Battery
        var foreground: RGBA, background: RGBA
        var scale: CGFloat
    }

    /// The battery's image, drawn again only when what it shows changes: an item's image
    /// compares by identity, so a new image redraws its layer on every render.
    private var batteryImages: [CGFloat: (key: BatteryDrawing, image: (CGImage, CGSize, ClosedRange<CGFloat>))] = [:]

    private func batteryImage(_ battery: Battery, scale: CGFloat) -> (CGImage, CGSize, ClosedRange<CGFloat>)? {
        let key = BatteryDrawing(battery: battery, foreground: theme.foreground, background: theme.background, scale: scale)
        if let cached = batteryImages[scale], cached.key == key { return cached.image }
        guard let image = battery.image(foreground: theme.foreground.nsColor, background: theme.background.nsColor,
                                        scale: scale) else { return nil }
        batteryImages[scale] = (key, image)
        return image
    }

    /// `first` then `second` with `gap` points between their ink, kerning away the blank the
    /// fonts leave after the one and before the other. `centered` raises or lowers `second`'s
    /// ink to center on `first`'s figures, as a pill's app glyphs on its number.
    private func joined(_ first: NSAttributedString, _ second: NSAttributedString, gap: CGFloat,
                        centered: Bool = false) -> NSAttributedString {
        let after = first.size().width - inkBounds(first).maxX
        let text = NSMutableAttributedString(attributedString: first)
        text.addAttribute(.kern, value: gap - after - inkBounds(second).minX, range: NSRange(location: text.length - 1, length: 1))
        let tail = NSMutableAttributedString(attributedString: second)
        if centered, let font = first.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            tail.addAttribute(.baselineOffset, value: font.capHeight / 2 - inkBounds(second).midY,
                              range: NSRange(location: 0, length: tail.length))
        }
        text.append(tail)
        return text
    }

    private func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "JetBrainsMonoNF-Bold" : "JetBrainsMonoNF-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    func clicked(_ key: String) {
        if key.hasPrefix("space.") {
            kosmos.send(["workspace", String(key.dropFirst(6))])
        } else if key == "front" {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        } else if key == "volume" {
            volume.toggleMute()
        }
    }

    func hover(_ key: String?) {
        guard key != hovered else { return }
        let changed = [hovered, key].contains { $0?.hasPrefix("space.") == true }
        hovered = key
        if changed { render() }
    }
}

/// Takes the bar's clicks and hovers and hands them to the controller by item.
final class BarView: NSView {
    private let controller: Controller
    private let display: CGDirectDisplayID

    init(controller: Controller, display: CGDirectDisplayID) {
        self.controller = controller
        self.display = display
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func key(_ event: NSEvent) -> String? {
        controller.item(at: convert(event.locationInWindow, from: nil), on: display)
    }

    override func mouseDown(with event: NSEvent) { key(event).map(controller.clicked) }
    override func mouseMoved(with event: NSEvent) { controller.hover(key(event)) }
    override func mouseExited(with event: NSEvent) { controller.hover(nil) }
}

extension Controller {
    func item(at point: CGPoint, on display: CGDirectDisplayID) -> String? { bars[display]?.item(at: point) }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { nsColor.cgColor }
}
