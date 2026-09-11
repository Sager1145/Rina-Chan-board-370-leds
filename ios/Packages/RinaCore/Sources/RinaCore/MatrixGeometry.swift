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

    /// Logical LED index for `(x, y)`, or nil if outside the row's valid range.
    public static func ledIndex(x: Int, y: Int) -> Int? {
        guard let range = validXRange(row: y), range.contains(x) else { return nil }
        var index = 0
        for row in 0..<y {
            index += rowLengths[row]
        }
        index += (x - range.lowerBound)
        return index
    }

    /// `(x, y)` for a logical LED index, or nil if out of range.
    public static func xy(ofLed led: Int) -> (x: Int, y: Int)? {
        guard led >= 0 && led < ledCount else { return nil }
        var remaining = led
        for row in 0..<rows {
            let length = rowLengths[row]
            if remaining < length {
                let range = validXRange(row: row)!
                return (range.lowerBound + remaining, row)
            }
            remaining -= length
        }
        return nil
    }

    /// Maps a logical LED index to its physical (serpentine-wired) strip index,
    /// mirroring `logicalToPhysicalIndex()` in the legacy `app.js`.
    public static func logicalToPhysicalIndex(_ index: Int) -> Int {
        guard let (x, y) = xy(ofLed: index), serpentine else { return index }
        guard serpentineOddRowsReversed, (y & 1) != 0 else { return index }
        let range = validXRange(row: y)!
        let mirroredX = range.lowerBound + range.upperBound - x
        return ledIndex(x: mirroredX, y: y) ?? index
    }

    /// Inverse of `logicalToPhysicalIndex`.
    public static func physicalToLogicalIndex(_ index: Int) -> Int {
        for logical in 0..<ledCount where logicalToPhysicalIndex(logical) == index {
            return logical
        }
        return index
    }
}
