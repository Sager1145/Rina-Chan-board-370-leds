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
}
