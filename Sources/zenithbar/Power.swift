import AppKit
import IOKit.ps

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

    /// Calls `changed` on the main thread at each change IOKit reports for any power source.
    @MainActor static func watch(_ changed: @escaping @MainActor () -> Void) {
        batteryChanged = changed
        let source = IOPSNotificationCreateRunLoopSource({ _ in MainActor.assumeIsolated { batteryChanged?() } }, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), source?.takeRetainedValue(), .defaultMode)
    }

    /// The battery, Steve's choice on 2026-10-07: a solid body filled to the charge over a
    /// fainter trough, the percent inside, light over the empty part and dark over the fill,
    /// and a bolt on AC. Its 51 by 20 unit canvas shows at 0.85 pt a unit, the body 25 by 14 pt.
    /// The image, its size, and where its ink, the body to the end of its nub, runs.
    func image(foreground: NSColor, background: NSColor, scale: CGFloat) -> (CGImage, CGSize, ClosedRange<CGFloat>)? {
        let unit: CGFloat = 0.85, size = CGSize(width: 51 * unit, height: 20 * unit)
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale * unit, y: scale * unit)
        context.translateBy(x: 9.5, y: 0)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let outer = NSRect(x: 1, y: 2, width: 30, height: 16)
        let filled = NSRect(x: outer.minX, y: outer.minY, width: outer.width * CGFloat(percent) / 100, height: outer.height)
        let trough = foreground.blended(withFraction: 0.55, of: background) ?? foreground
        let body = NSBezierPath(roundedRect: outer, xRadius: 4.5, yRadius: 4.5)
        trough.setFill()
        body.fill()
        context.saveGState()
        body.addClip()
        foreground.setFill()
        filled.fill()
        context.restoreGState()
        trough.setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 7, width: 2, height: 6), xRadius: 1, yRadius: 1).fill()
        let font = NSFont.monospacedDigitSystemFont(ofSize: percent == 100 ? 10 : 11.5, weight: .bold)
        let number = String(percent) as NSString
        let textSize = number.size(withAttributes: [.font: font])
        // The digits and the bolt centered together, the digits' capitals on the body's middle.
        let boltHeight: CGFloat = 10, boltWidth = boltHeight * 0.62
        let middle = outer.minX + (outer.width - (charging ? boltWidth + 1.5 : 0)) / 2
        let origin = NSPoint(x: middle - textSize.width / 2, y: outer.midY - font.capHeight / 2 + font.descender)
        number.draw(at: origin, withAttributes: [.font: font, .foregroundColor: foreground])
        context.saveGState()
        filled.clip()
        number.draw(at: origin, withAttributes: [.font: font, .foregroundColor: background])
        context.restoreGState()
        if charging {
            let left = middle + textSize.width / 2 + 1.2, bottom = outer.midY - boltHeight / 2
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: left + boltWidth * 0.75, y: bottom + boltHeight))
            for (x, y) in [(0.0, 0.42), (0.42, 0.42), (0.25, 0.0), (1.0, 0.58), (0.58, 0.58)] {
                bolt.line(to: NSPoint(x: left + boltWidth * x, y: bottom + boltHeight * y))
            }
            bolt.close()
            (percent >= 80 ? background : foreground).setFill()
            bolt.fill()
        }
        // The body starts at 1 unit and the nub ends at 34, after the 9.5 unit shift.
        return context.makeImage().map { ($0, size, 10.5 * unit...43.5 * unit) }
    }
}

@MainActor private var batteryChanged: (@MainActor () -> Void)?
