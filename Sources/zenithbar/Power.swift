import AppKit
import IOKit.ps
import ZenithBarKit

/// The internal battery's charge and whether it is on AC power, nil without a battery.
struct Battery: Hashable {
    var percent: Int
    var charging: Bool

    static func read() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return Battery(percent: min(100, current * 100 / maximum),
                           charging: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }

    /// Calls `changed` at each change IOKit reports for any power source, on the main run loop.
    @MainActor static func watch(_ changed: @escaping @MainActor () -> Void) {
        batteryChanged = changed
        let source = IOPSNotificationCreateRunLoopSource({ _ in onMain { batteryChanged?() } }, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), source?.takeRetainedValue(), .defaultMode)
    }

    /// The battery, Steve's choice on 2026-10-08 (option 3e): a 1 pt outline, a solid fill to the
    /// charge in the icons' color, the percent inside in condensed heavy digits, light over the
    /// empty part and cut out of the fill, and a bolt after them on AC. The outline sits on the half point grid, so it covers whole
    /// pixels. The image, its size, and where its ink, the body to the end of its nub, runs.
    func image(foreground: NSColor, background: NSColor, scale: CGFloat) -> (CGImage, CGSize, ClosedRange<CGFloat>)? {
        let size = CGSize(width: 32, height: 16)
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let outer = NSRect(x: 1, y: 1, width: 27, height: 14)
        let outline = NSBezierPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1
        foreground.setStroke()
        outline.stroke()
        let inner = outer.insetBy(dx: 2, dy: 2)
        let filled = NSRect(x: inner.minX, y: inner.minY, width: (inner.width * CGFloat(percent) / 100).rounded(),
                            height: inner.height)
        context.saveGState()
        NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).addClip()
        foreground.setFill()
        filled.fill()
        context.restoreGState()
        foreground.setFill()
        NSBezierPath(roundedRect: NSRect(x: outer.maxX + 1, y: outer.midY - 2.5, width: 1.5, height: 5),
                     xRadius: 0.75, yRadius: 0.75).fill()
        // The digits' and the bolt's ink centered together on the inside, snapped to the pixel
        // grid: centering on the font's line box set the digits 1 pt high.
        let lines = [foreground, background].map { color in
            CTLineCreateWithAttributedString(NSAttributedString(string: String(percent),
                                                                attributes: [.font: Self.digits, .foregroundColor: color]))
        }
        let ink = CTLineGetBoundsWithOptions(lines[0], .useGlyphPathBounds)
        let boltHeight: CGFloat = 9, boltWidth = boltHeight * 0.62, gap: CGFloat = 1
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        let left = snap(inner.midX - (ink.width + (charging ? gap + boltWidth : 0)) / 2)
        let origin = CGPoint(x: left - ink.minX, y: snap(inner.midY - ink.midY))
        let bolt = NSBezierPath()
        if charging {
            let boltLeft = left + ink.width + gap, bottom = inner.midY - boltHeight / 2
            bolt.move(to: NSPoint(x: boltLeft + boltWidth * 0.75, y: bottom + boltHeight))
            for (x, y) in [(0.0, 0.42), (0.42, 0.42), (0.25, 0.0), (1.0, 0.58), (0.58, 0.58)] {
                bolt.line(to: NSPoint(x: boltLeft + boltWidth * x, y: bottom + boltHeight * y))
            }
            bolt.close()
        }
        // Light over the empty part, then again in the background's color over the fill.
        for (line, color, clip) in [(lines[0], foreground, nil), (lines[1], background, filled)] as [(CTLine, NSColor, NSRect?)] {
            context.saveGState()
            clip?.clip()
            context.textPosition = origin
            CTLineDraw(line, context)
            color.setFill()
            bolt.fill()
            context.restoreGState()
        }
        return context.makeImage().map { ($0, size, 1...30.5) }
    }

    /// SF's condensed heavy at 9.5 pt with fixed-width figures, so "100" fits at the size of "64".
    /// Made at each drawing, which the bar's cache keeps to a charge change.
    private static var digits: NSFont {
        let font = NSFont.systemFont(ofSize: 9.5, weight: .heavy, width: .condensed)
        let figures = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: figures, size: 9.5) ?? font
    }
}

@MainActor private var batteryChanged: (@MainActor () -> Void)?
