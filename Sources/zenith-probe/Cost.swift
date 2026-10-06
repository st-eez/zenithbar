// What an update of the bar costs the bar's process and WindowServer (docs/overview.md).
//
//   zenith-probe cost [updates] [text|image|sketchybar...]
//       A 14 item probe bar along the top of the built-in display, 20 updates a second, each
//       changing one item's text to another width and moving the items after it, against an
//       idle stretch as long. Reports CPU per update of the probe and of WindowServer, and the
//       probe's main thread time per update.
//       text        each item a CATextLayer, measured with NSAttributedString
//       image       each item's text laid out with CoreText and drawn into its layer's contents
//       sketchybar  the same updates to an item added to the running SketchyBar through its CLI,
//                   on the built-in display, against SketchyBar's CPU; the item is removed after
//       Default: 300 updates, text then image. Takes about updates / 10 s a mode.
import AppKit
import CoreText

private let rate = 20.0, barHeight: CGFloat = 25, padding: CGFloat = 8, spacing: CGFloat = 6
private let words = ["1", "1 ab", "1 abcdef"]

@MainActor private final class Strip {
    let panel: BarPanel
    let image: Bool
    var items: [CALayer] = []
    var widths: [CGFloat] = []
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let scale: CGFloat
    /// ms spent setting text, laying out, and committing, over every update.
    var phases = [0.0, 0.0, 0.0]

    init(on screen: NSScreen, image: Bool) {
        self.image = image
        scale = screen.backingScaleFactor
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - barHeight, width: screen.frame.width,
                           height: barHeight)
        panel = BarPanel(frame: frame, level: .statusBar, behavior: [.canJoinAllSpaces, .stationary])
        let view = layerView(NSRect(origin: .zero, size: frame.size))
        view.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        panel.contentView = view
        for index in 0..<14 {
            let item = image ? CALayer() : CATextLayer()
            item.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
            item.cornerRadius = 6
            item.contentsScale = scale
            view.layer?.addSublayer(item)
            items.append(item)
            widths.append(0)
            set(index, "item \(index)")
        }
        layout(from: 0)
        panel.orderFrontRegardless()
    }

    /// Gives item `index` its text and width, and moves the items after it.
    func update(_ index: Int, _ text: String) {
        let clock = ContinuousClock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        phases[0] += ms(clock.measure { set(index, text) })
        phases[1] += ms(clock.measure { layout(from: index) })
        phases[2] += ms(clock.measure {
            CATransaction.commit()
            CATransaction.flush()
        })
    }

    private func set(_ index: Int, _ text: String) {
        if let layer = items[index] as? CATextLayer {
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            layer.string = string
            widths[index] = ceil(string.size().width) + 2 * padding
        } else {
            let line = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, text as CFString,
                                         [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor.white]
                                             as CFDictionary)!)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let textWidth = ceil(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let size = CGSize(width: textWidth + 2 * padding, height: barHeight - 6)
            let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            context.scaleBy(x: scale, y: scale)
            context.textPosition = CGPoint(x: padding, y: (size.height - ascent + descent) / 2)
            CTLineDraw(line, context)
            items[index].contents = context.makeImage()
            widths[index] = size.width
        }
    }

    private func layout(from index: Int) {
        var x = 20 + widths[..<index].reduce(0) { $0 + $1 + spacing }
        for item in index..<items.count {
            items[item].frame = CGRect(x: x, y: 3, width: widths[item], height: barHeight - 6)
            x += widths[item] + spacing
        }
    }
}

/// CPU in ms of the probe, WindowServer and an optional third process over `seconds` of the
/// event loop while `tick` runs `rate` times a second, or idle when `tick` is nil.
@MainActor private func measure(_ seconds: Double, other: pid_t?, tick: (@MainActor () -> Void)?)
    -> (probe: Double, server: Double, other: Double?)
{
    let server = pid(of: "WindowServer")!
    let probe0 = rusageCPU(getpid())!, server0 = psCPU(server)!, other0 = other.flatMap(rusageCPU)
    var timer: Timer?
    if let tick {
        timer = Timer(timeInterval: 1 / rate, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer!, forMode: .common)
    }
    pumpEvents(seconds)
    timer?.invalidate()
    let otherCPU = other.flatMap(rusageCPU).flatMap { now in other0.map { now - $0 } }
    return (rusageCPU(getpid())! - probe0, psCPU(server)! - server0, otherCPU)
}

@MainActor func cost(updates: Int, modes: [String]) -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let screen = builtInScreen(), seconds = Double(updates) / rate
    print("\(updates) updates at \(Int(rate)) a second; CPU per update is the busy stretch less an idle one as long")
    for mode in modes.isEmpty ? ["text", "image"] : modes {
        if mode == "sketchybar" {
            sketchyBar(updates: updates, seconds: seconds, on: screen)
            continue
        }
        guard mode == "text" || mode == "image" else {
            print("unknown mode \(mode)")
            exit(2)
        }
        let strip = Strip(on: screen, image: mode == "image")
        pumpEvents(0.5)
        let idle = measure(seconds, other: nil, tick: nil)
        var count = 0, mainThread = 0.0
        let busy = measure(seconds, other: nil) {
            mainThread += ms(ContinuousClock().measure { strip.update(1, words[count % words.count]) })
            count += 1
        }
        let n = Double(count)
        print(String(format: "%@: %d updates, main thread %.3f ms/update, probe %.3f ms/update, WindowServer %.2f ms/update"
            + " (idle: probe %.0f ms, WindowServer %.0f ms over %.0f s), footprint %.1f MB",
            mode, count, mainThread / n, (busy.probe - idle.probe) / n, (busy.server - idle.server) / n,
            idle.probe, idle.server, seconds, footprint(getpid()) ?? 0))
        print(String(format: "  phases per update: text %.3f ms, layout %.3f ms, commit %.3f ms",
                     strip.phases[0] / n, strip.phases[1] / n, strip.phases[2] / n))
        strip.panel.orderOut(nil)
    }
    exit(0)
}

/// The same updates sent to an item of the running SketchyBar through its CLI.
@MainActor private func sketchyBar(updates: Int, seconds: Double, on screen: NSScreen) {
    let cli = "/opt/homebrew/bin/sketchybar"
    guard let daemon = pid(of: "sketchybar") else {
        print("sketchybar: not running")
        return
    }
    // SketchyBar numbers displays by its own arrangement (docs/overview.md).
    let displays = (try? JSONSerialization.jsonObject(with: Data(run(cli, ["--query", "displays"]).utf8))) as? [[String: Any]]
    guard let arrangement = displays?.first(where: {
        ($0["DirectDisplayID"] as? NSNumber)?.uint32Value == screen.displayID
    })?["arrangement-id"] as? NSNumber else {
        print("sketchybar: no display matches the built-in one")
        return
    }
    run(cli, ["--add", "item", "zenith_probe", "right", "--set", "zenith_probe", "display=\(arrangement)", "label=1"])
    pumpEvents(0.5)
    let idle = measure(seconds, other: daemon, tick: nil)
    var count = 0
    let busy = measure(seconds, other: daemon) {
        run(cli, ["--set", "zenith_probe", "label=\(words[count % words.count])"])
        count += 1
    }
    run(cli, ["--remove", "zenith_probe"])
    let n = Double(count)
    print(String(format: "sketchybar: %d updates, SketchyBar %.3f ms/update, WindowServer %.2f ms/update"
        + " (idle: SketchyBar %.0f ms, WindowServer %.0f ms over %.0f s), SketchyBar footprint %.1f MB",
        count, ((busy.other ?? 0) - (idle.other ?? 0)) / n, (busy.server - idle.server) / n,
        idle.other ?? 0, idle.server, seconds, footprint(daemon) ?? 0))
}

private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
