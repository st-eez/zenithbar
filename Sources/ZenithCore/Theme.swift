import Foundation

/// An sRGB color, each channel from 0 to 1.
public struct RGBA: Equatable, Sendable {
    public var red, green, blue, alpha: Double

    /// "#rrggbb" or "#rrggbbaa".
    public init?(hex: String) {
        guard hex.hasPrefix("#"), [7, 9].contains(hex.count), let value = UInt64(hex.dropFirst(), radix: 16) else {
            return nil
        }
        let full = hex.count == 7 ? value << 8 | 0xff : value
        red = Double(full >> 24 & 0xff) / 255
        green = Double(full >> 16 & 0xff) / 255
        blue = Double(full >> 8 & 0xff) / 255
        alpha = Double(full & 0xff) / 255
    }
}

/// The bar's colors, the roles Steve's SketchyBar theme gives it, read from
/// `~/.config/zenith/theme.json`, which his theme build renders.
public struct Theme: Equatable, Sendable {
    public var background: RGBA
    /// Text and glyphs.
    public var foreground: RGBA
    /// Workspaces not shown, and muted volume: the foreground at 50%.
    public var dim: RGBA
    /// The text of shown workspaces.
    public var selected: RGBA

    /// Tokyo Night, the theme Steve's Mac had when Zenith began, for a Mac without the file.
    public static let fallback = Theme(json: Data("""
        {"background": "#1a1b26", "foreground": "#a9b1d6", "dim": "#a9b1d680", "selected": "#c0caf5"}
        """.utf8))!

    /// Nil when `json` lacks a role or names a color it cannot read.
    public init?(json: Data) {
        guard let roles = try? JSONDecoder().decode([String: String].self, from: json),
              let background = roles["background"].flatMap(RGBA.init(hex:)),
              let foreground = roles["foreground"].flatMap(RGBA.init(hex:)),
              let dim = roles["dim"].flatMap(RGBA.init(hex:)),
              let selected = roles["selected"].flatMap(RGBA.init(hex:)) else { return nil }
        self.background = background
        self.foreground = foreground
        self.dim = dim
        self.selected = selected
    }
}
