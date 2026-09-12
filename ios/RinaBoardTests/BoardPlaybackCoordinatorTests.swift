import XCTest
@testable import RinaBoard

@MainActor
final class BoardPlaybackCoordinatorTests: XCTestCase {
    func testBeginInvalidatesOldTokenBeforeStoppingPreviousSource() throws {
        let coordinator = BoardPlaybackCoordinator()
        var events: [String] = []
        coordinator.register(.manual) {
            events.append("stop:\(coordinator.source?.rawValue ?? "none")")
        }

        let oldToken = coordinator.begin(.manual)
        let newToken = coordinator.begin(.text)
        events.append("returned")

        XCTAssertEqual(events, ["stop:text", "returned"])
        XCTAssertFalse(coordinator.isCurrent(oldToken))
        XCTAssertTrue(coordinator.isCurrent(newToken))
        XCTAssertThrowsError(try coordinator.check(oldToken)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testClaimReusesCurrentSessionAndOnlyStopsWhenSourceChanges() {
        let coordinator = BoardPlaybackCoordinator()
        var stopCount = 0
        coordinator.register(.text) { stopCount += 1 }

        let first = coordinator.claim(.text)
        let reused = coordinator.claim(.text)
        let replacement = coordinator.claim(.debug)

        XCTAssertEqual(first, reused)
        XCTAssertNotEqual(first, replacement)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(coordinator.source, .debug)
    }

    func testInvalidateClearsSessionBeforeRunningStopHandler() throws {
        let coordinator = BoardPlaybackCoordinator()
        var sourceObservedByHandler: BoardOutputSource?
        coordinator.register(.performance) {
            sourceObservedByHandler = coordinator.source
        }
        let token = coordinator.begin(.performance)

        coordinator.invalidate()

        XCTAssertNil(sourceObservedByHandler)
        XCTAssertNil(coordinator.source)
        XCTAssertNil(coordinator.session)
        XCTAssertThrowsError(try coordinator.check(token)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}
