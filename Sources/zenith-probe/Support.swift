// The probe bar the probes build, its outline, and the reads they share.
import AppKit
import CZenith
@preconcurrency import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor func builtInScreen() -> NSScreen {
    NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 } ?? NSScreen.main ?? NSScreen.screens[0]
}

/// The outline of a bar hanging from its top edge: its top corners flare out by `flare` into
/// that edge, as Noctalia draws `concave_edge_corners`, and its bottom corners round by
/// `radius`. It spans `width + 2 * flare`, with the origin at the bottom left.
func tabPath(width: CGFloat, height: CGFloat, flare: CGFloat, radius: CGFloat) -> CGPath {
    let path = CGMutablePath(), right = flare + width
    path.move(to: CGPoint(x: 0, y: height))
    path.addArc(center: CGPoint(x: 0, y: height - flare), radius: flare, startAngle: .pi / 2, endAngle: 0,
                clockwise: true)
    path.addLine(to: CGPoint(x: flare, y: radius))
    path.addArc(center: CGPoint(x: flare + radius, y: radius), radius: radius, startAngle: .pi, endAngle: 1.5 * .pi,
                clockwise: false)
    path.addLine(to: CGPoint(x: right - radius, y: 0))
    path.addArc(center: CGPoint(x: right - radius, y: radius), radius: radius, startAngle: 1.5 * .pi,
                endAngle: 2 * .pi, clockwise: false)
    path.addLine(to: CGPoint(x: right, y: height - flare))
    path.addArc(center: CGPoint(x: right + flare, y: height - flare), radius: flare, startAngle: .pi,
                endAngle: .pi / 2, clockwise: true)
    path.closeSubpath()
    return path
}

/// A borderless panel that never takes key or activates the probe, as a bar's window.
final class BarPanel: NSPanel {
    init(frame: NSRect, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        self.level = level
        collectionBehavior = behavior
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var id: UInt32 { UInt32(windowNumber) }
}

/// A layer-backed view whose layer the probe draws into directly.
@MainActor func layerView(_ frame: NSRect) -> NSView {
    let view = NSView(frame: frame)
    view.wantsLayer = true
    return view
}

/// The window list's row for `window`, which includes windows ordered out.
func windowRow(_ window: UInt32) -> [String: Any]? {
    (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window)) as? [[String: Any]])?.first
}

func isOnScreen(_ window: UInt32) -> Bool { (windowRow(window)?[kCGWindowIsOnscreen as String] as? Bool) ?? false }

func spaces(of window: UInt32) -> [UInt64] {
    (zenith_window_spaces(window)?.takeRetainedValue() as? [NSNumber])?.map(\.uint64Value) ?? []
}

/// The windows on screen, front to back.
func onScreenOrder() -> [UInt32] {
    ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [])
        .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
}

/// CoreGraphics' point for `point` in the coordinates of `window`'s content, origin bottom left.
@MainActor func globalPoint(_ point: CGPoint, in window: NSWindow) -> CGPoint {
    CGPoint(x: window.frame.minX + point.x, y: NSScreen.screens[0].frame.height - window.frame.minY - point.y)
}

/// Runs the app's event loop for `seconds`.
@MainActor func pumpEvents(_ seconds: Double) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
    }
}

/// A capture of `rect`, in CoreGraphics' coordinates on `screen`, showing `windows` alone,
/// in sRGB with 8 bits a channel, or nil when the capture fails.
@MainActor func capture(_ rect: CGRect, of windows: [UInt32], on screen: NSScreen) -> Capture? {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var content: SCShareableContent?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { result, _ in
        content = result
        done.signal()
    }
    done.wait()
    guard let content, let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
    let bounds = CGDisplayBounds(screen.displayID), scale = screen.backingScaleFactor
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    configuration.width = Int(rect.width * scale)
    configuration.height = Int(rect.height * scale)
    configuration.showsCursor = false
    let filter = SCContentFilter(display: display, including: content.windows.filter { windows.contains($0.windowID) })
    nonisolated(unsafe) var image: CGImage?
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { result, _ in
        image = result
        done.signal()
    }
    done.wait()
    return image.flatMap { Capture($0, origin: rect.origin, scale: scale) }
}

/// A captured image's pixels, read in the coordinates of the screen it was taken from.
struct Capture {
    let width: Int, height: Int, origin: CGPoint, scale: CGFloat
    private let pixels: [UInt8]

    init?(_ image: CGImage, origin: CGPoint, scale: CGFloat) {
        width = image.width
        height = image.height
        self.origin = origin
        self.scale = scale
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        pixels = bytes
    }

    /// The luminance, 0 to 255, of the pixel at `point`, CoreGraphics' global coordinates.
    func luminance(_ point: CGPoint) -> Double? {
        // The bitmap context's first row is the image's top row.
        let x = Int((point.x - origin.x) * scale), y = Int((point.y - origin.y) * scale)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let index = (y * width + x) * 4
        return 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
    }

    /// How many pixels inside `rect`, CoreGraphics' global coordinates, are not clear, and a
    /// hash of every pixel there, which changes when anything drawn there changes.
    func ink(in rect: CGRect) -> (pixels: Int, hash: Int) {
        let minX = max(0, Int((rect.minX - origin.x) * scale)), maxX = min(width, Int((rect.maxX - origin.x) * scale))
        let minY = max(0, Int((rect.minY - origin.y) * scale)), maxY = min(height, Int((rect.maxY - origin.y) * scale))
        var count = 0, hasher = Hasher()
        for y in minY..<max(minY, maxY) {
            for x in minX..<max(minX, maxX) {
                let index = (y * width + x) * 4
                if pixels[index + 3] > 25 { count += 1 }
                hasher.combine(pixels[index..<index + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            }
        }
        return (count, hasher.finalize())
    }

    /// The spread of luminance along the row of pixels `span` points wide centered on `point`:
    /// near 255 across sharp black and white stripes, near 0 where they are blurred.
    func contrast(at point: CGPoint, span: CGFloat) -> Double? {
        let steps = Int(span * scale)
        let values = (0...steps).compactMap { luminance(CGPoint(x: point.x - span / 2 + CGFloat($0) / scale, y: point.y)) }
        guard let low = values.min(), let high = values.max() else { return nil }
        return high - low
    }
}

/// A vertical black and white stripe every 2 points, for blur to smear.
final class StripesView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let stripe: CGFloat = 2
        NSColor.white.setFill()
        bounds.fill()
        NSColor.black.setFill()
        var x: CGFloat = 0
        while x < bounds.width {
            NSRect(x: x, y: 0, width: stripe, height: bounds.height).fill()
            x += 2 * stripe
        }
    }
}

/// A process's CPU time in ms, or nil when the kernel refuses to read it, as for another
/// user's process. rusage counts in mach time units.
func rusageCPU(_ pid: pid_t) -> Double? {
    rusage(pid).map { info in
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e6
    }
}

/// A process's physical footprint in MB, as Activity Monitor's Memory column shows it.
func footprint(_ pid: pid_t) -> Double? { rusage(pid).map { Double($0.ri_phys_footprint) / 1_048_576 } }

private func rusage(_ pid: pid_t) -> rusage_info_v4? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? info : nil
}

/// A process's CPU time in ms as ps prints it, "minutes:seconds.hundredths", for WindowServer,
/// which runs as another user.
func psCPU(_ pid: pid_t) -> Double? {
    let parts = run("/bin/ps", ["-o", "time=", "-p", "\(pid)"])
        .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").compactMap { Double($0) }
    return parts.isEmpty ? nil : parts.reduce(0) { $0 * 60 + $1 } * 1000
}

func pid(of name: String) -> pid_t? {
    run("/usr/bin/pgrep", ["-x", name]).split(separator: "\n").first.flatMap { pid_t($0) }
}

/// A command's standard output.
@discardableResult func run(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return text
}

func stamp(_ start: ContinuousClock.Instant) -> String {
    let duration = ContinuousClock.now - start
    let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    return String(format: "%8.1f ms", ms)
}
