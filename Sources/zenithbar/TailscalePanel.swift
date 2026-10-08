import AppKit
import ZenithBarCore
import ZenithBarKit

/// The Tailscale panel, after Omarchy 4's (docs/tailscale.md, the panel): a header with
/// Tailscale's mark, this Mac's name, Omarchy's rotating caption and the on and off switch; then
/// MACHINES, the machines online, each with buttons to send it files and copy its address, and a
/// button to read them again; then OFFLINE, dim and without buttons. The machines are read when
/// it opens and on the refresh button; the switch and the mark follow `Tailscale`'s store.
@MainActor final class TailscalePanel: FlippedView {
    private let tailscale: Tailscale
    var host: PanelHost?
    var theme = Theme.fallback { didSet { if theme != oldValue { restyle() } } }

    static let width: CGFloat = 380
    private static let pad: CGFloat = 16
    private let icon = PanelImage()
    private let title = PanelLabel(size: 14, bold: true)
    private let caption = PanelLabel(size: 9.5, bold: true)
    private let power = PanelSwitch()
    private let divider = PanelDivider()
    private let machines = PanelLabel(size: 9.5, bold: true)
    private let refresh = PanelButton(symbol: "arrow.clockwise", pointSize: 11)
    private let onlineList = ScrollList(maxHeight: 400)
    private let offlineCaption = PanelLabel(size: 9.5, bold: true)
    private let offlineList = ScrollList(maxHeight: 200)
    private let note = PanelLabel(size: 11.5)
    private var isOpen = false
    private var phrase = 0
    private var timer: Timer?
    /// The switch's position from its click until the store reads back.
    private var asked: Bool?
    /// What the last click did, which the caption shows for 3 s while the panel is open, so a
    /// send that ends after it closed shows at the next open.
    private var said: String?
    private var saidCount = 0
    /// The machines files are on their way to, by name.
    private var sending: [String] = []
    private var listed: (online: [Row], offline: [Row]) = ([], [])
    private var mark: (color: RGBA, scale: CGFloat, image: NSImage?)?

    private struct Row: Equatable {
        var peer: TailscalePeer
        var sending: Bool
    }

    init(tailscale: Tailscale) {
        self.tailscale = tailscale
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        for view in [icon, title, caption, power, divider, machines, refresh, onlineList, offlineCaption, offlineList,
                     note] as [NSView] { addSubview(view) }
        power.action = { [weak self] in self?.togglePower() }
        refresh.action = { [weak self] in
            self?.tailscale.readStatus { read in self?.say(read ? "Refreshed" : "Could not read Tailscale") }
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func restyle() {
        for control in [power, refresh] as [PanelControl] { control.theme = theme }
        divider.theme = theme
        onlineList.theme = theme
        offlineList.theme = theme
        listed = ([], [])
        update()
    }

    /// Starts the caption's phrases and reads the machines.
    func open() {
        isOpen = true
        timer?.invalidate()
        phrase = Int.random(in: 0..<tailscalePhrases.count)
        let timer = Timer(timeInterval: 2.8, repeats: true) { _ in
            onMain {
                self.phrase += 1
                self.update()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if said != nil { forget(saidCount) }
        tailscale.readStatus()
        update()
    }

    func close() {
        isOpen = false
        timer?.invalidate()
        timer = nil
    }

    // MARK: actions

    private func togglePower() {
        guard let on = tailscale.on, !tailscale.switching else { return }
        asked = !on
        tailscale.turn(on: !on) { [weak self] error in
            guard let self else { return }
            if let error {
                self.asked = nil
                self.say(error)
            } else if self.isOpen, !on {
                self.tailscale.readStatus()
            }
        }
        update()
        // Back to what the store says if it never changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            onMain {
                self?.asked = nil
                self?.update()
            }
        }
    }

    /// Closes the panel, which would cover the picker, and sends the files picked, as Omarchy's
    /// omarchy-tailscale-send.
    private func pickFiles(for peer: TailscalePeer) {
        host?.close()
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.message = "Send to \(peer.name)"
        picker.prompt = "Send"
        // ZenithBar comes to the front so its picker takes the keyboard, and hands the front back
        // to the app that had it after; untested on screen (docs/tailscale.md, untested).
        let front = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        picker.begin { [weak self] response in
            onMain {
                front?.activate()
                guard let self, response == .OK, !picker.urls.isEmpty else { return }
                self.sending.append(peer.name)
                self.update()
                self.tailscale.send(picker.urls, to: peer) { error in
                    if let index = self.sending.firstIndex(of: peer.name) { self.sending.remove(at: index) }
                    self.say(error.map { "Could not send to \(peer.name): \($0)" } ?? "Sent to \(peer.name)")
                }
            }
        }
    }

    private func say(_ text: String) {
        said = text
        saidCount += 1
        if isOpen { forget(saidCount) }
        update()
    }

    /// Clears what `say` set 3 s from now, unless something newer was said.
    private func forget(_ count: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            onMain {
                guard let self, self.saidCount == count else { return }
                self.said = nil
                self.update()
            }
        }
    }

    // MARK: layout

    /// Sets every view from what `Tailscale` knows, lays them out, and tells the host when the
    /// height changes.
    func update() {
        let pad = Self.pad, width = Self.width, scale = window?.backingScaleFactor ?? 2
        let on = tailscale.on == true, status = tailscale.status
        if asked == tailscale.on { asked = nil }
        var y = pad

        // Header, as the Bluetooth panel's.
        icon.image = headerMark(color: on ? theme.foreground : theme.dim, scale: scale)
        icon.frame = NSRect(x: pad, y: y + 4, width: 32, height: 32)
        power.isHidden = tailscale.on == nil
        power.isOn = asked ?? on
        power.isEnabled = !tailscale.switching
        power.frame = NSRect(x: width - pad - 36, y: y + 8, width: 36, height: 24)
        let textX = pad + 32 + 14, textWidth = width - pad - 36 - 12 - textX
        title.set(status.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Tailscale", color: theme.foreground.nsColor)
        title.frame = NSRect(x: textX, y: y + 1, width: textWidth, height: title.lineHeight)
        let (text, accent) = captionText(on: on)
        caption.set(text.uppercased(), color: (accent ? theme.accent : theme.dim).nsColor, kern: 1.2)
        caption.frame = NSRect(x: textX, y: title.frame.maxY + 2, width: textWidth, height: caption.lineHeight)
        y += 40 + 12

        // MACHINES while on, then OFFLINE.
        for view in [divider, machines, refresh] as [NSView] { view.isHidden = !on }
        let lists = on && status?.running == true ? (status?.online ?? [], status?.offline ?? []) : ([], [])
        var message: String? = on ? nil : "Turn Tailscale on to see its machines"
        if on {
            divider.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: 9)
            y += 9 + 8
            machines.set("MACHINES", color: theme.dim.nsColor, kern: 1.2)
            machines.frame = NSRect(x: pad, y: y, width: 200, height: machines.lineHeight)
            refresh.isEnabled = !tailscale.reading
            refresh.active = tailscale.reading
            refresh.frame = NSRect(x: width - pad - 24, y: y + (machines.lineHeight - 24) / 2, width: 24, height: 24)
            y += machines.lineHeight + 6
            message = if let status {
                !status.running ? "Tailscale is \(status.backendState.lowercased()); refresh to read it again"
                    : lists.0.isEmpty ? "No machines online" : nil
            } else {
                tailscale.reading ? "Reading the machines…" : "Could not read Tailscale"
            }
        }
        let online = lists.0.map { Row(peer: $0, sending: sending.contains($0.name)) }
        let offline = lists.1.map { Row(peer: $0, sending: false) }
        if online != listed.online || offline != listed.offline {
            listed = (online, offline)
            build(online: online, offline: offline, width: width - 2 * pad + 8, scale: scale)
        }
        onlineList.isHidden = online.isEmpty
        if !online.isEmpty {
            onlineList.frame = NSRect(x: pad - 4, y: y, width: width - 2 * pad + 8, height: onlineHeight)
            y += onlineHeight + 6
        }
        note.isHidden = message == nil
        if let message {
            note.set(message, color: theme.dim.nsColor)
            note.frame = NSRect(x: pad, y: y + 4, width: width - 2 * pad, height: note.lineHeight)
            y += note.lineHeight + 12
        }
        offlineCaption.isHidden = offline.isEmpty
        offlineList.isHidden = offline.isEmpty
        if !offline.isEmpty {
            y += 6
            offlineCaption.set("OFFLINE", color: theme.dim.nsColor, kern: 1.2)
            offlineCaption.frame = NSRect(x: pad, y: y, width: 200, height: offlineCaption.lineHeight)
            y += offlineCaption.lineHeight + 6
            offlineList.frame = NSRect(x: pad - 4, y: y, width: width - 2 * pad + 8, height: offlineHeight)
            y += offlineHeight + 6
        }
        y += pad - 6
        if frame.height != y {
            frame.size = NSSize(width: width, height: y)
            host?.resized()
        }
    }

    /// What the last click did, a send going, else a phrase while on; and whether it is news,
    /// drawn in the accent.
    private func captionText(on: Bool) -> (String, Bool) {
        if let said { return (said, true) }
        if let name = sending.last { return ("Sending to \(name)…", true) }
        return on ? (tailscalePhrases[phrase % tailscalePhrases.count], false) : ("Disconnected", false)
    }

    private var onlineHeight: CGFloat = 0, offlineHeight: CGFloat = 0

    /// The rows, made again only when what they show changes.
    private func build(online: [Row], offline: [Row], width: CGFloat, scale: CGFloat) {
        onlineHeight = onlineList.set(online.map { row in
            let peer = row.peer
            let view = PeerRow(peer, line: [peer.ip, peer.dnsName.isEmpty ? nil : peer.dnsName].compactMap { $0 }
                .joined(separator: " · "), image: osImage(peer, color: theme.foreground, scale: scale), theme: theme,
                width: width)
            view.send.isHidden = !peer.taildrop
            view.send.active = row.sending
            view.send.action = { [weak self] in self?.pickFiles(for: peer) }
            view.copy.value = peer.ip
            view.copy.copied = { [weak self] ip in self?.say("Copied \(ip)") }
            return (view, PeerRow.height)
        }, width: width)
        offlineHeight = offlineList.set(offline.map { row in
            let peer = row.peer
            let view = PeerRow(peer, line: [tailscaleOS(peer.os).name, peer.ip].compactMap { $0 }.joined(separator: " · "),
                               image: osImage(peer, color: theme.dim, scale: scale), theme: theme, width: width)
            view.isEnabled = false
            view.send.isHidden = true
            view.copy.value = nil
            return (view, PeerRow.height)
        }, width: width)
    }

    private func osImage(_ peer: TailscalePeer, color: RGBA, scale: CGFloat) -> NSImage? {
        panelGlyph(tailscaleOS(peer.os).glyph, size: 15, color: color, scale: scale)
    }

    /// Tailscale's mark at 28 pt, drawn again only when its color or scale changes, as cropping
    /// it scans every pixel.
    private func headerMark(color: RGBA, scale: CGFloat) -> NSImage? {
        if let mark, mark.color == color, mark.scale == scale { return mark.image }
        let image = inkImage(tailscaleMark(size: 26, color: color.nsColor), scale: scale).map { NSImage(cgImage: $0.0, size: $0.1) }
        mark = (color, scale, image)
        return image
    }
}

/// A machine's row: its OS's logo, its name, and under it its address and DNS name, or its OS
/// and address while offline; at the right, while online, the send and copy buttons.
private final class PeerRow: PanelRow {
    static let height: CGFloat = 38
    let send = PanelButton(symbol: "paperplane.fill", pointSize: 12)
    let copy = CopyButton(pointSize: 12)

    init(_ peer: TailscalePeer, line: String, image: NSImage?, theme: Theme, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        self.theme = theme
        let icon = PanelImage()
        icon.image = image
        icon.frame = NSRect(x: 6, y: 0, width: 24, height: Self.height)
        addSubview(icon)
        let color = peer.online ? theme.foreground : theme.dim
        let name = PanelLabel(size: 11.5), detail = PanelLabel(size: 9.5)
        name.set(peer.name, color: color.nsColor)
        detail.set(line, color: theme.dim.nsColor)
        let x: CGFloat = 38, labelWidth = width - x - (peer.online ? 2 * 28 + 8 : 8)
        let top = ((Self.height - name.lineHeight - detail.lineHeight) / 2).rounded()
        name.frame = NSRect(x: x, y: top, width: labelWidth, height: name.lineHeight)
        detail.frame = NSRect(x: x, y: top + name.lineHeight, width: labelWidth, height: detail.lineHeight)
        for view in [name, detail] { addSubview(view) }
        guard peer.online else { return }
        send.theme = theme
        copy.theme = theme
        copy.frame = NSRect(x: width - 6 - 26, y: (Self.height - 26) / 2, width: 26, height: 26)
        send.frame = NSRect(x: copy.frame.minX - 2 - 26, y: copy.frame.minY, width: 26, height: 26)
        addSubview(send)
        addSubview(copy)
    }

    required init?(coder: NSCoder) { fatalError() }
}
