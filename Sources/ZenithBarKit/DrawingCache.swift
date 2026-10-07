import CoreGraphics

/// Drawings kept from one render to the next, each drawn again only when what it shows changes:
/// the bar compares an item's image by identity, so a new one redraws its layer on every render,
/// and cropping a symbol to its ink scans every pixel. Keyed by type, as an `AnyHashable` key
/// built at each lookup cost a render 4% more (docs/overview.md, modules).
public struct DrawingCache<Drawing> {
    private struct Slot: Hashable {
        var name: String
        var scale: CGFloat
    }

    private var drawn: [Slot: (shows: any Equatable, drawing: Drawing)] = [:]

    public init() {}

    /// `name`'s drawing at `scale`, from `draw` when what it `shows` differs from its last
    /// drawing's.
    public mutating func drawing<Shows: Equatable>(_ name: String, scale: CGFloat, shows: Shows,
                                                   draw: () -> Drawing) -> Drawing {
        let slot = Slot(name: name, scale: scale)
        if let last = drawn[slot], last.shows as? Shows == shows { return last.drawing }
        let drawing = draw()
        drawn[slot] = (shows, drawing)
        return drawing
    }
}
