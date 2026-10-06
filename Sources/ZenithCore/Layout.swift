/// Where each item's ink starts on a bar `width` wide, given each one's ink width: `left`
/// items from `insets.left` rightward, `right` items leftward to end `insets.right` before the
/// bar's end, the first of them at the end, with `gap` between neighbours.
public func layout(left: [Double], right: [Double], width: Double, insets: (left: Double, right: Double), gap: Double)
    -> (left: [Double], right: [Double])
{
    var x = insets.left
    let lefts = left.map { item in
        defer { x += item + gap }
        return x
    }
    x = width - insets.right + gap
    let rights = right.map { item in
        x -= item + gap
        return x
    }
    return (lefts, rights)
}
