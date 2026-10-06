/// A workspace's pill: its name, then a glyph for each of its windows.
public struct Pill: Equatable, Sendable {
    public enum Emphasis: Equatable, Sendable {
        /// Shown on the display that has focus: bright and bold.
        case focused
        /// Shown on another display: bright.
        case shown
        /// Dim, bright while hovered.
        case hidden
    }

    public var name: String
    /// sketchybar-app-font ligatures, one per window, apart by a space.
    public var glyphs: String
    public var emphasis: Emphasis
}

/// What each display's bar shows of Kosmos.
public struct WorkspaceRow: Equatable, Sendable {
    /// In Kosmos's order, the workspaces it lays out on this display.
    public var pills: [Pill]
    /// The focused app, "Desktop" on an empty workspace, on the display with focus alone.
    public var frontApp: String?
}

/// Each display's row, by Kosmos's number for it. A workspace whose display is 0, on no
/// connected display, shows nowhere. `icons` maps an app's name to its glyph, with "Default"
/// for apps it lacks.
public func workspaceRows(_ state: KosmosState, icons: [String: String]) -> [Int: WorkspaceRow] {
    var rows: [Int: WorkspaceRow] = [:]
    for display in state.displays { rows[display.id] = WorkspaceRow(pills: [], frontApp: nil) }
    for workspace in state.workspaces where workspace.display != 0 {
        let glyphs = workspace.windows.map { icons[$0.app] ?? icons["Default"] ?? "" }
        let emphasis: Pill.Emphasis = workspace.focused ? .focused : workspace.shown ? .shown : .hidden
        rows[workspace.display, default: WorkspaceRow(pills: [], frontApp: nil)].pills
            .append(Pill(name: workspace.name, glyphs: glyphs.joined(separator: " "), emphasis: emphasis))
        if workspace.focused {
            rows[workspace.display]?.frontApp = state.focused?.app ?? "Desktop"
        }
    }
    return rows
}
