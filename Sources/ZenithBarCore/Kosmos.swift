import Foundation

/// Kosmos's bar snapshot, sent whole on every change (Kosmos's docs/ipc.md). A new `version`
/// may rename or remove fields, and new fields can appear in any version.
public struct KosmosState: Decodable, Equatable, Sendable {
    // Only the fields ZenithBar reads, so a change Kosmos makes to the others cannot make it
    // reject a snapshot.

    public struct Display: Decodable, Equatable, Sendable {
        /// Kosmos's number for the display, which its workspaces name.
        public var id: Int
        /// CoreGraphics' UUID for the display, which ZenithBar matches its screens by; nil from a
        /// Kosmos before 638151c, or when CoreGraphics gives none.
        public var uuid: String?
    }

    public struct Window: Decodable, Equatable, Sendable {
        public var app: String
        /// Hidden with its app, after the windows shown; nil from a Kosmos before it added the
        /// field.
        public var hidden: Bool?
    }

    public struct Workspace: Decodable, Equatable, Sendable {
        public var name: String
        /// The `id` of its display, 0 when no connected display holds it. Kosmos gives 0 also
        /// when it manages no display, and gives every display 1 when one is active, so
        /// `displayUUID` is the join to trust.
        public var display: Int
        /// CoreGraphics' UUID for the display it is laid out on; nil from a Kosmos before it
        /// added the field, when ZenithBar joins by `display`.
        public var displayUUID: String?
        public var shown: Bool
        /// Shown on the display that has focus.
        public var focused: Bool
        /// Left to right, then top to bottom.
        public var windows: [Window]
    }

    public struct Focus: Decodable, Equatable, Sendable {
        public var app: String
    }

    public static let version = 1

    public var version: Int
    public var displays: [Display]
    public var workspaces: [Workspace]
    /// Nil on an empty workspace.
    public var focused: Focus?

    /// The snapshot in `data`, or nil when it is not one or has a version ZenithBar does not read.
    public static func decode(_ data: Data) -> KosmosState? {
        struct Versioned: Decodable { var version: Int }
        guard (try? JSONDecoder().decode(Versioned.self, from: data))?.version == version else { return nil }
        return try? JSONDecoder().decode(KosmosState.self, from: data)
    }
}
