import XCTest
@testable import RinaCore

final class MatrixGeometryTests: XCTestCase {
    func testRowLengthsSumTo370() {
        XCTAssertEqual(MatrixGeometry.rowLengths.reduce(0, +), 370)
        XCTAssertEqual(MatrixGeometry.rowLengths.count, MatrixGeometry.rows)
    }

    func testRow0Range() {
        // row 0 length 18 -> centred in 22: xStart = (22-18)/2 = 2 -> [2,19]
        XCTAssertEqual(MatrixGeometry.validXRange(row: 0), 2...19)
    }

    func testRow4FullWidthRange() {
        // row 4 length 22 -> [0,21]
        XCTAssertEqual(MatrixGeometry.validXRange(row: 4), 0...21)
    }

    func testLastRowRange() {
        // row 17 length 16 -> xStart = (22-16)/2 = 3 -> [3,18]
        XCTAssertEqual(MatrixGeometry.validXRange(row: 17), 3...18)
    }

    func testFirstLedIsRow0LeftEdge() {
        XCTAssertEqual(MatrixGeometry.ledIndex(x: 2, y: 0), 0)
        let xy = MatrixGeometry.xy(ofLed: 0)
        XCTAssertEqual(xy?.x, 2)
        XCTAssertEqual(xy?.y, 0)
    }

    func testSecondRowStartsAfterFirst() {
        // row0 has 18 leds (indices 0...17); row1 starts at index 18.
        XCTAssertEqual(MatrixGeometry.ledIndex(x: 1, y: 1), 18)
    }

    func testLastLedIsLastRowRightEdge() {
        XCTAssertEqual(MatrixGeometry.ledIndex(x: 18, y: 17), 369)
        let xy = MatrixGeometry.xy(ofLed: 369)
        XCTAssertEqual(xy?.x, 18)
        XCTAssertEqual(xy?.y, 17)
    }

    func testOutOfRangeReturnsNil() {
        XCTAssertNil(MatrixGeometry.ledIndex(x: 0, y: 0)) // row 0 valid range is 2...19
        XCTAssertNil(MatrixGeometry.xy(ofLed: 370))
        XCTAssertNil(MatrixGeometry.xy(ofLed: -1))
    }

    func testRoundTripAllLeds() {
        for led in 0..<MatrixGeometry.ledCount {
            guard let (x, y) = MatrixGeometry.xy(ofLed: led) else {
                XCTFail("no xy for led \(led)")
                continue
            }
            XCTAssertEqual(MatrixGeometry.ledIndex(x: x, y: y), led)
        }
    }

    func testSerpentineOddRowMirrored() {
        // row 1 is odd -> physical index should mirror x within the row's valid range.
        let logical = MatrixGeometry.ledIndex(x: 1, y: 1)! // leftmost of row1 [1,20]
        let physical = MatrixGeometry.logicalToPhysicalIndex(logical)
        let mirroredLogical = MatrixGeometry.ledIndex(x: 20, y: 1)! // rightmost of row1
        XCTAssertEqual(physical, mirroredLogical)
    }

    func testSerpentineEvenRowUnchanged() {
        let logical = MatrixGeometry.ledIndex(x: 2, y: 0)! // row 0 is even -> unchanged
        XCTAssertEqual(MatrixGeometry.logicalToPhysicalIndex(logical), logical)
    }

    // MARK: - PR-6 O(1) table exhaustive equality vs. the old scanning implementation

    func testLedIndexMatchesReferenceScanExhaustively() {
        for y in -2...(MatrixGeometry.rows + 1) {
            for x in -2...(MatrixGeometry.cols + 1) {
                XCTAssertEqual(MatrixGeometry.ledIndex(x: x, y: y),
                               MatrixGeometryScanReferencePR6.ledIndex(x: x, y: y),
                               "x=\(x) y=\(y)")
            }
        }
    }

    func testXyMatchesReferenceScanExhaustively() {
        for led in -2...(MatrixGeometry.ledCount + 1) {
            let actual = MatrixGeometry.xy(ofLed: led)
            let expected = MatrixGeometryScanReferencePR6.xy(ofLed: led)
            XCTAssertEqual(actual?.x, expected?.x, "led=\(led)")
            XCTAssertEqual(actual?.y, expected?.y, "led=\(led)")
        }
    }

    func testLogicalToPhysicalMatchesReferenceScanExhaustively() {
        for led in -2...(MatrixGeometry.ledCount + 1) {
            XCTAssertEqual(MatrixGeometry.logicalToPhysicalIndex(led),
                           MatrixGeometryScanReferencePR6.logicalToPhysicalIndex(led),
                           "led=\(led)")
        }
    }

    func testPhysicalToLogicalMatchesReferenceScanExhaustively() {
        for led in -2...(MatrixGeometry.ledCount + 1) {
            XCTAssertEqual(MatrixGeometry.physicalToLogicalIndex(led),
                           MatrixGeometryScanReferencePR6.physicalToLogicalIndex(led),
                           "led=\(led)")
        }
    }

    func testLedCellIndexMatchesXY() {
        for led in 0..<MatrixGeometry.ledCount {
            let xy = MatrixGeometry.xy(ofLed: led)!
            XCTAssertEqual(MatrixGeometry.ledCellIndex[led], xy.y * MatrixGeometry.cols + xy.x, "led=\(led)")
        }
    }
}

/// Verbatim copies of the pre-PR-6 `MatrixGeometry` scanning implementations,
/// kept only as a differential-testing reference for the O(1) table rewrite.
private enum MatrixGeometryScanReferencePR6 {
    static func ledIndex(x: Int, y: Int) -> Int? {
        guard let range = MatrixGeometry.validXRange(row: y), range.contains(x) else { return nil }
        var index = 0
        for row in 0..<y {
            index += MatrixGeometry.rowLengths[row]
        }
        index += (x - range.lowerBound)
        return index
    }

    static func xy(ofLed led: Int) -> (x: Int, y: Int)? {
        guard led >= 0 && led < MatrixGeometry.ledCount else { return nil }
        var remaining = led
        for row in 0..<MatrixGeometry.rows {
            let length = MatrixGeometry.rowLengths[row]
            if remaining < length {
                let range = MatrixGeometry.validXRange(row: row)!
                return (range.lowerBound + remaining, row)
            }
            remaining -= length
        }
        return nil
    }

    static func logicalToPhysicalIndex(_ index: Int) -> Int {
        guard let (x, y) = xy(ofLed: index), MatrixGeometry.serpentine else { return index }
        guard MatrixGeometry.serpentineOddRowsReversed, (y & 1) != 0 else { return index }
        let range = MatrixGeometry.validXRange(row: y)!
        let mirroredX = range.lowerBound + range.upperBound - x
        return ledIndex(x: mirroredX, y: y) ?? index
    }

    static func physicalToLogicalIndex(_ index: Int) -> Int {
        for logical in 0..<MatrixGeometry.ledCount where logicalToPhysicalIndex(logical) == index {
            return logical
        }
        return index
    }
}
