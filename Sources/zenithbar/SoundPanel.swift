import AppKit
import CoreAudio
import ZenithBarCore

/// The sound panel, after Omarchy 4's audio panel (docs/sound.md, the panel): a header with the
/// output's icon, "Audio", the volume's name and a switch, labelled SOUND & MIC, that mutes both; then OUTPUT and
/// INPUT, each with its level, a slider and every device, the default one highlighted, which a
/// click makes the default. It shows `Sound`'s state, which CoreAudio's listeners keep current
/// whether or not it is open, so it follows the volume keys, System Settings and other apps.
@MainActor final class SoundPanel: FlippedView {
    private let sound: Sound
    /// Places the panel again when its height changes.
    var resized: (@MainActor () -> Void)?
    var theme = Theme.fallback { didSet { if theme != oldValue { restyle() } } }

    static let width: CGFloat = 380
    private static let pad: CGFloat = 16
    private let icon = PanelImage()
    private let title = PanelLabel(size: 14, bold: true)
    private let caption = PanelLabel(size: 9.5, bold: true)
    private let master = PanelSwitch()
    /// Says what the switch mutes, as on its own it read as a mystery (Steve, 2026-10-07).
    private let masterLabel = PanelLabel(size: 9.5, bold: true, alignment: .right)
    /// The setting that keeps the MacBook's microphone when macOS moves the input to a headset,
    /// under INPUT (docs/sound.md, preferBuiltInMic).
    private let preferLabel = PanelLabel(size: 9.5, bold: true)
    private let preferSwitch = PanelSwitch()
    /// The switch was flipped to this.
    var preferChanged: (@MainActor (Bool) -> Void)?
    private let sections: [Section]
    private let dividers = [PanelDivider(), PanelDivider()]

    /// One direction's caption, percent, slider and devices.
    @MainActor private final class Section {
        let direction: AudioDirection
        let caption = PanelLabel(size: 9.5, bold: true)
        let percent = PanelLabel(size: 9.5, bold: true, alignment: .right)
        let slider = PanelSlider()
        let list = ScrollList(maxHeight: 200)
        var listed: [Row] = []
        var listHeight: CGFloat = 0
        /// The device a drag moves, held from its start, so a default that changes mid-drag ends it.
        var dragging: AudioObjectID?

        init(_ direction: AudioDirection) { self.direction = direction }
    }

    private struct Row: Equatable {
        var id: AudioObjectID
        var name: String
        var symbol: String
        var current: Bool
        var selectable: Bool
    }

    init(sound: Sound) {
        self.sound = sound
        sections = [Section(.output), Section(.input)]
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        for view in [icon, title, caption, master, masterLabel, preferLabel, preferSwitch] + dividers as [NSView] { addSubview(view) }
        for section in sections {
            for view in [section.caption, section.percent, section.slider, section.list] as [NSView] { addSubview(view) }
            section.slider.moved = { [weak self, unowned section] value in self?.moved(section, to: value) }
            section.slider.rightClicked = { [weak self, unowned section] in
                self?.sound.toggleMute(section.direction, because: "panel \(section.direction) slider right click")
            }
        }
        master.action = { [weak self] in self?.sound.toggleAll() }
        preferSwitch.action = { [weak self] in
            guard let self else { return }
            self.preferChanged?(!self.sound.preferBuiltInMic)
            self.update()
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func restyle() {
        master.theme = theme
        preferSwitch.theme = theme
        for divider in dividers { divider.theme = theme }
        for section in sections {
            section.slider.theme = theme
            section.list.theme = theme
            section.listed = []
        }
        update()
    }

    // MARK: actions

    /// Sets the level of the device the drag started on, while it stays the default.
    private func moved(_ section: Section, to value: Double) {
        let current = sound.state.defaultDevice(section.direction)?.id
        guard let target = section.dragging ?? current, target == current else {
            section.slider.cancelDrag()
            section.dragging = nil
            return update()
        }
        section.dragging = target
        sound.setVolume(target, section.direction, value, because: "panel \(section.direction) slider")
        update()
    }

    // MARK: layout

    /// Sets every view from the state, lays them out, and tells the host when the height changes.
    func update() {
        let pad = Self.pad, width = Self.width, scale = window?.backingScaleFactor ?? 2
        let state = sound.state
        let output = state.defaultDevice(.output)
        let outputSlider = sections[0].slider
        let shownVolume = outputSlider.dragged ?? output?.output?.volume ?? 1
        let muted = output?.output?.muted ?? false
        var y = pad

        // Header.
        let symbol = outputSymbol(output, bluetooth: output.flatMap { sound.bluetooth(for: $0) })
        icon.image = panelSymbol(symbol.name, pointSize: 22, color: symbol.dim ? theme.dim : theme.foreground, scale: scale)
        icon.frame = NSRect(x: pad, y: y + 4, width: 32, height: 32)
        master.isOn = state.switchOn
        master.frame = NSRect(x: width - pad - 36, y: y + 8, width: 36, height: 24)
        masterLabel.set("SOUND & MIC", color: theme.dim.nsColor, kern: 1.2)
        let labelWidth: CGFloat = 96
        masterLabel.frame = NSRect(x: master.frame.minX - 8 - labelWidth, y: master.frame.midY - masterLabel.lineHeight / 2,
                                   width: labelWidth, height: masterLabel.lineHeight)
        let textX = pad + 32 + 14, textWidth = masterLabel.frame.minX - 8 - textX
        title.set("Audio", color: theme.foreground.nsColor)
        title.frame = NSRect(x: textX, y: y + 1, width: textWidth, height: title.lineHeight)
        caption.set(outputVolumeName(shownVolume, muted: muted).uppercased(), color: theme.dim.nsColor, kern: 1.2)
        caption.frame = NSRect(x: textX, y: title.frame.maxY + 2, width: textWidth, height: caption.lineHeight)
        y += 40 + 12

        for (index, section) in sections.enumerated() {
            let devices = state.devices(section.direction)
            let shows = section.direction == .output || !devices.isEmpty
            let divider = dividers[index]
            for view in [divider, section.caption, section.percent, section.slider, section.list] as [NSView] {
                view.isHidden = !shows
            }
            guard shows else { continue }
            divider.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: 9)
            y += 9 + 8
            y = layout(section, state: state, y: y, width: width, scale: scale)
        }
        // Under INPUT, while there is one.
        let inputShows = !sections[1].list.isHidden
        preferLabel.isHidden = !inputShows
        preferSwitch.isHidden = !inputShows
        if inputShows {
            preferLabel.set("PREFER MACBOOK MIC", color: theme.dim.nsColor, kern: 1.2)
            preferSwitch.isOn = sound.preferBuiltInMic
            preferSwitch.frame = NSRect(x: width - pad - 36, y: y + 2, width: 36, height: 24)
            preferLabel.frame = NSRect(x: pad, y: preferSwitch.frame.midY - preferLabel.lineHeight / 2,
                                       width: preferSwitch.frame.minX - 8 - pad, height: preferLabel.lineHeight)
            y += 28
        }
        y += pad - 6
        if frame.height != y {
            frame.size = NSSize(width: width, height: y)
            resized?()
        }
    }

    private func layout(_ section: Section, state: SoundState, y start: CGFloat, width: CGFloat, scale: CGFloat) -> CGFloat {
        let pad = Self.pad, direction = section.direction
        let device = state.defaultDevice(direction), side = device?.side(direction)
        var y = start
        let slider = section.slider
        // A drag ends when its device stops being the default, as when AirPods leave.
        if slider.dragged == nil {
            section.dragging = nil
        } else if section.dragging != device?.id {
            slider.cancelDrag()
            section.dragging = nil
        }
        let level = slider.dragged ?? side?.volume
        let muted = side?.muted ?? false
        section.caption.set(direction == .output ? "OUTPUT" : "INPUT", color: theme.dim.nsColor, kern: 1.2)
        section.percent.set(volumePercent(level), color: (muted ? theme.dim : theme.foreground).nsColor.withAlphaComponent(0.7))
        let lineHeight = section.caption.lineHeight
        section.caption.frame = NSRect(x: pad, y: y, width: 120, height: lineHeight)
        section.percent.frame = NSRect(x: width - pad - 6 - 80, y: y, width: 80, height: lineHeight)
        y += lineHeight + 4
        // A side without a volume, as Steve's monitors, shows the slider disabled.
        slider.isEnabled = side?.volume != nil && side?.volumeSettable == true
        slider.dimmed = muted
        slider.value = side?.volume ?? 0
        slider.frame = NSRect(x: pad - 4, y: y, width: width - 2 * pad + 8, height: 24)
        y += 24 + 6

        let rows = state.listed(direction).map { device in
            let bluetooth = sound.bluetooth(for: device)
            return Row(id: device.id, name: device.name, symbol: deviceSymbol(device, direction, bluetooth: bluetooth),
                       current: device.id == state.defaultDevice(direction)?.id,
                       selectable: device.side(direction)?.canBeDefault == true)
        }
        if rows != section.listed {
            section.listed = rows
            build(section, rows, width: width - 2 * pad + 8, scale: scale)
        }
        section.list.frame = NSRect(x: pad - 4, y: y, width: width - 2 * pad + 8, height: section.listHeight)
        return y + section.listHeight + 4
    }

    /// The rows, made again only when what they show changes, as when a device comes or goes or
    /// the default changes.
    private func build(_ section: Section, _ rows: [Row], width: CGFloat, scale: CGFloat) {
        let views = rows.map { row -> (view: NSView, height: CGFloat) in
            let view = DeviceRow(row.name, symbol: row.symbol, current: row.current, selectable: row.selectable,
                                 theme: theme, scale: scale, width: width)
            view.action = { [weak self] in self?.sound.choose(row.id, section.direction) }
            return (view, DeviceRow.height)
        }
        section.listHeight = section.list.set(views, width: width)
    }
}

/// A device's row: its icon and name, bold and highlighted for the default. A device macOS
/// will not make the default shows dim and takes no click.
private final class DeviceRow: PanelRow {
    static let height: CGFloat = 32

    init(_ name: String, symbol: String, current: Bool, selectable: Bool, theme: Theme, scale: CGFloat, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        self.theme = theme
        self.current = current
        isEnabled = selectable && !current
        let color = selectable || current ? theme.foreground : theme.dim
        let icon = PanelImage()
        icon.image = panelSymbol(symbol, pointSize: 13, color: color, scale: scale)
        icon.frame = NSRect(x: 6, y: 0, width: 24, height: Self.height)
        addSubview(icon)
        let label = PanelLabel(size: 11.5, bold: current)
        label.set(name, color: color.nsColor)
        label.frame = NSRect(x: 38, y: ((Self.height - label.lineHeight) / 2).rounded(), width: width - 38 - 8,
                             height: label.lineHeight)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
}
