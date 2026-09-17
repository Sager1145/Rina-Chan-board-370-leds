import XCTest
@testable import RinaBoard

final class RingBufferTests: XCTestCase {
    func testAppendBelowCapacityPreservesInsertionOrder() {
        var buffer = RingBuffer<Int>(capacity: 5)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        XCTAssertEqual(buffer.elementCount, 3)
        XCTAssertFalse(buffer.isFull)
        XCTAssertEqual(buffer.elements, [1, 2, 3])
    }

    func testAppendAtExactCapacityKeepsAllElementsInOrder() {
        var buffer = RingBuffer<Int>(capacity: 4)
        for value in 1...4 { buffer.append(value) }
        XCTAssertTrue(buffer.isFull)
        XCTAssertEqual(buffer.elements, [1, 2, 3, 4])
    }

    func testAppendBeyondCapacityEvictsOldestAndPreservesOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...10 { buffer.append(value) }
        // Only the most recent `capacity` elements should remain, oldest
        // first: 8, 9, 10.
        XCTAssertEqual(buffer.elementCount, 3)
        XCTAssertEqual(buffer.elements, [8, 9, 10])
    }

    func testWraparoundAcrossMultipleFullCyclesStaysConsistent() {
        var buffer = RingBuffer<Int>(capacity: 5)
        // Push far more than a couple of multiples of capacity to exercise
        // several wraps of the internal head index.
        for value in 1...37 { buffer.append(value) }
        XCTAssertEqual(buffer.elements, [33, 34, 35, 36, 37])
    }

    func testRemoveAllResetsToEmpty() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.elementCount, 0)
        XCTAssertEqual(buffer.elements, [])
        buffer.append(9)
        XCTAssertEqual(buffer.elements, [9])
    }

    func testSequenceIterationMatchesElementsOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        XCTAssertEqual(Array(buffer), buffer.elements)
        XCTAssertEqual(Array(buffer), [3, 4, 5])
    }
}
