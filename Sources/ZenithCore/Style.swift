import CoreGraphics
import Foundation

/// The bar's shape. Every style is 25 pt tall at the display's top; the panel spans the
/// display, and clicks outside the outline reach what is behind it (docs/overview.md, clicks).
public enum BarStyle: String, Decodable, Sendable {
    /// Edge to edge, square.
    case standard
    /// Inset from the sides, its bottom corners rounded, its top square against the edge, as
    /// Steve's SketchyBar floating style shows it with its top tucked off screen.
    case floating
    /// Inset from the sides, its top corners flaring out into the screen's edge and its
    /// bottom corners rounded, as Noctalia's bar with `concave_edge_corners`.
    case tab

    public static let height = 25.0

    /// From each end of the display to the bar's body.
    var margin: Double { self == .standard ? 0 : 240 }
    var radius: Double { [.standard: 0, .floating: 9, .tab: 12][self]! }
    /// Where the top corners meet the screen's edge, the arc they flare out on.
    var flare: Double { self == .tab ? 12 : 0 }

    /// From each end of the display to the ink of the first item, left and right: in
    /// `standard`, where the ink of Steve's SketchyBar items began and ended.
    public var insets: (left: Double, right: Double) {
        switch self {
        case .standard: (21, 23)
        case .floating: (margin + 7, margin + 7)
        case .tab: (margin + 15, margin + 15)
        }
    }

    /// The bar's outline on a display `width` wide, origin at the bottom left.
    public func outline(width: Double) -> CGPath {
        let path = CGMutablePath(), h = Self.height, r = flare, R = radius
        let left = margin, right = width - margin
        path.move(to: CGPoint(x: left - r, y: h))
        if r > 0 {
            path.addArc(center: CGPoint(x: left - r, y: h - r), radius: r, startAngle: .pi / 2, endAngle: 0,
                        clockwise: true)
        }
        path.addLine(to: CGPoint(x: left, y: R))
        if R > 0 {
            path.addArc(center: CGPoint(x: left + R, y: R), radius: R, startAngle: .pi, endAngle: 1.5 * .pi,
                        clockwise: false)
        }
        path.addLine(to: CGPoint(x: right - R, y: 0))
        if R > 0 {
            path.addArc(center: CGPoint(x: right - R, y: R), radius: R, startAngle: 1.5 * .pi, endAngle: 2 * .pi,
                        clockwise: false)
        }
        path.addLine(to: CGPoint(x: right, y: h - r))
        if r > 0 {
            path.addArc(center: CGPoint(x: right + r, y: h - r), radius: r, startAngle: .pi, endAngle: .pi / 2,
                        clockwise: true)
        }
        path.closeSubpath()
        return path
    }
}

/// `~/.config/zenith/config.json`, read again whenever its folder changes.
public struct Config: Decodable, Equatable, Sendable {
    public var style: BarStyle = .standard

    public init() {}

    /// Nil when `json` is not a config Zenith reads, as with an unknown style.
    public init?(json: Data) {
        guard let config = try? JSONDecoder().decode(Config.self, from: json) else { return nil }
        self = config
    }

    private enum CodingKeys: String, CodingKey { case style }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(BarStyle.self, forKey: .style) ?? .standard
    }
}
