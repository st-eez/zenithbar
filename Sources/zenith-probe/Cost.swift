// What an update of the bar costs the bar's process and WindowServer (docs/overview.md).
//
//   zenith-probe cost [updates] [text|image|still|windows|sketchybar...]
//       A 14 item probe bar along the top of the built-in display, 20 updates a second, each
//       changing one item's text to another width and moving the items after it, in seconds
//       alternating with idle ones. Reports CPU per update of the probe and of WindowServer, and the
//       probe's main thread time per update.
//       text        each item a CATextLayer, measured with NSAttributedString
//       image       each item's text laid out with CoreText and drawn into its layer's contents
//       still       as text, but the last item changes, so no other item moves
//       windows     as text, but each item in a window of its own, as SketchyBar draws them
//       sketchybar  the same updates to an item added to the running SketchyBar through its CLI,
//                   on the built-in display, against SketchyBar's CPU; the item is removed after
//       Default: 300 updates, text then image. Takes about updates / 10 s a mode, longer with
//       sketchybar, whose CLI holds the rate near 10 a second.
import AppKit
import CoreText

private let rate = 20.0, barHeight: CGFloat = 25, padding: CGFloat = 8, spacing: CGFloat = 6
private let words = ["1", "1 ab", "1 abcdef"]

@MainActor private final class Strip {
    let panel: BarPanel
    let image: Bool
    var items: [CALayer] = []
    /// Each item's own window, when items have them.
    var windows: [BarPanel] = []
    var widths: [CGFloat] = []
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let scale: CGFloat
    /// ms spent setting text, laying out, and committing, over every update.
    var phases = [0.0, 0.0, 0.0]

    init(on screen: NSScreen, image: Bool, windowed: Bool) {
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
            if windowed {
                let window = BarPanel(frame: NSRect(x: frame.minX, y: frame.minY + 3, width: 10, height: barHeight - 6),
                                      level: .statusBar, behavior: [.canJoinAllSpaces, .stationary])
                window.contentView = layerView(NSRect(x: 0, y: 0, width: 10, height: barHeight - 6))
                window.contentView?.layer?.addSublayer(item)
                windows.append(window)
            } else {
                view.layer?.addSublayer(item)
            }
            items.append(item)
            widths.append(0)
            set(index, "item \(index)")
        }
        layout(from: 0)
        panel.orderFrontRegardless()
        for window in windows { window.orderFrontRegardless() }
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
            if windows.isEmpty {
                items[item].frame = CGRect(x: x, y: 3, width: widths[item], height: barHeight - 6)
            } else {
                windows[item].setFrame(NSRect(x: panel.frame.minX + x, y: panel.frame.minY + 3, width: widths[item],
                                              height: barHeight - 6), display: false)
                items[item].frame = CGRect(x: 0, y: 0, width: widths[item], height: barHeight - 6)
            }
            x += widths[item] + spacing
        }
    }
}

private struct Sample { var probe = 0.0, server = 0.0, other = 0.0 }

/// CPU in ms of the probe, WindowServer and an optional third process, idle and busy, each
/// summed over `seconds` alternations of an idle second and a second while `tick` runs `rate`
/// times a second. WindowServer's own load drifted by a third between 15 s stretches, which
/// alternating cancels (docs/overview.md).
@MainActor private func measure(_ seconds: Double, other: pid_t?, tick: @escaping @MainActor () -> Void)
    -> (idle: Sample, busy: Sample)
{
    let server = pid(of: "WindowServer")!
    let read = { Sample(probe: rusageCPU(getpid())!, server: psCPU(server)!, other: other.flatMap(rusageCPU) ?? 0) }
    var idle = Sample(), busy = Sample()
    for _ in 0..<Int(seconds) {
        for active in [false, true] {
            let start = read()
            var timer: Timer?
            if active {
                timer = Timer(timeInterval: 1 / rate, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
                RunLoop.main.add(timer!, forMode: .common)
            }
            pumpEvents(1)
            timer?.invalidate()
            let end = read()
            let delta = Sample(probe: end.probe - start.probe, server: end.server - start.server,
                               other: end.other - start.other)
            if active {
                busy = Sample(probe: busy.probe + delta.probe, server: busy.server + delta.server,
                              other: busy.other + delta.other)
            } else {
                idle = Sample(probe: idle.probe + delta.probe, server: idle.server + delta.server,
                              other: idle.other + delta.other)
            }
        }
    }
    return (idle, busy)
}

@MainActor func cost(updates: Int, modes: [String]) -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let screen = builtInScreen(), seconds = Double(updates) / rate
    print("\(updates) updates at \(Int(rate)) a second; CPU per update is the busy seconds less the idle ones between them")
    for mode in modes.isEmpty ? ["text", "image"] : modes {
        if mode == "sketchybar" {
            sketchyBar(updates: updates, seconds: seconds, on: screen)
            continue
        }
        guard ["text", "image", "still", "windows"].contains(mode) else {
            print("unknown mode \(mode)")
            exit(2)
        }
        let strip = Strip(on: screen, image: mode == "image", windowed: mode == "windows")
        let changing = mode == "still" ? strip.items.count - 1 : 1
        pumpEvents(0.5)
        var count = 0, mainThread = 0.0
        let (idle, busy) = measure(seconds, other: nil) {
            mainThread += ms(ContinuousClock().measure { strip.update(changing, words[count % words.count]) })
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
        for window in strip.windows { window.orderOut(nil) }
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
    var count = 0
    let (idle, busy) = measure(seconds, other: daemon) {
        run(cli, ["--set", "zenith_probe", "label=\(words[count % words.count])"])
        count += 1
    }
    run(cli, ["--remove", "zenith_probe"])
    let n = Double(count)
    print(String(format: "sketchybar: %d updates, SketchyBar %.3f ms/update, WindowServer %.2f ms/update"
        + " (idle: SketchyBar %.0f ms, WindowServer %.0f ms over %.0f s), SketchyBar footprint %.1f MB",
        count, (busy.other - idle.other) / n, (busy.server - idle.server) / n, idle.other, idle.server, seconds, footprint(daemon) ?? 0))
}

private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
