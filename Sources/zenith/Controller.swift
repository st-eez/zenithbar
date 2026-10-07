import AppKit
import ZenithCore
import ZenithKit

/// Holds what the bars show, and redraws them on each change: Kosmos's state, the clock,
/// the battery, the network, the volume, the plugins' items and the hovered item.
@MainActor final class Controller {
    private var bars: [CGDirectDisplayID: Bar] = [:]
    /// Each screen's UUID, which Kosmos's snapshot names its displays by.
    private var uuids: [CGDirectDisplayID: String] = [:]
    private var rows: [String: WorkspaceRow] = [:]
    private var theme = Theme.fallback
    private var config = Config()
    private var settingsWatches: [DispatchSourceFileSystemObject] = []
    private var battery = Battery.read()
    private var volume: Volume!
    private var network: Network!
    private var hovered: (key: String, display: CGDirectDisplayID)?
    private var clock: Timer?
    private lazy var kosmos = KosmosLink { [weak self] state in
        Task { @MainActor in self?.received(state) }
    }
    private lazy var plugins = Plugins { [weak self] item in self?.received(item) }
    /// The plugins' items, in the order they first printed them.
    private var pluginItems: [(key: String, item: PluginItem)] = []
    /// The page each plugin item's panel shows.
    private var pages: [String: Int] = [:]
    private lazy var popup = Popup(selected: { [weak self] page in self?.select(page: page) },
                                   exited: { [weak self] in self?.pointerMayHaveLeft() })

    func start() {
        guard kosmos.start() else {
            log.error("Another process holds \(KosmosLink.portName, privacy: .public), as another Zenith does; exiting")
            exit(1)
        }
        readSettings()
        watchSettings()
        volume = Volume { [weak self] in self?.render() }
        network = Network { [weak self] glyph in
            guard let self else { return }
            if glyph { render() }
            if let shown = popup.shown, shown.key == "network" { openPopup("network", display: shown.display) }
        }
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
                self.network.read()
                self.tick()
                self.kosmos.refresh()
                self.plugins.runAll(event: "wake")
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
        plugins.configure(config.plugins)
        // A plugin gone from config.json takes its items off the bar, and their panel with them.
        pluginItems.removeAll { !plugins.owns($0.item.item) }
        pages = pages.filter { page in pluginItems.contains { $0.key == page.key } }
        if let shown = popup.shown, shown.key.hasPrefix("plugin."), !pluginItems.contains(where: { $0.key == shown.key }) {
            popup.close()
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

    private func received(_ item: PluginItem) {
        let key = "plugin." + item.item
        if let index = pluginItems.firstIndex(where: { $0.key == key }) {
            guard pluginItems[index].item != item else { return }
            pluginItems[index].item = item
        } else {
            pluginItems.append((key, item))
        }
        render()
        if popup.shown?.key == key { openPopup(key, display: popup.shown!.display) }
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

    /// A bar for each screen.
    private func placeBars() {
        let screens = NSScreen.screens
        uuids = [:]
        for screen in screens {
            let id = screen.displayID
            uuids[id] = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            if let bar = bars[id] { bar.move(to: screen) } else { bars[id] = Bar(screen: screen, view: BarView(controller: self, display: id)) }
        }
        for (id, bar) in bars where !screens.contains(where: { $0.displayID == id }) {
            bar.panel.orderOut(nil)
            bars[id] = nil
        }
        if let shown = popup.shown, bars[shown.display] == nil { popup.close() }
        render()
    }

    private func render() {
        for (id, bar) in bars {
            let scale = NSScreen.screens.first { $0.displayID == id }?.backingScaleFactor ?? 2
            bar.show(left: leftItems(uuids[id].flatMap { rows[$0] }, display: id), right: rightItems(scale: scale),
                     style: config.style, background: theme.background.cgColor, scale: scale)
        }
        // An item that left its bar, or whose bar went with its display, gets no exit event.
        if let hovered, bars[hovered.display]?.frames[hovered.key] == nil { self.hovered = nil }
    }

    // The fonts and sizes of Steve's SketchyBar config.

    private func leftItems(_ row: WorkspaceRow?, display: CGDirectDisplayID) -> [(key: String, item: Item)] {
        guard let row else { return [] }
        var items = row.pills.map { pill -> (key: String, item: Item) in
            let key = "space." + pill.name
            let color = switch pill.emphasis {
            case .focused, .shown: theme.selected
            case .hidden: hovered?.key == key && hovered?.display == display ? theme.foreground : theme.dim
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
            // Short enough that the name, last on the left, rarely meets the right run or the notch.
            let name = app.count > 24 ? app.prefix(23) + "…" : app
            let text = NSAttributedString(string: name, attributes: [.font: font(13), .foregroundColor: theme.foreground.nsColor])
            items.append(("front", Item(content: .text(text))))
        }
        return items
    }

    /// From the bar's right end inward: the calendar, the battery, the network, the volume,
    /// then the plugins' items, the system items in the native menu bar's order.
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
        let route = networkIcon(network.route), routeColor = route.dim ? theme.dim : theme.foreground
        switch route.icon {
        case let .glyph(glyph):
            let text = NSAttributedString(string: glyph, attributes: [.font: font(16), .foregroundColor: routeColor.nsColor])
            items.append(("network", Item(content: .text(text), center: .ink)))
        case let .symbol(name, value):
            if let (image, size, ink) = symbolImage(name, value: value, color: routeColor, scale: scale) {
                items.append(("network", Item(content: .image(image, size: size, ink: ink))))
            }
        }
        let speaker = volumeGlyph(volume.level, muted: volume.muted)
        let glyph = NSAttributedString(string: speaker.glyph, attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: (speaker.dim ? theme.dim : theme.foreground).nsColor,
        ])
        items.append(("volume", Item(content: .text(glyph), center: .ink)))
        for (key, item) in pluginItems where !item.hidden {
            let glyph = NSAttributedString(string: item.icon, attributes: [
                .font: font(16), .foregroundColor: (item.alert ? theme.alert : theme.foreground).nsColor,
            ])
            items.append((key, Item(content: .text(glyph), center: .ink)))
        }
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

    private struct SymbolDrawing: Hashable {
        var name: String
        var value: Double?
        var color: RGBA
    }

    /// The network's symbol, drawn again only when it changes, as the battery's image is.
    private var symbolImages: [CGFloat: (key: SymbolDrawing, image: (CGImage, CGSize, ClosedRange<CGFloat>))] = [:]

    /// At 16 pt, the size of the volume's speaker beside it.
    private func symbolImage(_ name: String, value: Double?, color: RGBA,
                             scale: CGFloat) -> (CGImage, CGSize, ClosedRange<CGFloat>)? {
        let key = SymbolDrawing(name: name, value: value, color: color)
        if let cached = symbolImages[scale], cached.key == key { return cached.image }
        guard let image = symbol(name, value: value, pointSize: 16, color: color.nsColor).flatMap({ inkImage($0, scale: scale) })
        else { return nil }
        symbolImages[scale] = (key, image)
        return image
    }

    /// `first` then `second` with `gap` points between their ink, kerning away the blank the
    /// fonts leave after the one and before the other. `centered` raises or lowers `second`'s
    /// ink to center on `first`'s figures, as a pill's app glyphs on its number.
    private func joined(_ first: NSAttributedString, _ second: NSAttributedString, gap: CGFloat,
                        centered: Bool = false) -> NSAttributedString {
        guard first.length > 0 else { return second }
        let after = first.size().width - inkBounds(first).maxX
        let text = NSMutableAttributedString(attributedString: first)
        text.addAttribute(.kern, value: gap - after - inkBounds(second).minX, range: NSRange(location: text.length - 1, length: 1))
        let tail = NSMutableAttributedString(attributedString: second)
        if centered, let font = first.firstFont {
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

    enum Button { case left, right, middle }

    func clicked(_ key: String, button: Button, display: CGDirectDisplayID) {
        if key.hasPrefix("plugin.") {
            return pluginClicked(key, button: button, display: display)
        }
        guard button == .left else { return }
        if key.hasPrefix("space.") {
            kosmos.send(["workspace", String(key.dropFirst(6))])
        } else if key == "front" {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        } else if key == "volume" {
            volume.toggleMute()
        } else if key == "network" {
            if popup.shown?.key == key { popup.close() } else { openPopup(key, display: display) }
        }
    }

    func hover(_ key: String?, display: CGDirectDisplayID) {
        let next = key.map { (key: $0, display: display) }
        guard next?.key != hovered?.key || next?.display != hovered?.display else { return }
        let changed = [hovered?.key, key].contains { $0?.hasPrefix("space.") == true }
        hovered = next
        if changed { render() }
        if popup.shown != nil, key != popup.shown?.key { pointerMayHaveLeft() }
    }

    /// A left click opens or closes the item's panel, a middle click shows its next page,
    /// and a right click runs its plugin now, as SketchyBar's agents item did.
    private func pluginClicked(_ key: String, button: Button, display: CGDirectDisplayID) {
        switch button {
        case .left: if popup.shown?.key == key { popup.close() } else { openPopup(key, display: display) }
        case .middle:
            guard let item = pluginItems.first(where: { $0.key == key })?.item, !item.pages.isEmpty else { return }
            pages[key] = ((pages[key] ?? 0) + 1) % item.pages.count
            if popup.shown?.key == key { openPopup(key, display: display) }
        case .right: plugins.run(item: String(key.dropFirst("plugin.".count)), event: "refresh")
        }
    }

    private func openPopup(_ key: String, display: CGDirectDisplayID) {
        guard let item = key == "network" ? network.panel() : pluginItems.first(where: { $0.key == key })?.item,
              !item.hidden, !item.pages.isEmpty,
              let bar = bars[display], let frame = bar.frames[key],
              let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return popup.close() }
        let anchor = frame.offsetBy(dx: bar.panel.frame.minX, dy: bar.panel.frame.minY)
        var icon: NSImage?
        if key == "network", case let .symbol(name, value) = networkIcon(network.route).icon {
            icon = symbol(name, value: value, pointSize: 13, color: theme.accent.nsColor)
        }
        popup.show(item, page: min(pages[key] ?? 0, item.pages.count - 1), key: key, display: display, anchor: anchor,
                   screen: screen.frame, theme: theme, icon: icon)
    }

    private func select(page: Int) {
        guard let shown = popup.shown else { return }
        pages[shown.key] = page
        openPopup(shown.key, display: shown.display)
    }

    /// Closes the panel 50 ms after the pointer leaves it or its item, unless the pointer is
    /// back on one of them by then, as when it crosses the gap between them.
    private func pointerMayHaveLeft() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let shown = self.popup.shown else { return }
                let pointer = NSEvent.mouseLocation
                let onItem = self.bars[shown.display].flatMap { bar in
                    bar.frames[shown.key].map { $0.offsetBy(dx: bar.panel.frame.minX, dy: bar.panel.frame.minY) }
                }?.contains(pointer) == true
                if !onItem, !self.popup.panel.frame.contains(pointer) { self.popup.close() }
            }
        }
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

    override func mouseDown(with event: NSEvent) { click(event, .left) }
    override func rightMouseDown(with event: NSEvent) { click(event, .right) }
    override func otherMouseDown(with event: NSEvent) { click(event, .middle) }

    private func click(_ event: NSEvent, _ button: Controller.Button) {
        if let key = key(event) { controller.clicked(key, button: button, display: display) }
    }
    override func mouseMoved(with event: NSEvent) { controller.hover(key(event), display: display) }
    override func mouseExited(with event: NSEvent) { controller.hover(nil, display: display) }
}

extension Controller {
    func item(at point: CGPoint, on display: CGDirectDisplayID) -> String? { bars[display]?.item(at: point) }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { nsColor.cgColor }
}
