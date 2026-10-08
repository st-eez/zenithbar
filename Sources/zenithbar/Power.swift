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

    /// The battery, Steve's choice on 2026-10-08 (option 3d): a 1 pt outline, a faint fill to the
    /// charge, the percent inside in condensed heavy digits, the same color at every charge, and
    /// a bolt after them on AC. The outline sits on the half point grid, so it covers whole
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
        context.saveGState()
        NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).addClip()
        foreground.withAlphaComponent(0.3).setFill()
        NSRect(x: inner.minX, y: inner.minY, width: (inner.width * CGFloat(percent) / 100).rounded(), height: inner.height).fill()
        context.restoreGState()
        foreground.setFill()
        NSBezierPath(roundedRect: NSRect(x: outer.maxX + 1, y: outer.midY - 2.5, width: 1.5, height: 5),
                     xRadius: 0.75, yRadius: 0.75).fill()
        let font = Self.digits
        let number = String(percent) as NSString
        let textWidth = number.size(withAttributes: [.font: font]).width
        // The digits and the bolt centered together, the digits' capitals on the body's middle.
        let boltHeight: CGFloat = 7.5, boltWidth = boltHeight * 0.62, gap: CGFloat = 0.8
        let left = inner.midX - (textWidth + (charging ? boltWidth + gap : 0)) / 2
        number.draw(at: NSPoint(x: left, y: inner.midY - font.capHeight / 2 + font.descender),
                    withAttributes: [.font: font, .foregroundColor: foreground])
        if charging {
            let boltLeft = left + textWidth + gap, bottom = inner.midY - boltHeight / 2
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: boltLeft + boltWidth * 0.75, y: bottom + boltHeight))
            for (x, y) in [(0.0, 0.42), (0.42, 0.42), (0.25, 0.0), (1.0, 0.58), (0.58, 0.58)] {
                bolt.line(to: NSPoint(x: boltLeft + boltWidth * x, y: bottom + boltHeight * y))
            }
            bolt.close()
            bolt.fill()
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
