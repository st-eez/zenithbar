import AppKit

/// The ink of `text`'s glyphs, from its origin with y up from its baseline.
public func inkBounds(_ text: NSAttributedString) -> CGRect {
    CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
}

extension NSAttributedString {
    /// The font of the first character, nil for empty text, as a plugin's blank detail.
    public var firstFont: NSFont? { length > 0 ? attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil }
}
