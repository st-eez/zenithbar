/// Where each item's ink starts on a bar `width` wide, given each one's ink width: `left`
/// items from `insets.left` rightward, `right` items leftward to end `insets.right` before the
/// bar's end, the first of them at the end, with `gap` between neighbours. The left run ends
/// `gap` before the right run and before `notch`, the left edge of the camera housing on a
/// display with one; the left items that would pass that are left out, from the end, so fewer
/// starts may come back for `left` than items.
public func layout(left: [Double], right: [Double], width: Double, insets: (left: Double, right: Double), gap: Double,
                   notch: Double?) -> (left: [Double], right: [Double])
{
    var x = width - insets.right + gap
    let rights = right.map { item in
        x -= item + gap
        return x
    }
    let limit = min(x, notch ?? x) - gap
    var lefts: [Double] = []
    x = insets.left
    for item in left {
        guard x + item <= limit else { break }
        lefts.append(x)
        x += item + gap
    }
    return (lefts, rights)
}
