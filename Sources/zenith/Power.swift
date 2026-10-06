import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps

/// The internal battery's charge and whether it is on AC power, nil without a battery.
struct Battery: Equatable {
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

    /// The battery image of Steve's SketchyBar helper, ported: a filled body with the percent
    /// inside it, light over the empty part and dark over the filled one, and a bolt on AC.
    /// Its 51 by 20 unit canvas showed at 0.85 pt a unit there.
    func image(foreground: NSColor, background: NSColor, scale: CGFloat) -> (CGImage, CGSize)? {
        let unit: CGFloat = 0.85, size = CGSize(width: 51 * unit, height: 20 * unit)
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale * unit, y: scale * unit)
        context.translateBy(x: 9.5, y: 0)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let fraction = CGFloat(percent) / 100
        let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 27, height: 14), xRadius: 4, yRadius: 4)
        let trough = foreground.blended(withFraction: 0.55, of: background) ?? foreground
        trough.setFill()
        body.fill()
        context.saveGState()
        body.addClip()
        foreground.setFill()
        NSRect(x: 1, y: 3, width: 27 * fraction, height: 14).fill()
        context.restoreGState()
        let font = NSFont.monospacedDigitSystemFont(ofSize: percent == 100 ? 10 : 11.5, weight: .semibold)
        let number = String(percent) as NSString
        let textSize = number.size(withAttributes: [.font: font])
        let origin = NSPoint(x: (charging ? 12 : 14.5) - textSize.width / 2, y: 10 - textSize.height / 2 + 0.5)
        number.draw(at: origin, withAttributes: [.font: font, .foregroundColor: foreground])
        context.saveGState()
        NSRect(x: 1, y: 3, width: 27 * fraction, height: 14).clip()
        number.draw(at: origin, withAttributes: [.font: font, .foregroundColor: background])
        context.restoreGState()
        trough.setFill()
        NSBezierPath(roundedRect: NSRect(x: 29, y: 7.5, width: 2, height: 5), xRadius: 1, yRadius: 1).fill()
        if charging {
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 25, y: 16))
            for point in [NSPoint(x: 20.5, y: 9), NSPoint(x: 23.5, y: 9), NSPoint(x: 22, y: 4),
                          NSPoint(x: 27.5, y: 11.5), NSPoint(x: 24, y: 11.5)] { bolt.line(to: point) }
            bolt.close()
            background.setFill()
            bolt.fill()
        }
        return context.makeImage().map { ($0, size) }
    }
}

@MainActor private var batteryChanged: (@MainActor () -> Void)?

/// The default output device's volume and mute, read and watched through CoreAudio.
@MainActor final class Volume {
    private(set) var level = 0.0
    private(set) var muted = false
    private var device = AudioObjectID(kAudioObjectUnknown)
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
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(device, &address, nil, listener)
        }
        read()
    }

    func read() {
        var volume = Float32(0), mute = UInt32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        size = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyMute)
        let hasMute = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr
        let next = (Double(volume), hasMute && mute != 0)
        guard next != (level, muted) else { return }
        (level, muted) = next
        changed()
    }

    func toggleMute() {
        var mute = UInt32(muted ? 0 : 1)
        var address = Self.address(kAudioDevicePropertyMute)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
