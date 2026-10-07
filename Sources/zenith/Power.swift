import AppKit
import AudioToolbox
import CoreAudio
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

    /// The battery of the bar's line style, Steve's choice on 2026-10-07: an outline in SF
    /// Symbols' 1.3 pt strokes with a solid fill inside it to the charge, the percent inside,
    /// light over the empty part and dark over the fill, and a bolt on AC. Its 51 by 20 unit
    /// canvas shows at 0.85 pt a unit, as the SketchyBar helper's filled body it replaces.
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
        let line = 1.3 / unit, outer = NSRect(x: 1, y: 2, width: 30, height: 16)
        let outline = foreground.blended(withFraction: 0.45, of: background) ?? foreground
        let body = NSBezierPath(roundedRect: outer.insetBy(dx: line / 2, dy: line / 2), xRadius: 4.5 - line / 2,
                                yRadius: 4.5 - line / 2)
        body.lineWidth = line
        outline.setStroke()
        body.stroke()
        outline.setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 7, width: 2, height: 6), xRadius: 1, yRadius: 1).fill()
        // The fill sits a unit clear of the outline, as in the native menu bar's battery.
        let inner = outer.insetBy(dx: line + 0.9, dy: line + 0.9)
        let filled = NSRect(x: inner.minX, y: inner.minY, width: inner.width * CGFloat(percent) / 100, height: inner.height)
        context.saveGState()
        NSBezierPath(roundedRect: inner, xRadius: 2.2, yRadius: 2.2).addClip()
        foreground.setFill()
        filled.fill()
        context.restoreGState()
        let font = NSFont.monospacedDigitSystemFont(ofSize: percent == 100 ? 10 : 11, weight: .bold)
        let number = String(percent) as NSString
        let textSize = number.size(withAttributes: [.font: font])
        let origin = NSPoint(x: (charging ? 13.5 : 16) - textSize.width / 2, y: 10 - textSize.height / 2 + 0.5)
        number.draw(at: origin, withAttributes: [.font: font, .foregroundColor: foreground])
        context.saveGState()
        filled.clip()
        number.draw(at: origin, withAttributes: [.font: font, .foregroundColor: background])
        context.restoreGState()
        if charging {
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 27.6, y: 14.5))
            for point in [NSPoint(x: 24.4, y: 9.4), NSPoint(x: 26.5, y: 9.4), NSPoint(x: 25.4, y: 5.5),
                          NSPoint(x: 28.6, y: 10.8), NSPoint(x: 26.5, y: 10.8)] { bolt.line(to: point) }
            bolt.close()
            (percent >= 85 ? background : foreground).setFill()
            bolt.fill()
        }
        // The body starts at 1 unit and the nub ends at 34, after the 9.5 unit shift.
        return context.makeImage().map { ($0, size, 10.5 * unit...43.5 * unit) }
    }
}

@MainActor private var batteryChanged: (@MainActor () -> Void)?

/// The default output device's volume and mute, read and watched through CoreAudio. A device
/// may have neither, as Steve's VG279QE5A monitors, whose level is set on the monitor
/// (AudioObjectHasProperty false for both, 2026-10-06); it shows full and unmuted.
@MainActor final class Volume {
    private(set) var level = 1.0
    private(set) var muted = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var hasLevel = false, hasMute = false
    private let changed: @MainActor () -> Void
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.read() }
    }

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        var defaultDevice = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        attach()
    }

    /// Follows the default output device, as when headphones connect.
    private func attach() {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(device, &address, nil, listener)
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        var levelAddress = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var muteAddress = Self.address(kAudioDevicePropertyMute)
        hasLevel = AudioObjectHasProperty(device, &levelAddress)
        hasMute = AudioObjectHasProperty(device, &muteAddress)
        if hasLevel { AudioObjectAddPropertyListenerBlock(device, &levelAddress, nil, listener) }
        if hasMute { AudioObjectAddPropertyListenerBlock(device, &muteAddress, nil, listener) }
        read()
    }

    func read() {
        var volume = Float32(1), mute = UInt32(0)
        if hasLevel {
            var size = UInt32(MemoryLayout<Float32>.size)
            var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        }
        if hasMute {
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = Self.address(kAudioDevicePropertyMute)
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute)
        }
        let next = (Double(volume), mute != 0)
        guard next != (level, muted) else { return }
        (level, muted) = next
        changed()
    }

    func toggleMute() {
        guard hasMute else { return }
        var mute = UInt32(muted ? 0 : 1)
        var address = Self.address(kAudioDevicePropertyMute)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
