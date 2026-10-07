import AppKit
@preconcurrency import CoreWLAN
import ZenithBarCore
import ZenithBarKit

/// The network item's panel, after Omarchy 4's (docs/network.md, the panel): a header with the
/// connection's icon and name, the speed test and the Wi-Fi switch; a grid of live figures for
/// the primary interface, read only while it shows; and the Wi-Fi networks from a scan when it
/// opens, which a click joins, leaves or forgets.
@MainActor final class NetworkPanel: FlippedView {
    /// What the controller does for it: take and give back the keyboard for the password
    /// field, place the panel again when its height changes, and close it when the pointer is
    /// off it.
    struct Host {
        var takeKeyboard: @MainActor (NSView) -> Void
        var giveKeyboardBack: @MainActor () -> Void
        var resized: @MainActor () -> Void
        var pointerMayHaveLeft: @MainActor () -> Void
    }

    enum Status: Equatable {
        case connecting, disconnecting, forgetting
        case failed(String)

        var text: String {
            switch self {
            case .connecting: "Connecting…"
            case .disconnecting: "Disconnecting…"
            case .forgetting: "Forgetting…"
            case let .failed(reason): reason
            }
        }
    }

    private let network: Network
    private let wifi: Wifi
    var host: Host?
    var theme = Theme.fallback { didSet { if theme != oldValue { restyle() } } }
    private(set) var isOpen = false

    // Live figures.
    private lazy var sampler = NetworkSampler { [weak self] sample in self?.received(sample) }
    private var counters: Counters?
    private var rates: (received: Double, sent: Double)?
    private var linkSpeed: UInt64 = 0
    private var router = PingHistory(), internet = PingHistory()
    private lazy var speedTest = SpeedTest { [weak self] in self?.update() }
    private var phrase = 0
    private var timer: Timer?

    // Wi-Fi, read when it opens and at each change, as each read asks airportd or locationd.
    private var read = (ssid: String?.none, band: WifiBand?.none, known: Set<String>(), allowed: false, undecided: false)
    private var scanned: [CWNetwork] = []
    private var scanning = false
    private var statuses: [String: Status] = [:]
    /// The network whose row shows the password field.
    private var asking: String?
    private var listed: [ListEntry] = []

    // Views.
    static let width: CGFloat = 460
    private static let pad: CGFloat = 16
    private let icon = PanelImage()
    private let title = PanelLabel(size: 14, bold: true)
    private let caption = PanelLabel(size: 9.5, bold: true)
    private let speedButton = PanelButton(symbol: "gauge.with.needle", pointSize: 15)
    private let wifiSwitch = PanelSwitch()
    private let speedLabel = PanelLabel(size: 11)
    private let speedValue = PanelLabel(size: 11, alignment: .right)
    private var grid: [(label: PanelLabel, value: PanelLabel)] = []
    private let copyAddress = CopyButton(), copyRouter = CopyButton()
    private let divider = PanelDivider()
    private let wifiCaption = PanelLabel(size: 9.5, bold: true)
    private let allowButton = TextButton()
    private let list = ScrollList(maxHeight: 240)
    private let labels = [("Ping", "Packet Loss"), ("Router Ping", "Router Loss"), ("Receiving", "Sending"),
                          ("Downloaded", "Uploaded"), ("IP Address", "Gateway")]

    init(network: Network) {
        self.network = network
        wifi = Wifi(client: network.client)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        for view in [icon, title, caption, speedButton, wifiSwitch, speedLabel, speedValue, divider, wifiCaption,
                     allowButton, list] as [NSView] { addSubview(view) }
        for _ in labels {
            for _ in 0..<2 {
                let pair = (PanelLabel(size: 11.5), PanelLabel(size: 11.5, alignment: .right))
                addSubview(pair.0)
                addSubview(pair.1)
                grid.append(pair)
            }
        }
        addSubview(copyAddress)
        addSubview(copyRouter)
        speedButton.action = { [weak self] in self?.speedTest.start() }
        wifiSwitch.action = { [weak self] in self?.togglePower() }
        allowButton.text = "Allow"
        allowButton.action = { [weak self] in self?.askForNames() }
        wifi.watchNames { [weak self] in self?.namesChanged() }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func restyle() {
        for control in [speedButton, wifiSwitch, copyAddress, copyRouter, allowButton] as [PanelControl] {
            control.theme = theme
        }
        divider.theme = theme
        list.theme = theme
        listed = []
        update()
    }

    // MARK: open and close

    /// Starts the figures, the caption's phrases and a scan.
    func open() {
        guard !isOpen else { return update() }
        isOpen = true
        phrase = Int.random(in: 0..<connectionPhrases.count)
        let timer = Timer(timeInterval: 2.8, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.phrase += 1
                self.update()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scanned = wifi.cached
        readWifi()
        scan()
        update()
    }

    private func readWifi() {
        read = (wifi.ssid, wifi.band, wifi.known, wifi.namesAllowed, wifi.namesUndecided)
    }

    /// Stops everything it reads, and forgets the figures, so the next open starts fresh.
    func close() {
        isOpen = false
        timer?.invalidate()
        timer = nil
        sampler.stop()
        counters = nil
        rates = nil
        router = PingHistory()
        internet = PingHistory()
        asking = nil
        statuses = statuses.filter { if case .failed = $0.value { false } else { true } }
    }

    /// The network changed, as its events or the store told.
    func refresh() {
        guard isOpen else { return }
        readWifi()
        update()
    }

    private func scan() {
        guard network.wifiPower == true, !scanning else { return }
        scanning = true
        wifi.scan { [weak self] found in
            guard let self else { return }
            scanning = false
            if let found { scanned = found }
            readWifi()
            update()
        }
    }

    // MARK: figures

    private func received(_ sample: NetworkSampler.Sample) {
        if let next = sample.counters {
            rates = next.rates(since: counters) ?? rates
            counters = next
        }
        linkSpeed = sample.linkSpeed
        if let routerAddress = network.primary?.router, let reply = sample.replies[routerAddress] { router.append(reply) }
        if let reply = sample.replies[NetworkSampler.internet] { internet.append(reply) }
        update()
    }

    // MARK: Wi-Fi actions

    private func togglePower() {
        guard let on = network.wifiPower else { return }
        wifiSwitch.isOn = !on
        wifi.setPower(!on) { [weak self] failure in
            guard let self else { return }
            if failure != nil { log.error("Could not turn Wi-Fi \(on ? "off" : "on")") }
            network.read()
            readWifi()
            if !on { scan() }
            update()
        }
    }

    private func askForNames() {
        wifi.askForNames { [weak self] in self?.namesChanged() }
    }

    private func namesChanged() {
        guard isOpen else { return }
        readWifi()
        scan()
        update()
    }

    /// An action runs, so the other rows wait, as Omarchy's do.
    private var busy: Bool { statuses.values.contains { !$0.isFailure } }

    private func clicked(_ row: WifiNetwork) {
        guard !busy, let ssid = row.ssid, ssid != asking else { return }
        if asking != nil { closePassword() }
        switch wifiClick(row) {
        case .none: return
        case .disconnect:
            act(ssid, .disconnecting) { done in self.wifi.disconnect(done: done) }
        case .askPassword:
            if row.enterprise {
                statuses[ssid] = .failed("Join it in System Settings once")
                return update()
            }
            openPassword(ssid)
        case .connect:
            guard let target = target(ssid) else { return }
            act(ssid, .connecting) { done in self.wifi.connect(target, password: nil, done: done) }
        }
    }

    private func forget(_ ssid: String) {
        guard !busy else { return }
        act(ssid, .forgetting) { done in self.wifi.forget(ssid, done: done) }
    }

    private func submit(_ ssid: String, password: String) {
        guard let target = target(ssid) else { return }
        closePassword()
        act(ssid, .connecting) { done in self.wifi.connect(target, password: password, done: done) }
    }

    /// Runs an action on `ssid`'s row, showing `status` until it ends, then its failure.
    private func act(_ ssid: String, _ status: Status, _ work: (@escaping @MainActor (String?) -> Void) -> Void) {
        statuses[ssid] = status
        update()
        work { [weak self] failure in
            guard let self else { return }
            statuses[ssid] = failure.map { .failed($0) }
            network.read()
            scanned = wifi.cached.isEmpty ? scanned : wifi.cached
            readWifi()
            // A wrong password, saved or typed, asks for it again, as Omarchy's row does.
            if failure == "Wrong password" { return openPassword(ssid) }
            update()
            host?.pointerMayHaveLeft()
        }
    }

    /// The strongest access point a scan found for `ssid`.
    private func target(_ ssid: String) -> CWNetwork? {
        scanned.filter { $0.ssid == ssid }.max { $0.rssiValue < $1.rssiValue }
    }

    private func openPassword(_ ssid: String) {
        asking = ssid
        update()
        if let field = passwordField { host?.takeKeyboard(field.field) }
    }

    private func closePassword() {
        asking = nil
        host?.giveKeyboardBack()
        update()
    }

    // MARK: layout

    private enum ListEntry: Equatable {
        case heading(String)
        case network(WifiNetwork, status: Status?, asking: Bool)
    }

    private var passwordField: PasswordField?
    /// The network `passwordField` was made for.
    private var fieldFor: String?

    /// Sets every view from what it knows, lays them out, and tells the host when the height
    /// changes.
    private func update() {
        let pad = Self.pad, width = Self.width, scale = window?.backingScaleFactor ?? 2
        let route = network.route
        let connected = network.primary != nil
        var y = pad

        // Header.
        let drawn = networkIcon(route)
        icon.image = headerIcon(drawn.icon, color: drawn.dim ? theme.dim : theme.foreground, scale: scale)
        icon.frame = NSRect(x: pad, y: y + 4, width: 32, height: 32)
        let hasWifi = network.wifiPower != nil
        wifiSwitch.isHidden = !hasWifi
        wifiSwitch.isOn = network.wifiPower == true
        var right = width - pad
        if hasWifi {
            wifiSwitch.frame = NSRect(x: right - 36, y: y + 8, width: 36, height: 24)
            right -= 36 + 6
        }
        speedButton.isHidden = !connected
        speedButton.isEnabled = !speedTest.running
        speedButton.active = speedTest.running
        speedButton.frame = NSRect(x: right - 30, y: y + 5, width: 30, height: 30)
        right -= 30 + 8
        let textX = pad + 32 + 12
        title.set(networkTitle(route, ssid: read.ssid, band: read.band, linkSpeed: linkSpeed), color: theme.foreground.nsColor)
        title.frame = NSRect(x: textX, y: y + 1, width: right - textX, height: title.lineHeight)
        caption.set((connected ? connectionPhrases[phrase % connectionPhrases.count] : "Not connected").uppercased(),
                    color: theme.dim.nsColor, kern: 1.2)
        caption.frame = NSRect(x: textX, y: title.frame.maxY + 2, width: right - textX, height: caption.lineHeight)
        y += 40 + 12

        // The speed test's progress or result.
        let speed: (String, String, Bool)? = switch speedTest.state {
        case .idle: nil
        case let .running(reading, started):
            ("Testing… \(Int(Date().timeIntervalSince(started)))s", reading.summary, false)
        case let .done(reading, at): ("Speed Test", reading.summary, Date().timeIntervalSince(at) > 3600)
        case let .failed(reason): (reason, "", true)
        }
        speedLabel.isHidden = speed == nil
        speedValue.isHidden = speed == nil
        if let (label, value, stale) = speed {
            speedLabel.set(label, color: theme.dim.nsColor)
            speedValue.set(value, color: (stale ? theme.dim : theme.foreground).nsColor)
            let lineHeight = speedLabel.lineHeight
            speedLabel.frame = NSRect(x: pad, y: y, width: 130, height: lineHeight)
            speedValue.frame = NSRect(x: pad + 130, y: y, width: width - 2 * pad - 130, height: lineHeight)
            y += lineHeight + 8
        }

        // The grid, for the primary interface.
        let service = network.primary
        if isOpen, let service {
            sampler.start(interface: service.interface, router: service.router)
        } else {
            sampler.stop()
        }
        let values: [(String, Bool)] = [
            (formatPing(internet.latency, hasSamples: internet.hasSamples), internet.lossPercent > 0),
            (internet.hasSamples ? "\(internet.lossPercent)%" : "--", internet.lossPercent > 0),
            (formatPing(router.latency, hasSamples: router.hasSamples), router.lossPercent > 0),
            (router.hasSamples ? "\(router.lossPercent)%" : "--", router.lossPercent > 0),
            (rates.map { formatRate($0.received) } ?? "--", false),
            (rates.map { formatRate($0.sent) } ?? "--", false),
            (counters.map { formatBytes(Double($0.received)) } ?? "--", false),
            (counters.map { formatBytes(Double($0.sent)) } ?? "--", false),
            (service?.address ?? "--", false),
            (service?.router ?? "--", false),
        ]
        let column = (width - 2 * pad - 24) / 2, rowHeight: CGFloat = 20
        copyAddress.value = service?.address
        copyRouter.value = service?.router
        for (index, (label, value)) in grid.enumerated() {
            label.isHidden = service == nil
            value.isHidden = service == nil
            guard service != nil else { continue }
            let row = index / 2, x = pad + CGFloat(index % 2) * (column + 24), top = y + CGFloat(row) * rowHeight
            let names = labels[row]
            label.set(index % 2 == 0 ? names.0 : names.1, color: theme.dim.nsColor)
            value.set(values[index].0, color: (values[index].1 ? theme.alert : theme.foreground).nsColor)
            let copy: CopyButton? = index == 8 ? copyAddress : index == 9 ? copyRouter : nil
            let room: CGFloat = copy == nil ? 0 : 20
            label.frame = NSRect(x: x, y: top, width: 90, height: label.lineHeight)
            value.frame = NSRect(x: x + 80, y: top, width: column - 80 - room, height: value.lineHeight)
            copy?.frame = NSRect(x: x + column - 18, y: top - 1, width: 18, height: 18)
        }
        copyAddress.isHidden = service?.address == nil
        copyRouter.isHidden = service?.router == nil
        if service != nil { y += CGFloat(labels.count) * rowHeight + 4 }

        // Wi-Fi.
        divider.isHidden = !hasWifi
        wifiCaption.isHidden = true
        allowButton.isHidden = true
        list.isHidden = true
        if hasWifi {
            divider.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: 9)
            y += 9 + 6
            y = layoutWifi(y: y, width: width, scale: scale)
        }
        y += pad - 4
        if frame.height != y {
            frame.size = NSSize(width: width, height: y)
            host?.resized()
        }
    }

    private func layoutWifi(y start: CGFloat, width: CGFloat, scale: CGFloat) -> CGFloat {
        let pad = Self.pad, y = start
        let note: String? = if network.wifiPower != true {
            "Wi-Fi off"
        } else if !read.allowed {
            read.undecided ? "Network names need Location Services"
                : "Allow ZenithBar in Location Services for names"
        } else if scanned.isEmpty {
            scanning ? "Scanning Wi-Fi…" : "No networks found"
        } else { nil }
        if let note {
            wifiCaption.isHidden = false
            wifiCaption.set(note.uppercased(), color: theme.dim.nsColor, kern: 1.2)
            let showsAllow = network.wifiPower == true && !read.allowed && read.undecided
            let room: CGFloat = showsAllow ? 64 : 0
            wifiCaption.frame = NSRect(x: pad, y: y + 4, width: width - 2 * pad - room, height: wifiCaption.lineHeight)
            if showsAllow {
                allowButton.isHidden = false
                allowButton.frame = NSRect(x: width - pad - 56, y: y, width: 56, height: 22)
            }
            return y + 24
        }
        let known = read.known, current = read.ssid
        let rows = wifiRows(scanned.map { found in
            WifiNetwork(ssid: found.ssid, rssi: found.rssiValue,
                        secure: !found.supportsSecurity(.none) && !found.supportsSecurity(.OWE),
                        enterprise: [.wpaEnterprise, .wpa2Enterprise, .wpa3Enterprise].contains { found.supportsSecurity($0) }
                            && ![.wpaPersonal, .wpa2Personal, .wpa3Personal, .wpa3Transition].contains { found.supportsSecurity($0) },
                        known: found.ssid.map(known.contains) ?? false,
                        connected: found.ssid != nil && found.ssid == current)
        })
        var entries: [ListEntry] = []
        for (index, row) in rows.enumerated() {
            if let heading = wifiSection(rows, at: index) { entries.append(.heading(heading)) }
            entries.append(.network(row, status: row.ssid.flatMap { statuses[$0] },
                                    asking: row.ssid != nil && row.ssid == asking))
        }
        if scanning { entries.insert(.heading("SCANNING WI-FI…"), at: 0) }
        list.isHidden = false
        // Kept while someone types a password, so a scan that ends then keeps the field.
        if entries != listed, asking == nil || asking != fieldFor {
            listed = entries
            build(entries, width: width - 2 * pad + 8, scale: scale)
        }
        list.frame = NSRect(x: pad - 4, y: y, width: width - 2 * pad + 8, height: listHeight)
        return y + listHeight
    }

    private var listHeight: CGFloat = 0

    /// The list's rows, made again only when what they show changes, as at a scan or an action.
    private func build(_ entries: [ListEntry], width: CGFloat, scale: CGFloat) {
        var views: [(view: NSView, height: CGFloat)] = []
        passwordField = nil
        fieldFor = nil
        for entry in entries {
            switch entry {
            case let .heading(text):
                let label = PanelLabel(size: 9.5, bold: true)
                label.set(text, color: theme.dim.nsColor, kern: 1.2)
                let holder = FlippedView()
                label.frame = NSRect(x: 4, y: 6, width: width - 8, height: label.lineHeight)
                holder.addSubview(label)
                views.append((holder, 22))
            case let .network(network, status, asking):
                let row = NetworkRow(network: network, status: status, theme: theme, scale: scale, width: width,
                                     disabled: busy)
                row.action = { [weak self] in self?.clicked(network) }
                row.forget = { [weak self] in network.ssid.map { self?.forget($0) } }
                if asking, let ssid = network.ssid {
                    let field = row.addPassword()
                    field.submitted = { [weak self] password in self?.submit(ssid, password: password) }
                    field.cancelled = { [weak self] in
                        self?.closePassword()
                        self?.host?.pointerMayHaveLeft()
                    }
                    field.wantsKeyboard = { [weak self, weak field] in
                        if let field { self?.host?.takeKeyboard(field.field) }
                    }
                    passwordField = field
                    fieldFor = ssid
                }
                views.append((row, row.height))
            }
        }
        listHeight = list.set(views, width: width)
        if let passwordField, let row = passwordField.superview { list.reveal(row) }
    }

    private var drawnIcon: (icon: NetworkIcon, color: RGBA, scale: CGFloat, image: NSImage?)?

    /// Drawn again only when it changes, as cropping it to its ink scans every pixel.
    private func headerIcon(_ icon: NetworkIcon, color: RGBA, scale: CGFloat) -> NSImage? {
        if let drawnIcon, drawnIcon.icon == icon, drawnIcon.color == color, drawnIcon.scale == scale { return drawnIcon.image }
        let image = switch icon {
        case let .symbol(name, value): panelSymbol(name, value: value, pointSize: 22, color: color, scale: scale)
        case let .glyph(text):
            inkImage(glyph(text, font: panelFont(28), color: color.nsColor), scale: scale).map { NSImage(cgImage: $0.0, size: $0.1) }
        }
        drawnIcon = (icon, color, scale, image)
        return image
    }

    // MARK: test hooks, in debug builds only (Controller.watchTestHooks)

    #if DEBUG
    /// Starts the speed test, as a click on its button.
    func pressSpeedTest() { speedTest.start() }
    /// Asks for names, as a click on Allow.
    func pressAllow() { askForNames() }
    /// Opens `ssid`'s password field, as a click on a secured network the Mac does not know.
    func pressPassword(_ ssid: String) { openPassword(ssid) }
    #endif
}

private extension NetworkPanel.Status {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

/// A network's row: its signal as the bar's Wi-Fi symbol, its name or "Hidden", its status
/// under it, and a lock when it needs a password, which a forget button replaces on hover for
/// a known network not joined. With `addPassword`, a password field under it.
private final class NetworkRow: PanelRow {
    var forget: (() -> Void)?
    private(set) var height: CGFloat = 34
    private let network: WifiNetwork
    private let forgetButton = PanelButton(symbol: "xmark.circle", pointSize: 11)
    private let lock = PanelImage()

    init(network: WifiNetwork, status: NetworkPanel.Status?, theme: Theme, scale: CGFloat, width: CGFloat, disabled: Bool) {
        self.network = network
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))
        self.theme = theme
        current = network.connected
        isEnabled = !disabled && network.ssid != nil
        let failed = if case .failed = status { true } else { false }
        let tint = failed ? theme.alert : theme.foreground
        let signal = PanelImage()
        signal.image = panelSymbol("wifi", value: Double(wifiLevel(rssi: network.rssi)) / 4, pointSize: 13,
                                   color: tint, scale: scale)
        signal.frame = NSRect(x: 6, y: 0, width: 24, height: 34)
        addSubview(signal)
        let name = PanelLabel(size: 11.5, bold: network.connected)
        name.set(network.ssid ?? "Hidden", color: (network.ssid == nil ? theme.dim : theme.foreground).nsColor)
        let statusText = status?.text ?? (network.connected ? "Connected" : nil)
        let nameHeight = name.lineHeight
        if let statusText {
            let line = PanelLabel(size: 9.5)
            line.set(statusText, color: (failed ? theme.alert : theme.dim).nsColor)
            let lineHeight = line.lineHeight, top = ((34 - nameHeight - lineHeight) / 2).rounded()
            name.frame = NSRect(x: 36, y: top, width: width - 36 - 34, height: nameHeight)
            line.frame = NSRect(x: 36, y: top + nameHeight, width: width - 36 - 34, height: lineHeight)
            addSubview(line)
        } else {
            name.frame = NSRect(x: 36, y: ((34 - nameHeight) / 2).rounded(), width: width - 36 - 34, height: nameHeight)
        }
        addSubview(name)
        lock.image = network.secure ? panelSymbol("lock.fill", pointSize: 10, color: theme.dim, scale: scale) : nil
        lock.frame = NSRect(x: width - 30, y: 0, width: 24, height: 34)
        addSubview(lock)
        forgetButton.theme = theme
        forgetButton.frame = NSRect(x: width - 31, y: 5, width: 24, height: 24)
        forgetButton.action = { [weak self] in self?.forget?() }
        forgetButton.isHidden = true
        addSubview(forgetButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Forget shows on hover, on a known network the Mac has not joined, as Omarchy's row.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let forgettable = network.known && !network.connected && isEnabled
        forgetButton.isHidden = !forgettable
        lock.isHidden = forgettable
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        forgetButton.isHidden = true
        lock.isHidden = false
    }

    /// Clicks on the password area belong to the field.
    override func mouseUp(with event: NSEvent) {
        guard convert(event.locationInWindow, from: nil).y < 34 else { return }
        super.mouseUp(with: event)
    }

    func addPassword() -> PasswordField {
        let field = PasswordField()
        field.theme = theme
        field.frame = NSRect(x: 36, y: 34, width: bounds.width - 36 - 8, height: 26)
        addSubview(field)
        height = 34 + 26 + 8
        frame.size.height = height
        return field
    }
}

/// A small text button with a border, as Allow.
final class TextButton: PanelControl {
    var text = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (hovered ? theme.hover : theme.foreground.with(alpha: 0.04).nsColor).setFill()
        box.fill()
        theme.foreground.with(alpha: 0.25).nsColor.setStroke()
        box.stroke()
        let label = NSAttributedString(string: text, attributes: [
            .font: panelFont(11), .foregroundColor: theme.foreground.nsColor,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
    }
}
