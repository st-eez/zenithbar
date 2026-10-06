// Whether a blur behind the bar follows its outline (docs/overview.md).
//
//   zenith-probe shape [visual|masked|skylight|tint...]
//       For each way of drawing the bar's fill, a probe bar shaped as a tab with flared top
//       corners over a striped backdrop of the probe's, in the middle of the built-in display,
//       and the stripes' contrast in a capture at points inside the outline, in its flares and
//       rounded corners, and outside them. Blur shows as contrast near 0, bare stripes near 255.
//       visual    NSVisualEffectView with the outline as its maskImage
//       masked    NSVisualEffectView with the outline as its layer's mask
//       skylight  the outline filled translucent, and SLSSetWindowBackgroundBlurRadius 30
//       tint      the outline filled translucent, with no blur, the control
//       Needs Screen Recording for the host terminal. Takes about 2 s a mode.
import AppKit
import CZenith

private let barWidth: CGFloat = 400, height: CGFloat = 64, flare: CGFloat = 32, radius: CGFloat = 20

/// Points in the window's content, origin bottom left, and whether the outline covers each.
private let samples: [(name: String, point: CGPoint, inside: Bool)] = [
    ("center", CGPoint(x: flare + barWidth / 2, y: height / 2), true),
    // 36 pt from the flare's circle center, outside its 32 pt circle, so the outline fills it.
    ("flare fill", CGPoint(x: 0.8 * flare, y: height - 0.2 * flare), true),
    // 11 pt from that center, inside the circle the flare carves away.
    ("flare carve", CGPoint(x: 0.25 * flare, y: height - 0.75 * flare), false),
    ("bottom fill", CGPoint(x: flare + radius + 20, y: 10), true),
    // 25 pt from the bottom left corner's center, outside its 20 pt radius.
    ("corner carve", CGPoint(x: flare + 2, y: 2), false),
    ("below window", CGPoint(x: flare + barWidth / 2, y: -10), false),
]

@MainActor func shape(_ modes: [String]) -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let screen = builtInScreen()
    let size = NSSize(width: barWidth + 2 * flare, height: height)
    let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                       width: size.width, height: size.height)
    let backdrop = BarPanel(frame: frame.insetBy(dx: -30, dy: -30), level: .floating, behavior: [.canJoinAllSpaces])
    backdrop.contentView = StripesView()
    backdrop.orderFrontRegardless()
    let outline = tabPath(width: barWidth, height: height, flare: flare, radius: radius)
    print("bar \(Int(barWidth))x\(Int(height)) pt, flare \(Int(flare)), bottom radius \(Int(radius)); stripes 2 pt")
    print("contrast, 0 to 255, where blur reads near 0 and bare stripes near 255")
    for mode in modes.isEmpty ? ["tint", "visual", "masked", "skylight"] : modes {
        let bar = BarPanel(frame: frame, level: .statusBar, behavior: [.canJoinAllSpaces])
        let fill = CAShapeLayer()
        fill.path = outline
        fill.fillColor = NSColor(white: 0.5, alpha: 0.35).cgColor
        switch mode {
        case "visual", "masked":
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            if mode == "visual" {
                effect.maskImage = NSImage(size: size, flipped: false) { _ in
                    NSColor.black.setFill()
                    let context = NSGraphicsContext.current!.cgContext
                    context.addPath(outline)
                    context.fillPath()
                    return true
                }
            } else {
                effect.wantsLayer = true
                let mask = CAShapeLayer()
                mask.path = outline
                effect.layer?.mask = mask
            }
            bar.contentView = effect
        case "skylight", "tint":
            let view = layerView(NSRect(origin: .zero, size: size))
            view.layer?.addSublayer(fill)
            bar.contentView = view
        default:
            print("unknown mode \(mode)")
            exit(2)
        }
        bar.orderFrontRegardless()
        if mode == "skylight" {
            let error = SLSSetWindowBackgroundBlurRadius(SLSMainConnectionID(), bar.id, 30)
            if error != .success { print("skylight: SLSSetWindowBackgroundBlurRadius returned \(error.rawValue)") }
        }
        pumpEvents(0.6)
        let area = CGRect(x: backdrop.frame.minX, y: NSScreen.screens[0].frame.height - backdrop.frame.maxY,
                          width: backdrop.frame.width, height: backdrop.frame.height)
        guard let image = capture(area, of: [backdrop.id, bar.id], on: screen) else {
            print("\(mode): the capture failed; grant Screen Recording to the terminal")
            exit(1)
        }
        let readings = samples.map { sample -> String in
            let value = image.contrast(at: globalPoint(sample.point, in: bar), span: 5)
            return "\(sample.name) \(value.map { String(Int($0)) } ?? "-")\(sample.inside ? "" : "*")"
        }
        print(String(mode.padding(toLength: 9, withPad: " ", startingAt: 0)) + readings.joined(separator: ", "))
        bar.orderOut(nil)
    }
    print("* outside the outline: reads near 255 when the blur follows it")
    exit(0)
}
