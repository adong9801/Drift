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
        let full = Array(repeating: columns, count: count / columns)
        return jumpRow(from: index, rowLengths: count % columns == 0 ? full : full + [count % columns], down: down)
    }

    /// The same over rows of any length, which is what a grid with a row per
    /// tab group has: a short row can come anywhere, not only last.
    static func jumpRow(from index: Int, rowLengths: [Int], down: Bool) -> Int {
        let lengths = rowLengths.filter { $0 > 0 }
        guard lengths.count > 1 else { return index }
        var start = 0
        var row = 0
        while row < lengths.count - 1, index >= start + lengths[row] {
            start += lengths[row]
            row += 1
        }
        let column = index - start
        let target = (row + (down ? 1 : -1) + lengths.count) % lengths.count
        let targetStart = lengths.prefix(target).reduce(0, +)
        return targetStart + min(column, lengths[target] - 1)
    }
}
