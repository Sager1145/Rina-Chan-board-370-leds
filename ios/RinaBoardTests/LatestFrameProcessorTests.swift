import XCTest
@testable import RinaBoard

@MainActor
final class LatestFrameProcessorTests: XCTestCase {
    func testSingleSubmitIsDelivered() {
        let delivered = expectation(description: "delivered")
        var receivedValues: [Int] = []
        let processor = LatestFrameProcessor<Int, Int>(
            transform: { $0 * 2 },
            deliver: { value in
                receivedValues.append(value)
                delivered.fulfill()
            }
        )
        processor.submit(1)
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(receivedValues, [2])
    }

    func testPendingInputIsCoalescedToLatest() {
        // A blocks in `transform` until the gate is released; while it is in
        // flight, submitting B then C leaves only C pending (B replaced), so
        // the delivered sequence is exactly [A, C] — B's transform never runs.
        let gate = DispatchSemaphore(value: 0)
        let aStarted = expectation(description: "a started")
        let cDelivered = expectation(description: "c delivered")
        var deliveredOrder: [Int] = []

        let processor = LatestFrameProcessor<Int, Int>(
            transform: { input in
                if input == 1 {
                    aStarted.fulfill()
                    gate.wait()
                }
                return input
            },
            deliver: { value in
                deliveredOrder.append(value)
                if value == 3 { cDelivered.fulfill() }
            }
        )

        processor.submit(1) // A: starts immediately, blocks in transform
        wait(for: [aStarted], timeout: 2)

        processor.submit(2) // B: processor busy -> becomes the pending input
        processor.submit(3) // C: replaces B as the pending input

        gate.signal() // let A's transform return
        wait(for: [cDelivered], timeout: 2)

        XCTAssertEqual(deliveredOrder, [1, 3])
    }

    func testInvalidateDropsInFlightResultAndAllowsLaterSubmit() {
        let gate = DispatchSemaphore(value: 0)
        let aStarted = expectation(description: "a started")
        let laterDelivered = expectation(description: "later delivered")
        var deliveredValues: [Int] = []

        let processor = LatestFrameProcessor<Int, Int>(
            transform: { input in
                if input == 1 {
                    aStarted.fulfill()
                    gate.wait()
                }
                return input
            },
            deliver: { value in
                deliveredValues.append(value)
                if value == 99 { laterDelivered.fulfill() }
            }
        )

        processor.submit(1)
        wait(for: [aStarted], timeout: 2)
        processor.invalidate()
        gate.signal() // let A's transform return; its result must be discarded

        processor.submit(99)
        wait(for: [laterDelivered], timeout: 2)
        XCTAssertEqual(deliveredValues, [99], "invalidated result A must never be delivered")
    }

    func testTransformRunsOffMainThreadAndDeliverRunsOnMainThread() {
        let delivered = expectation(description: "delivered")
        let transformWasOnMainBox = LockedBox(true)
        var deliverWasOnMain = false

        let processor = LatestFrameProcessor<Int, Int>(
            transform: { input in
                transformWasOnMainBox.value = Thread.isMainThread
                return input
            },
            deliver: { _ in
                deliverWasOnMain = Thread.isMainThread
                delivered.fulfill()
            }
        )
        processor.submit(1)
        wait(for: [delivered], timeout: 2)
        XCTAssertFalse(transformWasOnMainBox.value)
        XCTAssertTrue(deliverWasOnMain)
    }

    func testInvalidateDropsPendingInput() {
        // A blocks in `transform` until the gate is released; while it is in
        // flight, submitting 2 then invalidating drops the pending input, and
        // a later submit of 3 becomes the new pending input. Only 3 should
        // ever be delivered.
        let gate = DispatchSemaphore(value: 0)
        let aStarted = expectation(description: "a started")
        let delivered = expectation(description: "delivered")
        var deliveredValues: [Int] = []

        let processor = LatestFrameProcessor<Int, Int>(
            transform: { input in
                if input == 1 {
                    aStarted.fulfill()
                    gate.wait()
                }
                return input
            },
            deliver: { value in
                deliveredValues.append(value)
                delivered.fulfill()
            }
        )

        processor.submit(1) // A: starts immediately, blocks in transform
        wait(for: [aStarted], timeout: 2)

        processor.submit(2) // becomes the pending input
        processor.invalidate() // drops pending input 2
        processor.submit(3) // becomes the new pending input

        gate.signal() // let A's transform return (its result is discarded on delivery of 1)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(deliveredValues, [3])
    }

    func testNilTransformResultClearsBusyAndRunsPending() {
        let gate = DispatchSemaphore(value: 0)
        let aStarted = expectation(description: "a started")
        let delivered = expectation(description: "delivered")
        var deliveredValues: [Int] = []

        var processor: LatestFrameProcessor<Int, Int>!
        processor = LatestFrameProcessor<Int, Int>(
            transform: { input in
                if input == 1 {
                    aStarted.fulfill()
                    gate.wait()
                    return nil
                }
                return input
            },
            deliver: { value in
                deliveredValues.append(value)
                delivered.fulfill()
            }
        )

        processor.submit(1) // A: starts immediately, blocks in transform, returns nil
        wait(for: [aStarted], timeout: 2)

        processor.submit(2) // becomes the pending input while A is in flight

        gate.signal() // let A's transform return nil

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(deliveredValues, [2])
        XCTAssertFalse(processor.isBusy)
    }
}

/// A tiny lock-protected box for values written from a background transform
/// and read from the test's main-actor context, avoiding a data race on a
/// plain captured `var`.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}
