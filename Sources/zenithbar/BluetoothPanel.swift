import AppKit
import ZenithBarCore

/// The Bluetooth panel, after Omarchy 4's (docs/bluetooth.md, the panel): a header with the
/// item's glyph, "Bluetooth", Omarchy's rotating caption and the power switch; then CONNECTED,
/// whose rows disconnect on a click, and MY DEVICES, the paired devices not connected, whose rows
/// connect. It shows `Bluetooth`'s state, which its events keep current whether or not it is
/// open; only the caption's phrases run while it is open.
@MainActor final class BluetoothPanel: FlippedView {
    private let bluetooth: Bluetooth
    /// Places the panel again when its height changes.
    var resized: (@MainActor () -> Void)?
    var theme = Theme.fallback { didSet { if theme != oldValue { restyle() } } }

    static let width: CGFloat = 380
    private static let pad: CGFloat = 16
    private let icon = PanelImage()
    private let title = PanelLabel(size: 14, bold: true)
    private let caption = PanelLabel(size: 9.5, bold: true)
    private let power = PanelSwitch()
    private let note = PanelLabel(size: 11.5)
    private let sections = [Section("CONNECTED"), Section("MY DEVICES")]
    private var phrase = 0
    private var timer: Timer?
    /// The switch's position from its click until the state reads back.
    private var asked: Bool?

    @MainActor private final class Section {
        let caption = PanelLabel(size: 9.5, bold: true)
        let divider = PanelDivider()
        let list = ScrollList(maxHeight: 400)
        let name: String
        var listed: [Row] = []
        var listHeight: CGFloat = 0

        init(_ name: String) { self.name = name }
    }

    private struct Row: Equatable {
        var device: BluetoothDevice
        var pending: BluetoothAction?
        /// While another device waits, as one click at a time.
        var waiting: Bool
    }

    init(bluetooth: Bluetooth) {
        self.bluetooth = bluetooth
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        for view in [icon, title, caption, power, note] as [NSView] { addSubview(view) }
        for section in sections {
            for view in [section.divider, section.caption, section.list] as [NSView] { addSubview(view) }
        }
        power.action = { [weak self] in self?.togglePower() }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func restyle() {
        power.theme = theme
        for section in sections {
            section.divider.theme = theme
            section.list.theme = theme
            section.listed = []
        }
        glyphs = [:]
        update()
    }

    /// Starts the caption's phrases and reads the devices again, for their batteries.
    func open() {
        timer?.invalidate()
        phrase = Int.random(in: 0..<bluetoothPhrases.count)
        let timer = Timer(timeInterval: 2.8, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.phrase += 1
                self.update()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        bluetooth.opened()
        update()
    }

    func close() {
        timer?.invalidate()
        timer = nil
    }

    private func togglePower() {
        guard let on = bluetooth.state.powered else { return }
        asked = !on
        bluetooth.setPower(!on)
        update()
        // Back to what the state says if it never changes, as when the call is refused.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                self?.asked = nil
                self?.update()
            }
        }
    }

    // MARK: layout

    /// Sets every view from the state, lays them out, and tells the host when the height changes.
    func update() {
        let pad = Self.pad, width = Self.width, scale = window?.backingScaleFactor ?? 2
        let state = bluetooth.state
        if asked == state.powered { asked = nil }
        var y = pad

        // Header, as the network panel's.
        let iconState = state.icon ?? .off
        icon.image = glyphImage(iconState.glyph, size: 28, color: iconState == .off ? theme.dim : theme.foreground, scale: scale)
        icon.frame = NSRect(x: pad, y: y + 4, width: 32, height: 32)
        power.isHidden = state.powered == nil
        power.isOn = asked ?? state.powered ?? false
        power.frame = NSRect(x: width - pad - 36, y: y + 8, width: 36, height: 24)
        let textX = pad + 32 + 14, textWidth = width - pad - 36 - 12 - textX
        title.set("Bluetooth", color: theme.foreground.nsColor)
        title.frame = NSRect(x: textX, y: y + 1, width: textWidth, height: title.lineHeight)
        caption.set(bluetoothCaption(powered: state.powered, phrase: phrase).uppercased(), color: theme.dim.nsColor, kern: 1.2)
        caption.frame = NSRect(x: textX, y: title.frame.maxY + 2, width: textWidth, height: caption.lineHeight)
        y += 40 + 12

        // While off, macOS connects nothing, so the lists give way to a note.
        let on = state.powered == true
        let lists = [state.connected, state.available]
        for (section, devices) in zip(sections, lists) {
            let shows = on && !devices.isEmpty
            for view in [section.divider, section.caption, section.list] as [NSView] { view.isHidden = !shows }
            guard shows else { continue }
            section.divider.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: 9)
            y += 9 + 8
            section.caption.set(section.name, color: theme.dim.nsColor, kern: 1.2)
            section.caption.frame = NSRect(x: pad, y: y, width: 200, height: section.caption.lineHeight)
            y += section.caption.lineHeight + 6
            let rows = devices.map { device in
                Row(device: device, pending: bluetooth.pending[device.address],
                    waiting: !bluetooth.pending.isEmpty && bluetooth.pending[device.address] == nil)
            }
            if rows != section.listed {
                section.listed = rows
                build(section, rows, width: width - 2 * pad + 8, scale: scale)
            }
            section.list.frame = NSRect(x: pad - 4, y: y, width: width - 2 * pad + 8, height: section.listHeight)
            y += section.listHeight + 6
        }

        let empty = lists.allSatisfy(\.isEmpty)
        note.isHidden = on && !empty
        if !note.isHidden {
            let text = switch state.powered {
            case nil: "No Bluetooth adapter"
            case false: "Turn Bluetooth on to connect"
            case true: "No paired devices; pair them in System Settings"
            }
            note.set(text, color: theme.dim.nsColor)
            note.frame = NSRect(x: pad, y: y + 4, width: width - 2 * pad, height: note.lineHeight)
            y += note.lineHeight + 12
        }
        y += pad - 6
        if frame.height != y {
            frame.size = NSSize(width: width, height: y)
            resized?()
        }
    }

    /// The rows, made again only when what they show changes.
    private func build(_ section: Section, _ rows: [Row], width: CGFloat, scale: CGFloat) {
        let views = rows.map { row -> (view: NSView, height: CGFloat) in
            let device = row.device
            let color = device.connected ? theme.foreground : theme.dim
            let image = bluetoothSymbol(device).flatMap { panelSymbol($0, pointSize: 13, color: color, scale: scale) }
                ?? glyphImage(BluetoothIcon.on.glyph, size: 15, color: color, scale: scale)
            let view = DeviceRow(device.name, status: bluetoothStatus(device, pending: row.pending), image: image,
                                 current: device.connected, theme: theme, width: width)
            view.isEnabled = row.pending == nil && !row.waiting
            view.action = { [weak self] in
                if device.connected { self?.bluetooth.disconnect(device.address) } else { self?.bluetooth.connect(device.address) }
            }
            return (view, DeviceRow.height)
        }
        section.listHeight = section.list.set(views, width: width)
    }

    /// The glyphs drawn so far, as cropping one to its ink scans every pixel.
    private var glyphs: [String: NSImage] = [:]

    /// A Nerd Font glyph cropped to its ink, as the network panel draws its Ethernet glyph.
    private func glyphImage(_ text: String, size: CGFloat, color: RGBA, scale: CGFloat) -> NSImage? {
        let key = "\(text) \(size) \(color) \(scale)"
        if let image = glyphs[key] { return image }
        let image = inkImage(glyph(text, font: panelFont(size), color: color.nsColor), scale: scale).map { NSImage(cgImage: $0.0, size: $0.1) }
        glyphs[key] = image
        return image
    }
}

/// A device's row: its icon, its name, and under it the action it waits for or its battery, on
/// the current row's fill while connected.
private final class DeviceRow: PanelRow {
    static let height: CGFloat = 38

    init(_ name: String, status: String, image: NSImage?, current: Bool, theme: Theme, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        self.theme = theme
        self.current = current
        let icon = PanelImage()
        icon.image = image
        icon.frame = NSRect(x: 6, y: 0, width: 24, height: Self.height)
        addSubview(icon)
        let label = PanelLabel(size: 11.5)
        label.set(name, color: theme.foreground.nsColor)
        addSubview(label)
        let x: CGFloat = 38, labelWidth = width - x - 8
        guard !status.isEmpty else {
            label.frame = NSRect(x: x, y: ((Self.height - label.lineHeight) / 2).rounded(), width: labelWidth, height: label.lineHeight)
            return
        }
        let line = PanelLabel(size: 9.5)
        line.set(status, color: (current ? theme.foreground : theme.dim).nsColor)
        let top = ((Self.height - label.lineHeight - line.lineHeight) / 2).rounded()
        label.frame = NSRect(x: x, y: top, width: labelWidth, height: label.lineHeight)
        line.frame = NSRect(x: x, y: top + label.lineHeight, width: labelWidth, height: line.lineHeight)
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }
}
