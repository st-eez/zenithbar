import AppKit
import ZenithBarCore
import ZenithBarKit

/// Holds what the bars show, and redraws them on each change: Kosmos's workspaces and front
/// app on the left; on the right the built-in items, each from its module, and the plugins'
/// items; and the hovered item.
@MainActor final class Controller {
    private var bars: [CGDirectDisplayID: Bar] = [:]
    /// Each screen's UUID, which Kosmos's snapshot names its displays by.
    private var uuids: [CGDirectDisplayID: String] = [:]
    private var rows: [String: WorkspaceRow] = [:]
    private var theme = Theme.fallback
    private var config = Config()
    private var settingsWatches: [DispatchSourceFileSystemObject] = []
    /// From the bar's right end inward: the calendar, the battery, the network, Bluetooth, the
    /// speaker and the microphone, the native menu bar's order with the network in Wi-Fi's place
    /// and Bluetooth where Omarchy places it, left of the network. The plugins' items follow.
    private let modules: [BarModule] = [CalendarModule(), BatteryModule(), NetworkModule(), BluetoothModule(), SoundModule()]
    private var hovered: (key: String, display: CGDirectDisplayID)?
    private lazy var kosmos = KosmosLink { [weak self] state in onMain { self?.received(state) } }
    private lazy var plugins = Plugins { [weak self] item in self?.received(item) }
    /// The plugins' items, in the order they first printed them.
    private var pluginItems: [(key: String, item: PluginItem)] = []
    /// The page each plugin item's panel shows.
    private var pages: [String: Int] = [:]
    private var pluginImages = DrawingCache<Item?>()
    private lazy var popup = Popup(selected: { [weak self] page in self?.select(page: page) },
                                   exited: { [weak self] in self?.pointerMayHaveLeft() })

    func start() {
        guard kosmos.start() else {
            log.error("Another process holds \(KosmosLink.portName, privacy: .public), as another ZenithBar does; exiting")
            exit(1)
        }
        readSettings()
        watchSettings()
        let panelHost = PanelHost(takeKeyboard: { [weak self] field in self?.popup.takeKeyboard(for: field) },
                                  giveKeyboardBack: { [weak self] in self?.popup.giveKeyboardBack() },
                                  resized: { [weak self] in self?.popup.fit() },
                                  pointerMayHaveLeft: { [weak self] in self?.pointerMayHaveLeft() })
        for module in modules {
            module.start(ModuleHost(changed: { [weak self, unowned module] icon in self?.changed(module, icon: icon) },
                                    panel: panelHost))
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in onMain { self?.placeBars() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            onMain {
                guard let self else { return }
                for module in self.modules { module.wake() }
                self.kosmos.refresh()
                self.plugins.runAll(event: "wake")
            }
        }
        placeBars()
        #if DEBUG
        watchTestHooks()
        #endif
    }

    private func module(for key: String) -> BarModule? { modules.first { $0.keys.contains(key) } }

    private func changed(_ module: BarModule, icon: Bool) {
        if icon { render() }
        if let shown = popup.shown, module.keys.contains(shown.key) { module.refreshPanel() }
    }

    #if DEBUG
    /// In debug builds only, as any local process can post the notification: commands for
    /// testing panels without the pointer, posted as a distributed notification
    /// `io.github.st-eez.zenithbar.test` whose object is the command, as `zenithbar-probe send`
    /// posts it: `open <item>` on the first display showing it, `close`, and each module's own
    /// (`BarModule.test`).
    private func watchTestHooks() {
        DistributedNotificationCenter.default().addObserver(forName: .init("io.github.st-eez.zenithbar.test"), object: nil,
                                                            queue: .main) { [weak self] note in
            let words = (note.object as? String ?? "").split(separator: " ", maxSplits: 2).map(String.init)
            onMain {
                guard let self else { return }
                log.info("Test hook: \(words.joined(separator: " "), privacy: .public)")
                switch (words.first, words.dropFirst().first) {
                case ("open", let key?):
                    if let display = self.bars.keys.sorted().first(where: { self.bars[$0]?.frames[key] != nil }) {
                        self.openPopup(key, display: display)
                    }
                case ("close", _): self.popup.close()
                default:
                    if !self.modules.contains(where: { $0.test(words) }) {
                        log.error("Unknown test hook \(words.joined(separator: " "), privacy: .public)")
                    }
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
        for module in modules { module.configure(config) }
        // A plugin gone from config.json takes its items off the bar, and their panel with them.
        pluginItems.removeAll { !plugins.owns($0.item.item) }
        pages = pages.filter { page in pluginItems.contains { $0.key == page.key } }
        if let shown = popup.shown, shown.key.hasPrefix("plugin."), !pluginItems.contains(where: { $0.key == shown.key }) {
            popup.close()
        }
        // In the new theme's colors.
        if let shown = popup.shown, module(for: shown.key) != nil {
            openPopup(shown.key, display: shown.display)
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
                onMain {
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
                string: pill.name, attributes: [.font: barFont(14, bold: pill.emphasis == .focused), .foregroundColor: color.nsColor])
            if !pill.glyphs.isEmpty {
                text = joined(text, NSAttributedString(string: pill.glyphs, attributes: [
                    .font: NSFont(name: "sketchybar-app-font", size: 14) ?? barFont(14), .foregroundColor: color.nsColor,
                ]), gap: 8, centered: true)
            }
            return (key, Item(content: .text(text)))
        }
        if let app = row.frontApp {
            // Short enough that the name, last on the left, rarely meets the right run or the notch.
            let name = app.count > 24 ? app.prefix(23) + "…" : app
            let text = NSAttributedString(string: name, attributes: [.font: barFont(13), .foregroundColor: theme.foreground.nsColor])
            items.append(("front", Item(content: .text(text))))
        }
        return items
    }

    /// The modules' items, then the plugins'.
    private func rightItems(scale: CGFloat) -> [(key: String, item: Item)] {
        var items = modules.flatMap { $0.items(scale: scale, theme: theme) }
        for (key, item) in pluginItems where !item.hidden {
            let color = item.alert ? theme.alert : theme.foreground
            if let symbol = item.symbol, let image = pluginImages.symbolItem(symbol, slot: key, color: color, scale: scale) {
                items.append((key, image))
                continue
            }
            let glyph = NSAttributedString(string: item.icon, attributes: [.font: barFont(16), .foregroundColor: color.nsColor])
            items.append((key, Item(content: .text(glyph), center: .ink)))
        }
        return items
    }

    func clicked(_ key: String, button: MouseButton, display: CGDirectDisplayID) {
        if key.hasPrefix("plugin.") {
            return pluginClicked(key, button: button, display: display)
        }
        if let module = module(for: key) {
            if module.clicked(key, button: button) == .togglePanel {
                if popup.shown?.key == key { popup.close() } else { openPopup(key, display: display) }
            }
            return
        }
        guard button == .left else { return }
        if key.hasPrefix("space.") {
            kosmos.send(["workspace", String(key.dropFirst(6))])
        } else if key == "front" {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        }
    }

    func scrolled(_ key: String, delta: Double, precise: Bool, momentum: Bool) {
        module(for: key)?.scrolled(key, delta: delta, precise: precise, momentum: momentum)
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
    private func pluginClicked(_ key: String, button: MouseButton, display: CGDirectDisplayID) {
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
        if let module = module(for: key) { return openPanel(of: module, key: key, display: display) }
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

    private func openPanel(of module: BarModule, key: String, display: CGDirectDisplayID) {
        guard let bar = bars[display], let frame = bar.frames[key],
              let screen = NSScreen.screens.first(where: { $0.displayID == display }),
              let view = module.panel(for: key, theme: theme) else { return popup.close() }
        popup.show(view, key: key, display: display,
                   anchor: frame.offsetBy(dx: bar.panel.frame.minX, dy: bar.panel.frame.minY), screen: screen.frame,
                   theme: theme, closed: { [weak module] in module?.panelClosed() })
        module.panelOpened()
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
            onMain {
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

    private func click(_ event: NSEvent, _ button: MouseButton) {
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
