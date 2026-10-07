import AppKit
import ZenithBarCore
import ZenithBarKit

/// Holds what the bars show, and redraws them on each change: Kosmos's state, the clock,
/// the battery, the network, the sound, the plugins' items and the hovered item.
@MainActor final class Controller {
    private var bars: [CGDirectDisplayID: Bar] = [:]
    /// Each screen's UUID, which Kosmos's snapshot names its displays by.
    private var uuids: [CGDirectDisplayID: String] = [:]
    private var rows: [String: WorkspaceRow] = [:]
    private var theme = Theme.fallback
    private var config = Config()
    private var settingsWatches: [DispatchSourceFileSystemObject] = []
    private var battery = Battery.read()
    private var sound: Sound!
    /// Scroll steps carried between events, for the speaker and the microphone.
    private var scrolls: [String: ScrollSteps] = [:]
    private var network: Network!
    private var hovered: (key: String, display: CGDirectDisplayID)?
    private var clock: Timer?
    private var locationLog: LocationLog?
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
    private lazy var networkPanel: NetworkPanel = {
        let panel = NetworkPanel(network: network)
        panel.host = .init(takeKeyboard: { [weak self] field in self?.popup.takeKeyboard(for: field) },
                           giveKeyboardBack: { [weak self] in self?.popup.giveKeyboardBack() },
                           resized: { [weak self] in self?.popup.fit() },
                           pointerMayHaveLeft: { [weak self] in self?.pointerMayHaveLeft() })
        return panel
    }()
    private lazy var soundPanel: SoundPanel = {
        let panel = SoundPanel(sound: sound)
        panel.resized = { [weak self] in self?.popup.fit() }
        return panel
    }()
    /// The sound panel opens under the speaker or the microphone, whichever opened it.
    private var soundShown: Bool { popup.shown.map { ["volume", "mic"].contains($0.key) } ?? false }

    func start() {
        guard kosmos.start() else {
            log.error("Another process holds \(KosmosLink.portName, privacy: .public), as another ZenithBar does; exiting")
            exit(1)
        }
        readSettings()
        watchSettings()
        sound = Sound { [weak self] in
            guard let self else { return }
            render()
            if soundShown { soundPanel.update() }
        }
        network = Network { [weak self] glyph in
            guard let self else { return }
            if glyph { render() }
            if popup.shown?.key == "network" { networkPanel.refresh() }
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
                self.sound.read()
                self.network.read()
                self.tick()
                self.kosmos.refresh()
                self.plugins.runAll(event: "wake")
            }
        }
        placeBars()
        tick()
        locationLog = LocationLog()
        #if DEBUG
        watchTestHooks()
        #endif
    }

    #if DEBUG
    /// The microphone item as a test hook draws it.
    private var micShown: MicState?

    /// In debug builds only, as any local process can post the notification: commands for
    /// testing panels without the pointer, posted as a distributed notification
    /// `io.github.st-eez.zenithbar.test` whose object is the command, as `zenithbar-probe send`
    /// posts it: `open <item>` on the first display showing it, `close`, and for the network
    /// panel `network speedtest`, `network allow` and `network password <name>`, as clicks on
    /// them would.
    private func watchTestHooks() {
        DistributedNotificationCenter.default().addObserver(forName: .init("io.github.st-eez.zenithbar.test"), object: nil,
                                                            queue: .main) { note in
            let words = (note.object as? String ?? "").split(separator: " ", maxSplits: 2).map(String.init)
            MainActor.assumeIsolated {
                log.info("Test hook: \(words.joined(separator: " "), privacy: .public)")
                switch (words.first, words.dropFirst().first) {
                case ("open", let key?):
                    if let display = self.bars.keys.sorted().first(where: { self.bars[$0]?.frames[key] != nil }) {
                        self.openPopup(key, display: display)
                    }
                case ("close", _): self.popup.close()
                case ("network", "speedtest"): self.networkPanel.pressSpeedTest()
                case ("network", "allow"): self.networkPanel.pressAllow()
                case ("network", "password"): if words.count > 2 { self.networkPanel.pressPassword(words[2]) }
                case ("mic", let state?):
                    self.micShown = ["live": .live, "muted": .muted, "off": .hidden][state]
                    self.render()
                default: log.error("Unknown test hook \(words.joined(separator: " "), privacy: .public)")
                }
            }
        }
    }
    #endif

    static let settings = URL(fileURLWithPath: NSHomeDirectory() + "/.config/zenithbar")

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
        // In the new theme's colors.
        if let shown = popup.shown, ["network", "volume", "mic"].contains(shown.key) { openPopup(shown.key, display: shown.display) }
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

    /// From the bar's right end inward: the calendar, the battery, the network, the volume, the
    /// microphone while it shows, then the plugins' items, the system items in the native menu
    /// bar's order.
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
        let route = networkIcon(network.route)
        if let (image, size, ink) = networkImage(route.icon, color: route.dim ? theme.dim : theme.foreground, scale: scale) {
            items.append(("network", Item(content: .image(image, size: size, ink: ink))))
        }
        let output = sound.state.defaultDevice(.output)
        let speaker = outputSymbol(output, bluetooth: output.flatMap { sound.bluetooth(for: $0) })
        if let (image, size, ink) = symbolImage(speaker.name, key: "volume", color: speaker.dim ? theme.dim : theme.foreground,
                                                scale: scale) {
            items.append(("volume", Item(content: .image(image, size: size, ink: ink))))
        }
        var micState = sound.state.mic
        #if DEBUG
        micState = micShown ?? micState
        #endif
        if let mic = micState.symbol,
           let (image, size, ink) = symbolImage(mic.name, key: "mic", color: mic.alert ? theme.alert : theme.foreground,
                                                scale: scale) {
            items.append(("mic", Item(content: .image(image, size: size, ink: ink))))
        }
        for (key, item) in pluginItems where !item.hidden {
            let color = item.alert ? theme.alert : theme.foreground
            if let symbol = item.symbol, let (image, size, ink) = symbolImage(symbol, key: key, color: color, scale: scale) {
                items.append((key, Item(content: .image(image, size: size, ink: ink))))
                continue
            }
            let glyph = NSAttributedString(string: item.icon, attributes: [.font: font(16), .foregroundColor: color.nsColor])
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

    private struct NetworkDrawing: Equatable {
        var icon: NetworkIcon
        var color: RGBA
    }

    /// The network's icon, drawn again only when it changes, as the battery's image is.
    private var networkImages: [CGFloat: (key: NetworkDrawing, image: (CGImage, CGSize, ClosedRange<CGFloat>))] = [:]

    private func networkImage(_ icon: NetworkIcon, color: RGBA, scale: CGFloat) -> (CGImage, CGSize, ClosedRange<CGFloat>)? {
        let key = NetworkDrawing(icon: icon, color: color)
        if let cached = networkImages[scale], cached.key == key { return cached.image }
        guard let image = networkDrawing(icon, size: 14, color: color.nsColor).flatMap({ inkImage($0, scale: scale) }) else { return nil }
        networkImages[scale] = (key, image)
        return image
    }

    private struct SymbolDrawing: Equatable {
        var name: String
        var color: RGBA
    }

    /// Each item's symbol, the volume's, the microphone's and plugins', at each display scale, drawn again only
    /// when it changes, as the battery's image is.
    private var symbolImages: [String: (key: SymbolDrawing, image: (CGImage, CGSize, ClosedRange<CGFloat>))] = [:]

    /// At 14 pt, as the network's icon.
    private func symbolImage(_ name: String, key item: String, color: RGBA,
                             scale: CGFloat) -> (CGImage, CGSize, ClosedRange<CGFloat>)? {
        let key = SymbolDrawing(name: name, color: color), slot = "\(item) \(scale)"
        if let cached = symbolImages[slot], cached.key == key { return cached.image }
        guard let image = symbol(name, value: nil, pointSize: 14, color: color.nsColor).flatMap({ inkImage($0, scale: scale) })
        else { return nil }
        symbolImages[slot] = (key, image)
        return image
    }

    /// At 14 pt, about 12 pt tall, as the battery; at 16 pt the Wi-Fi's arcs outweighed the
    /// speaker beside it.
    private func networkDrawing(_ icon: NetworkIcon, size: CGFloat, color: NSColor) -> NSImage? {
        switch icon {
        case let .symbol(name, value): symbol(name, value: value, pointSize: size, color: color)
        // The glyph at 16 pt, as the bar's other Nerd Font icons.
        case let .glyph(text): glyph(text, font: font(size + 2), color: color)
        }
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
        switch (key, button) {
        // Omarchy's speaker: a left or middle click opens the panel, a right click mutes.
        case ("volume", .left), ("volume", .middle), ("mic", .middle):
            return popup.shown?.key == key ? popup.close() : openPopup(key, display: display)
        case ("volume", .right): return sound.toggleOutputMute()
        // Omarchy's microphone: a left click mutes.
        case ("mic", .left): return sound.toggleMic()
        default: break
        }
        guard button == .left else { return }
        if key.hasPrefix("space.") {
            kosmos.send(["workspace", String(key.dropFirst(6))])
        } else if key == "front" {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        } else if key == "network" {
            if popup.shown?.key == key { popup.close() } else { openPopup(key, display: display) }
        }
    }

    /// A scroll on the speaker or the microphone steps its level by 5%, as Omarchy's do.
    func scrolled(_ key: String, delta: Double, precise: Bool, momentum: Bool) {
        guard key == "volume" || key == "mic" else { return }
        let steps = scrolls[key, default: ScrollSteps()].steps(delta: delta, precise: precise, momentum: momentum)
        guard steps != 0 else { return }
        if key == "volume" { sound.stepOutput(steps) } else { sound.stepInput(steps) }
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
        if key == "network" { return openNetwork(display: display) }
        if key == "volume" || key == "mic" { return openSound(key, display: display) }
        guard let item = pluginItems.first(where: { $0.key == key })?.item,
              !item.hidden, !item.pages.isEmpty,
              let bar = bars[display], let frame = bar.frames[key],
              let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return popup.close() }
        let anchor = frame.offsetBy(dx: bar.panel.frame.minX, dy: bar.panel.frame.minY)
        let drawing = item.symbol.flatMap { symbol($0, value: nil, pointSize: 13, color: theme.accent.nsColor) }
        let icon = drawing.flatMap { inkImage($0, scale: screen.backingScaleFactor) }.map { NSImage(cgImage: $0.0, size: $0.1) }
        popup.show(item, page: min(pages[key] ?? 0, item.pages.count - 1), key: key, display: display, anchor: anchor,
                   screen: screen.frame, theme: theme, icon: icon)
    }

    private func openNetwork(display: CGDirectDisplayID) {
        guard let bar = bars[display], let frame = bar.frames["network"],
              let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return popup.close() }
        networkPanel.theme = theme
        popup.show(networkPanel, key: "network", display: display,
                   anchor: frame.offsetBy(dx: bar.panel.frame.minX, dy: bar.panel.frame.minY), screen: screen.frame,
                   theme: theme, closed: { [weak self] in self?.networkPanel.close() })
        networkPanel.open()
    }

    private func openSound(_ key: String, display: CGDirectDisplayID) {
        guard let bar = bars[display], let frame = bar.frames[key],
              let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return popup.close() }
        soundPanel.theme = theme
        soundPanel.update()
        popup.show(soundPanel, key: key, display: display,
                   anchor: frame.offsetBy(dx: bar.panel.frame.minX, dy: bar.panel.frame.minY), screen: screen.frame, theme: theme)
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
                // Someone typing in the panel keeps it open (docs/network.md, the panel's focus).
                guard let self, let shown = self.popup.shown, !self.popup.typing else { return }
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

    /// Up is louder whichever way the system scrolls, as the hand moved.
    override func scrollWheel(with event: NSEvent) {
        guard let key = key(event) else { return }
        let delta = Double(event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY)
        controller.scrolled(key, delta: delta, precise: event.hasPreciseScrollingDeltas, momentum: event.momentumPhase != [])
    }
    override func mouseExited(with event: NSEvent) { controller.hover(nil, display: display) }
}

extension Controller {
    func item(at point: CGPoint, on display: CGDirectDisplayID) -> String? { bars[display]?.item(at: point) }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { nsColor.cgColor }
}
