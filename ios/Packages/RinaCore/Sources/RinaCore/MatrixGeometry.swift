import Foundation

/// Ports the WebUI matrix geometry (`EXPRESSION_PARTS.matrix` block, `app.js`
/// ~line 203) exactly: 22 columns, 18 rows, per-row valid x ranges centred in
/// the 22-wide grid, logical LED index assigned in row-major (top-to-bottom,
/// left-to-right within the row's valid range) order. Serpentine wiring only
/// affects the *physical* strip order, not the logical index used by the
/// packed frame / RinaLink wire format.
public enum MatrixGeometry {
    public static let cols = 22
    public static let rows = 18
    public static let ledCount = 370

    /// `MATRIX.row_lengths`
    public static let rowLengths: [Int] = [
        18, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 22, 20, 20, 20, 18, 16,
    ]

    public static let serpentine = true
    public static let serpentineOddRowsReversed = true

    /// `x0...x1` inclusive valid column range for `row`, centred: `xStart = (cols - rowLength) / 2`.
    public static func validXRange(row: Int) -> ClosedRange<Int>? {
        guard row >= 0 && row < rows else { return nil }
        let length = rowLengths[row]
        let xStart = (cols - length) / 2
        return xStart...(xStart + length - 1)
    }

    /// Logical LED index of the first LED in each row (prefix sum of `rowLengths`).
    private static let rowStartIndex: [Int] = {
        var table = [Int](repeating: 0, count: rows)
        var running = 0
        for row in 0..<rows {
            table[row] = running
            running += rowLengths[row]
        }
        return table
    }()

    private struct LedPosition {
        let x: Int
        let y: Int
    }

    /// `(x, y)` for every logical LED, built once by walking `rowLengths` /
    /// `validXRange` directly (row-major, left-to-right within the row).
    private static let ledPositions: [LedPosition] = {
        var result = [LedPosition]()
        result.reserveCapacity(ledCount)
        for row in 0..<rows {
            let range = validXRange(row: row)!
            for x in range {
                result.append(LedPosition(x: x, y: row))
            }
        }
        return result
    }()

    /// `y * cols + x` for every logical LED, for hot loops that need the flat
    /// cell index directly without calling `xy(ofLed:)`.
    public static let ledCellIndex: [Int] = {
        var table = [Int](repeating: 0, count: ledCount)
        for led in 0..<ledCount {
            let position = ledPositions[led]
            table[led] = position.y * cols + position.x
        }
        return table
    }()

    /// `logicalToPhysicalIndex` for every logical LED, computed directly
    /// (mirrored index within the row's valid range for odd rows) rather than
    /// by calling the public function.
    private static let logicalToPhysical: [Int] = {
        var table = [Int](repeating: 0, count: ledCount)
        for index in 0..<ledCount {
            guard serpentine else { table[index] = index; continue }
            let position = ledPositions[index]
            guard serpentineOddRowsReversed, (position.y & 1) != 0 else {
                table[index] = index
                continue
            }
            let range = validXRange(row: position.y)!
            let mirroredX = range.lowerBound + range.upperBound - position.x
            guard range.contains(mirroredX) else { table[index] = index; continue }
            table[index] = rowStartIndex[position.y] + (mirroredX - range.lowerBound)
        }
        return table
    }()

    /// Inverse of `logicalToPhysical`, computed once from it.
    private static let physicalToLogical: [Int] = {
        var table = [Int](repeating: 0, count: ledCount)
        for physical in 0..<ledCount {
            table[physical] = physical
        }
        for logical in 0..<ledCount {
            let physical = logicalToPhysical[logical]
            if physical >= 0 && physical < ledCount {
                table[physical] = logical
            }
        }
        return table
    }()

    /// Logical LED index for `(x, y)`, or nil if outside the row's valid range.
    public static func ledIndex(x: Int, y: Int) -> Int? {
        guard let range = validXRange(row: y), range.contains(x) else { return nil }
        return rowStartIndex[y] + (x - range.lowerBound)
    }

    /// `(x, y)` for a logical LED index, or nil if out of range.
    public static func xy(ofLed led: Int) -> (x: Int, y: Int)? {
        guard led >= 0 && led < ledCount else { return nil }
        let position = ledPositions[led]
        return (position.x, position.y)
    }

    /// Maps a logical LED index to its physical (serpentine-wired) strip index,
    /// mirroring `logicalToPhysicalIndex()` in the legacy `app.js`.
    public static func logicalToPhysicalIndex(_ index: Int) -> Int {
        guard index >= 0 && index < ledCount else { return index }
        return logicalToPhysical[index]
    }

    /// Inverse of `logicalToPhysicalIndex`.
    public static func physicalToLogicalIndex(_ index: Int) -> Int {
        guard index >= 0 && index < ledCount else { return index }
        return physicalToLogical[index]
    }
}
