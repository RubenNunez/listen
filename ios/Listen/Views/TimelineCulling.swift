import Foundation

enum TimelineCulling {
    /// Row layout guarantees ordered, nonoverlapping boxes, including label widths.
    /// Binary search retains an item starting far before the viewport if it spans it.
    static func indices(count: Int, lower: CGFloat, upper: CGFloat,
                        left: (Int) -> CGFloat, right: (Int) -> CGFloat) -> Range<Int> {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if right(middle) < lower { low = middle + 1 } else { high = middle }
        }
        let first = low
        high = count
        while low < high {
            let middle = (low + high) / 2
            if left(middle) <= upper { low = middle + 1 } else { high = middle }
        }
        return first..<low
    }
}
