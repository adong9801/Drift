import Foundation

/// The Ctrl-Tab overlay as a grid: five across, as many rows as it takes.
enum SwitcherGrid {

    static let columns = 5

    static func rows(for count: Int) -> Int {
        count <= 0 ? 0 : (count + columns - 1) / columns
    }

    /// One step along, wrapping at either end. What Tab and the side arrows do.
    static func step(from index: Int, count: Int, backwards: Bool) -> Int {
        guard count > 0 else { return 0 }
        return (index + (backwards ? -1 : 1) + count) % count
    }

    /// One row up or down, staying in the same column. Off the bottom comes
    /// back in at the top, and the other way round. A last row that is short
    /// has no card under some columns; those land on its final card instead.
    static func jumpRow(from index: Int, count: Int, down: Bool) -> Int {
        guard count > 0 else { return 0 }
        let total = rows(for: count)
        guard total > 1 else { return index }
        let column = index % columns
        let row = index / columns
        let target = (row + (down ? 1 : -1) + total) % total
        return min(target * columns + column, count - 1)
    }
}
