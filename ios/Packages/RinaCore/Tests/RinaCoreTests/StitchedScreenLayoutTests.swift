import XCTest
@testable import RinaCore

final class StitchedScreenLayoutTests: XCTestCase {
    func testSingleBoardNoGaps() throws {
        let layout = try StitchedScreenLayout(slotCount: 1, gapsAfter: [])
        XCTAssertEqual(layout.virtualWidth, 22)
        XCTAssertEqual(layout.viewportX(slot: 0), 0)
    }

    func testFiveBoardsNoGaps() throws {
        let layout = try StitchedScreenLayout(slotCount: 5, gapsAfter: [0, 0, 0, 0])
        XCTAssertEqual(layout.virtualWidth, 110)
        XCTAssertEqual((0..<5).map { layout.viewportX(slot: $0) }, [0, 22, 44, 66, 88])
    }

    func testFiveBoardsMaxGaps() throws {
        let layout = try StitchedScreenLayout(slotCount: 5, gapsAfter: [8, 8, 8, 8])
        // 22*5 + 8*4 = 142, within the 22...200 virtualWidth bound (§1.1/§1.4).
        XCTAssertEqual(layout.virtualWidth, 142)
        XCTAssertEqual((0..<5).map { layout.viewportX(slot: $0) }, [0, 30, 60, 90, 120])
    }

    func testMixedGaps() throws {
        let layout = try StitchedScreenLayout(slotCount: 3, gapsAfter: [3, 0])
        XCTAssertEqual(layout.viewportX(slot: 0), 0)
        XCTAssertEqual(layout.viewportX(slot: 1), 25) // 22 + 3
        XCTAssertEqual(layout.viewportX(slot: 2), 47) // 25 + 22 + 0
        XCTAssertEqual(layout.virtualWidth, 69) // 47 + 22
    }

    /// Every valid slotCount/gap combination keeps virtualWidth within the
    /// wire bound (22...200, §1.1/§1.4) with no extra clamping needed.
    func testVirtualWidthAlwaysWithinWireBounds() throws {
        for slotCount in 1...5 {
            for gap in [0, 8] {
                let gaps = [Int](repeating: gap, count: max(0, slotCount - 1))
                let layout = try StitchedScreenLayout(slotCount: slotCount, gapsAfter: gaps)
                XCTAssertGreaterThanOrEqual(layout.virtualWidth, 22)
                XCTAssertLessThanOrEqual(layout.virtualWidth, 200)
            }
        }
    }

    func testInvalidSlotCountThrows() {
        XCTAssertThrowsError(try StitchedScreenLayout(slotCount: 0, gapsAfter: [])) { error in
            XCTAssertEqual(error as? StitchedScreenLayout.LayoutError, .invalidSlotCount(0))
        }
        XCTAssertThrowsError(try StitchedScreenLayout(slotCount: 6, gapsAfter: [0, 0, 0, 0, 0])) { error in
            XCTAssertEqual(error as? StitchedScreenLayout.LayoutError, .invalidSlotCount(6))
        }
    }

    func testWrongGapsCountThrows() {
        XCTAssertThrowsError(try StitchedScreenLayout(slotCount: 3, gapsAfter: [0])) { error in
            XCTAssertEqual(
                error as? StitchedScreenLayout.LayoutError,
                .invalidGapsCount(expected: 2, got: 1)
            )
        }
    }

    func testOutOfRangeGapThrows() {
        XCTAssertThrowsError(try StitchedScreenLayout(slotCount: 2, gapsAfter: [9])) { error in
            XCTAssertEqual(error as? StitchedScreenLayout.LayoutError, .invalidGap(index: 0, value: 9))
        }
        XCTAssertThrowsError(try StitchedScreenLayout(slotCount: 2, gapsAfter: [-1])) { error in
            XCTAssertEqual(error as? StitchedScreenLayout.LayoutError, .invalidGap(index: 0, value: -1))
        }
    }
}
