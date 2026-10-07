import AppKit

/// The SF Symbol `name` at `pointSize` in `color`, its unfilled part fainter by `value` from 0
/// to 1 when it has one, as the native menu bar's Wi-Fi shows its signal.
func symbol(_ name: String, value: Double?, pointSize: CGFloat, color: NSColor) -> NSImage? {
    let image = value.map { NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: nil) }
        ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return image?.withSymbolConfiguration(configuration)
}

/// `image` drawn at `scale` and cropped to its ink, so an item centers and spaces it by its
/// ink as it does a glyph: the bitmap, its size in points, and its ink's span, all of it.
func inkImage(_ image: NSImage, scale: CGFloat) -> (CGImage, CGSize, ClosedRange<CGFloat>)? {
    let width = Int(ceil(image.size.width * scale)), height = Int(ceil(image.size.height * scale))
    guard width > 0, height > 0,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    guard let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return nil }
    // Rows run from the top, and each pixel's alpha comes first.
    var left = width, right = -1, top = height, bottom = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4] > 0 {
            (left, right, top, bottom) = (min(left, x), max(right, x), min(top, y), max(bottom, y))
        }
    }
    guard right >= left, let cropped = context.makeImage()?.cropping(
        to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else { return nil }
    let size = CGSize(width: CGFloat(cropped.width) / scale, height: CGFloat(cropped.height) / scale)
    return (cropped, size, 0...size.width)
}
