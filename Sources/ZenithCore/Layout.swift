/// Each item's left edge on a bar `width` wide: `left` items from `insets.left` rightward,
/// `right` items from `insets.right` before the bar's end leftward, the first of them at the
/// end. Widths include each item's own padding.
public func layout(left: [Double], right: [Double], width: Double, insets: (left: Double, right: Double))
    -> (left: [Double], right: [Double])
{
    var x = insets.left
    let lefts = left.map { item in
        defer { x += item }
        return x
    }
    x = width - insets.right
    let rights = right.map { item in
        x -= item
        return x
    }
    return (lefts, rights)
}
