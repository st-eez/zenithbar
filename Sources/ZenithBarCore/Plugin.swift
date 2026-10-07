import Foundation

/// One line a plugin prints on its standard output: an item it shows on the bar, and the
/// panel a click opens (docs/plugins.md).
public struct PluginItem: Decodable, Equatable, Sendable {
    public var item: String
    /// The glyph the bar shows.
    public var icon: String
    /// An SF Symbol the bar and the panel show in place of `icon`, which stays the fallback
    /// when macOS has no symbol of that name.
    public var symbol: String?
    /// Drawn in the theme's alert color.
    public var alert: Bool
    public var hidden: Bool
    /// The panel's pages, one at a time, the next on a middle click or a click on its tabs.
    public var pages: [Page]

    /// An item ZenithBar builds itself, as the network item's panel.
    public init(item: String, icon: String, symbol: String? = nil, alert: Bool = false, hidden: Bool = false, pages: [Page]) {
        (self.item, self.icon, self.symbol, self.alert, self.hidden, self.pages) = (item, icon, symbol, alert, hidden, pages)
    }

    public struct Page: Decodable, Equatable, Sendable {
        /// The tab that names the page among several.
        public var tab: String
        public var title: String
        public var rows: [Row]

        public init(tab: String = "", title: String, rows: [Row]) {
            (self.tab, self.title, self.rows) = (tab, title, rows)
        }
    }

    public enum Tone: String, Decodable, Sendable {
        case normal, dim, warning, alert
    }

    public enum Row: Decodable, Equatable, Sendable {
        /// A small heading over a group of rows.
        case caption(String)
        /// A label, a bar filled to `value` from 0 to 1, and `detail` at the right.
        case meter(label: String, value: Double, detail: String, tone: Tone, bold: Bool)
        /// A line of small text: `text`, then the time to `until` or since `since`, then `detail`.
        case note(text: String, until: Date?, since: Date?, detail: String?, tone: Tone)

        private enum Keys: String, CodingKey {
            case caption, meter, value, detail, tone, bold, note, until, since
        }

        public init(from decoder: Decoder) throws {
            let row = try decoder.container(keyedBy: Keys.self)
            let tone = try row.decodeIfPresent(Tone.self, forKey: .tone) ?? .normal
            let date = { (key: Keys) in try row.decodeIfPresent(Double.self, forKey: key).map(Date.init(timeIntervalSince1970:)) }
            if let caption = try row.decodeIfPresent(String.self, forKey: .caption) {
                self = .caption(caption)
            } else if let label = try row.decodeIfPresent(String.self, forKey: .meter) {
                self = .meter(label: label, value: min(1, max(0, try row.decode(Double.self, forKey: .value))),
                              detail: try row.decodeIfPresent(String.self, forKey: .detail) ?? "", tone: tone,
                              bold: try row.decodeIfPresent(Bool.self, forKey: .bold) ?? false)
            } else if let text = try row.decodeIfPresent(String.self, forKey: .note) {
                self = .note(text: text, until: try date(.until), since: try date(.since),
                             detail: try row.decodeIfPresent(String.self, forKey: .detail), tone: tone)
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "a row is a caption, a meter or a note"))
            }
        }
    }

    private enum Keys: String, CodingKey { case item, icon, symbol, alert, hidden, pages }

    public init(from decoder: Decoder) throws {
        let line = try decoder.container(keyedBy: Keys.self)
        item = try line.decode(String.self, forKey: .item)
        icon = try line.decode(String.self, forKey: .icon)
        symbol = try line.decodeIfPresent(String.self, forKey: .symbol)
        alert = try line.decodeIfPresent(Bool.self, forKey: .alert) ?? false
        hidden = try line.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        pages = try line.decodeIfPresent([Page].self, forKey: .pages) ?? []
    }

    /// The item on `line`, or nil when it is not one.
    public static func decode(_ line: Data) -> PluginItem? { try? JSONDecoder().decode(PluginItem.self, from: line) }
}

/// A note's text at `now`: "Resets in 2h 5m", "Updated 3m ago · 941 prompts".
public func noteText(_ text: String, until: Date?, since: Date?, detail: String?, now: Date) -> String {
    var parts = [text]
    if let until { parts[0] += " " + duration(until.timeIntervalSince(now)) }
    if let since { parts[0] += " " + ago(now.timeIntervalSince(since)) }
    if let detail, !detail.isEmpty { parts.append(detail) }
    return parts.joined(separator: "  ·  ")
}

/// "2d 22h", "1h 59m", "5m", as Omarchy's agents panel writes a time left.
func duration(_ seconds: Double) -> String {
    guard seconds > 0 else { return "now" }
    let minutes = Int(seconds / 60), hours = minutes / 60, days = hours / 24
    if days > 0 { return "\(days)d \(hours % 24)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(max(1, minutes))m"
}

/// "just now", "12m ago", "3h ago".
func ago(_ seconds: Double) -> String {
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    return "\(Int(seconds / 3600))h ago"
}
