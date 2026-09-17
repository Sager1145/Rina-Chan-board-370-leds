import Observation
import XCTest
@testable import RinaBoard

@MainActor
final class DebugLogBufferingTests: XCTestCase {
    func testLogIsRingBufferedAndCappedAt500AfterFlush() {
        let vm = DebugViewModel()
        for i in 0..<600 {
            vm.log(.info, "line \(i)")
        }
        vm.flushPendingLogs()
        XCTAssertEqual(vm.logs.count, 500)
        // Oldest 100 lines (0...99) should have been evicted; the buffer
        // keeps the newest 500 (100...599), oldest-first.
        XCTAssertEqual(vm.logs.first?.message, "line 100")
        XCTAssertEqual(vm.logs.last?.message, "line 599")
    }

    func testFlushPendingLogsIsDeterministicWithoutWaitingForScheduledFlush() {
        let vm = DebugViewModel()
        vm.log(.info, "immediate")
        // Without calling flushPendingLogs(), the published snapshot may not
        // yet reflect the appended line (it's coalesced). The explicit flush
        // hook makes the appearance deterministic for tests.
        vm.flushPendingLogs()
        XCTAssertEqual(vm.logs.last?.message, "immediate")
    }

    func testVisibleLogsCacheInvalidatesOnNewLogsFilterChangeAndClear() {
        let vm = DebugViewModel()
        vm.log(.error, "boom")
        vm.flushPendingLogs()
        XCTAssertEqual(vm.visibleLogs.first?.message, "boom")

        // New logs must invalidate the cache.
        vm.log(.error, "boom2")
        vm.flushPendingLogs()
        XCTAssertEqual(vm.visibleLogs.first?.message, "boom2")

        // Changing the filter must invalidate the cache even with no new logs.
        vm.logFilter = .errorsOnly
        XCTAssertEqual(vm.visibleLogs.count, 2)
        vm.log(.debug, "quiet")
        vm.flushPendingLogs()
        XCTAssertEqual(vm.visibleLogs.count, 2, "debug line must stay filtered out under errorsOnly")

        // Changing the search text must invalidate the cache.
        vm.logSearch = "boom2"
        XCTAssertEqual(vm.visibleLogs.map(\.message), ["boom2"])

        // Clear must invalidate the cache and empty the result.
        vm.logSearch = ""
        vm.clearLog()
        XCTAssertTrue(vm.visibleLogs.isEmpty)
    }

    func testVisibleLogsCacheInvalidatesOnLogSourceChange() {
        let vm = DebugViewModel()
        vm.log(.info, "app line", source: .app)
        vm.log(.info, "firmware line", source: .firmware)
        vm.flushPendingLogs()
        XCTAssertEqual(vm.visibleLogs.count, 2)

        vm.logSource = .firmware
        XCTAssertEqual(vm.visibleLogs.map(\.message), ["firmware line"])

        vm.logSource = .app
        XCTAssertEqual(vm.visibleLogs.map(\.message), ["app line"])

        vm.logSource = nil
        XCTAssertEqual(vm.visibleLogs.count, 2)
    }

    func testClearLogWhilePausedEmptiesBothLiveAndPausedSnapshots() {
        let vm = DebugViewModel()
        vm.log(.info, "before-pause")
        vm.isLogDisplayPaused = true
        XCTAssertEqual(vm.visibleLogs.map(\.message), ["before-pause"])

        vm.clearLog()
        XCTAssertTrue(vm.visibleLogs.isEmpty)

        // Resuming after a clear-while-paused must not resurrect anything
        // from the (now-cleared) live snapshot.
        vm.isLogDisplayPaused = false
        XCTAssertTrue(vm.visibleLogs.isEmpty)
        XCTAssertTrue(vm.logs.isEmpty)
    }

    /// Regression test for a defect class where `visibleLogs` was a lazily
    /// recomputed getter over an `@ObservationIgnored` dirty flag/cache: a
    /// read that lands on the already-clean branch returns the cached array
    /// directly, without touching any tracked property, so it registers no
    /// Observation dependency — a later flush would never re-invoke a
    /// SwiftUI body that had already rendered once.
    ///
    /// Every other test in this file reads `vm.visibleLogs` as a plain,
    /// untracked property access, which recomputes-on-demand regardless of
    /// whether the *notification* path works — so none of them can catch
    /// this. This test deliberately primes the cache into the clean state
    /// with an untracked read *before* opening `withObservationTracking`,
    /// so the tracked read below is the clean-path read a second SwiftUI
    /// body pass would actually perform.
    func testVisibleLogsChangeIsObservableThroughObservationTracking() {
        let vm = DebugViewModel()
        vm.log(.info, "seed")
        vm.flushPendingLogs()
        _ = vm.visibleLogs // untracked: primes the cache into the clean state

        let changed = expectation(description: "visibleLogs change observed")
        withObservationTracking {
            _ = vm.visibleLogs // the clean-path read that must still track
        } onChange: {
            changed.fulfill()
        }

        vm.log(.info, "line two")
        vm.flushPendingLogs()
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(vm.visibleLogs.map(\.message), ["line two", "seed"])
    }

    func testPauseSnapshotsCurrentLogsAndResumeShowsLinesLoggedWhilePaused() {
        let vm = DebugViewModel()
        vm.log(.info, "before-pause")
        vm.isLogDisplayPaused = true
        XCTAssertEqual(vm.visibleLogs.map(\.message), ["before-pause"])

        vm.log(.info, "during-pause")
        // While paused, newly logged lines must not appear even after a
        // manual flush of the underlying ring buffer.
        vm.flushPendingLogs()
        XCTAssertEqual(vm.visibleLogs.map(\.message), ["before-pause"])

        vm.isLogDisplayPaused = false
        XCTAssertEqual(Set(vm.visibleLogs.map(\.message)), ["before-pause", "during-pause"])
    }

    func testMonitorEntriesRemainSynchronousAndCappedAt500() {
        let vm = DebugViewModel()
        for i in 0..<600 {
            vm.log(.info, "ev \(i)", source: .firmware)
        }
        // Firmware-sourced log lines mirror into monitorEntries synchronously
        // (no coalescing for the serial monitor).
        XCTAssertEqual(vm.monitorEntries.count, 500)
        XCTAssertTrue(vm.monitorEntries.last?.message.contains("ev 599") == true)
    }
}
