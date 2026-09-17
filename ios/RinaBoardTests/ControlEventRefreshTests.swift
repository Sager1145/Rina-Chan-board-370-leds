import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

/// Event-driven Control refresh loop (perf PR-12b): replaces the fixed
/// 200 ms poll with a status-version trigger, a 1 Hz reconciliation
/// fallback, and coalesced fetches. `ControlDisplayRefreshTransport` lets a
/// test push unsolicited EV_STATUS frames the way firmware would on a
/// runtime-state-version bump, and counts GET_FRAME requests.
@MainActor
final class ControlEventRefreshTests: XCTestCase {
    func testVersionBumpTriggersExactlyOneGetFrameAndAdoptsFrame() async throws {
        let (model, connection, transport) = try await connectedFixture()
        model.refreshTiming.reconciliationInterval = .seconds(1000) // isolate the event path

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        await waitUntil { transport.getFrameCount >= 1 }
        XCTAssertEqual(transport.getFrameCount, 1, "Entry must fetch exactly once")

        var bumped = PackedFrame()
        bumped.set(42)
        transport.displayFrame = bumped
        transport.pushStatus(version: 2)

        await waitUntil { transport.getFrameCount >= 2 }
        XCTAssertEqual(transport.getFrameCount, 2, "A version bump must fetch exactly once")
        await waitUntil { model.draftFrame == bumped }
        XCTAssertEqual(model.draftFrame, bumped)

        task.cancel()
        await task.value
    }

    func testUnchangedVersionEventsProduceNoExtraFetch() async throws {
        let (model, connection, transport) = try await connectedFixture()
        model.refreshTiming.reconciliationInterval = .seconds(1000)

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        await waitUntil { transport.getFrameCount >= 1 }
        XCTAssertEqual(transport.getFrameCount, 1)

        // Same version as already applied at setup: must not be treated as a
        // trigger. The reconciliation interval is long enough that a 200 ms
        // poll (5 extra fetches over this window) would fail this assertion.
        transport.pushStatus(version: 1)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(transport.getFrameCount, 1, "An unchanged version must not cause another fetch")

        task.cancel()
        await task.value
    }

    func testIdleReconciliationRunsAtTheConfiguredRateNotFaster() async throws {
        let (model, connection, transport) = try await connectedFixture()
        model.refreshTiming.reconciliationInterval = .milliseconds(100)

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        // 600 ms idle with no events: the entry fetch plus up to ~6 ticks at
        // 100 ms. Bounds are generous for a loaded Mac; this only guards
        // against the reconciliation loop drifting far off its configured
        // interval (e.g. a busy-spin) — it is not tight enough to by itself
        // catch a regression to a fixed-rate legacy poll (a 200 ms poll over
        // this same 600 ms window yields ~4 fetches, which still fits these
        // bounds). That regression is covered separately by
        // `testUnchangedVersionEventsProduceNoExtraFetch` and
        // `testNilVersionAtEntryThenAppearingSwitchesToEventDrivenFetchRate`.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThanOrEqual(transport.getFrameCount, 2)
        XCTAssertLessThanOrEqual(transport.getFrameCount, 9,
                                 "Reconciliation must follow its own interval, not a tight poll")

        task.cancel()
        await task.value
    }

    func testBurstOfVersionBumpsCoalescesToAtMostTwoFetches() async throws {
        let (model, connection, transport) = try await connectedFixture()
        model.refreshTiming.reconciliationInterval = .seconds(1000)
        // Generous in-flight window (vs. the near-instant in-memory event
        // processing) so a loaded Mac cannot make the burst arrive late and
        // spill into a third fetch.
        transport.getFrameDelay = .milliseconds(150)

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        await waitUntil { transport.getFrameStarted >= 1 }

        for version in 2...6 {
            transport.pushStatus(version: version)
        }

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertLessThanOrEqual(transport.getFrameCount, 2,
                                 "A burst of version bumps must coalesce into at most one extra fetch")
        XCTAssertGreaterThanOrEqual(transport.getFrameCount, 2,
                                    "The coalesced trailing bump must still be served once")

        task.cancel()
        await task.value
    }

    func testHasUnsentChangesBlocksEveryFetch() async throws {
        let (model, connection, transport) = try await connectedFixture()
        model.refreshTiming.reconciliationInterval = .milliseconds(20)
        // Live Preview would otherwise send this edit and clear
        // `hasUnsentChanges` within one send round-trip (AcceptanceControlTests
        // disables it for the same reason).
        model.livePreview = false
        model.toggle(led: 5, connection: connection)
        XCTAssertTrue(model.hasUnsentChanges)

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        transport.pushStatus(version: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transport.getFrameCount, 0, "An unsent draft must never be overwritten by a fetch")

        task.cancel()
        await task.value
    }

    func testNonControlModeBlocksEveryFetch() async throws {
        let model = ControlViewModel()
        let connection = BoardConnection()
        let transport = ControlEventRefreshTransport()
        transport.initialVersion = 1
        transport.initialControlMode = false // mode never synchronized
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.resetCounters() // connect() itself issues a setup GET_FRAME
        model.refreshTiming.reconciliationInterval = .milliseconds(20)
        // Deliberately do not call model.boardModeSynchronized.

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        transport.pushStatus(version: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transport.getFrameCount, 0, "Without a synchronized Control mode, nothing must be fetched")

        task.cancel()
        await task.value
        connection.disconnect()
    }

    func testNilStatusVersionFallsBackToLegacyPolling() async throws {
        let model = ControlViewModel()
        let connection = BoardConnection()
        let transport = ControlEventRefreshTransport()
        transport.initialVersion = nil
        transport.initialControlMode = true
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.resetCounters() // connect() itself issues a setup GET_FRAME
        model.boardModeSynchronized(generation: connection.connectionGeneration)
        model.refreshTiming.legacyPollInterval = .milliseconds(15)

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThanOrEqual(transport.getFrameCount, 3,
                                    "Older firmware with no status version must keep polling")

        task.cancel()
        await task.value
        connection.disconnect()
    }

    func testLoopStopsFetchingOnceCancelled() async throws {
        let (model, connection, transport) = try await connectedFixture()
        model.refreshTiming.reconciliationInterval = .milliseconds(15)

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        await waitUntil { transport.getFrameCount >= 1 }
        task.cancel()
        await task.value

        let countAtCancellation = transport.getFrameCount
        try await Task.sleep(for: .milliseconds(80))
        transport.pushStatus(version: 99)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(transport.getFrameCount, countAtCancellation,
                       "A cancelled loop must never fetch again")
        connection.disconnect()
    }

    func testBoardModeSynchronizedWakesARunningLoopImmediately() async throws {
        let (model, connection, transport) = try await connectedFixture()
        model.refreshTiming.reconciliationInterval = .seconds(1000) // isolate the wake path

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        await waitUntil { transport.getFrameCount >= 1 }
        XCTAssertEqual(transport.getFrameCount, 1)

        // A mode flip with no accompanying version bump (mirrors
        // BoardSyncCoordinator resolving Control mode) must still wake the
        // loop right away instead of waiting on the 1 Hz fallback.
        model.boardModeSynchronized(generation: connection.connectionGeneration)
        await waitUntil { transport.getFrameCount >= 2 }
        XCTAssertEqual(transport.getFrameCount, 2)

        task.cancel()
        await task.value
    }

    func testVersionGoingBackwardsStillTriggersARefresh() async throws {
        let (model, connection, transport) = try await connectedFixture(version: 5)
        model.refreshTiming.reconciliationInterval = .seconds(1000)

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        await waitUntil { transport.getFrameCount >= 1 }
        XCTAssertEqual(transport.getFrameCount, 1)

        transport.pushStatus(version: 3) // lower than the current 5
        await waitUntil { transport.getFrameCount >= 2 }
        XCTAssertEqual(transport.getFrameCount, 2, "Any version change, not just an increase, must refresh")

        task.cancel()
        await task.value
    }

    func testNilVersionAtEntryThenAppearingSwitchesToEventDrivenFetchRate() async throws {
        let model = ControlViewModel()
        let connection = BoardConnection()
        let transport = ControlEventRefreshTransport()
        transport.initialVersion = nil
        transport.initialControlMode = true
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.resetCounters() // connect() itself issues a setup GET_FRAME
        model.boardModeSynchronized(generation: connection.connectionGeneration)
        model.refreshTiming.legacyPollInterval = .milliseconds(10)
        model.refreshTiming.reconciliationInterval = .seconds(1000) // isolate the fallback rate

        let task = Task { await model.runDisplayRefreshLoop(connection: connection) }
        await waitUntil { transport.getFrameCount >= 3 }
        XCTAssertGreaterThanOrEqual(transport.getFrameCount, 3, "Must poll while the version is nil")

        // The version arrives (as if the coordinator's GET_STATUS/EV_STATUS
        // filled it in): the loop must settle into the event-driven fallback
        // rate instead of continuing to poll every 10 ms.
        transport.pushStatus(version: 1)
        await waitUntil { connection.status?.v == 1 }
        let countAfterVersionAppears = transport.getFrameCount
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(transport.getFrameCount, countAfterVersionAppears + 2,
                                 "Once a version exists, the 10 ms legacy poll must stop")

        task.cancel()
        await task.value
        connection.disconnect()
    }

    func testTriggerSurvivesALoopRestart() async throws {
        let (model, connection, transport) = try await connectedFixture()
        model.refreshTiming.reconciliationInterval = .seconds(1000)

        // Force the losing order deterministically: keep the entry fetch in
        // flight so run 1 is cancelled *during* a fetch, and its `defer`
        // only unwinds after run 2 has already installed its own trigger.
        transport.getFrameDelay = .milliseconds(80)
        let firstRun = Task { await model.runDisplayRefreshLoop(connection: connection) }
        await waitUntil { transport.getFrameStarted >= 1 }

        // Simulate `.task(id:)` restarting: cancel the old run and start a
        // new one without waiting for the old one to finish unwinding, so
        // the two runs' `defer` blocks can race.
        firstRun.cancel()
        let secondRun = Task { await model.runDisplayRefreshLoop(connection: connection) }
        await firstRun.value
        transport.getFrameDelay = nil
        await waitUntil { transport.getFrameCount >= 2 }
        XCTAssertGreaterThanOrEqual(transport.getFrameCount, 2, "The restarted run must fetch on entry")

        let countBeforeWake = transport.getFrameCount
        model.boardModeSynchronized(generation: connection.connectionGeneration)
        await waitUntil { transport.getFrameCount > countBeforeWake }
        XCTAssertGreaterThan(transport.getFrameCount, countBeforeWake,
                             "The old run's cleanup must not have cleared the new run's trigger")

        secondRun.cancel()
        await secondRun.value
    }

    func testConcurrentCallersNeverOverlapAGetFrame() async throws {
        let (model, connection, transport) = try await connectedFixture()
        transport.getFrameDelay = .milliseconds(60)

        async let first: Void = model.refreshBoardDisplay(connection: connection)
        async let second: Void = model.refreshBoardDisplay(connection: connection)
        _ = await (first, second)

        XCTAssertLessThanOrEqual(transport.maxConcurrentGetFrames, 1,
                                 "refreshBoardDisplay must be single-flight across every caller")
        XCTAssertEqual(transport.getFrameCount, 2,
                       "The second concurrent caller must still be served exactly once, not dropped")
    }

    func testTriggerDuringTheFinalRerunIsStillServed() async throws {
        let (model, connection, transport) = try await connectedFixture()
        transport.getFrameDelay = .milliseconds(60)

        // Fetch #1: the owner.
        async let ownerCall: Void = model.refreshBoardDisplay(connection: connection)
        await waitUntil { transport.getFrameStarted >= 1 }

        // A caller arrives while fetch #1 is in flight: it becomes the
        // pending rerun (fetch #2).
        async let firstWaiterCall: Void = model.refreshBoardDisplay(connection: connection)
        await waitUntil { transport.getFrameStarted >= 2 }

        // A further caller arrives while fetch #2 — the rerun — is itself in
        // flight. It must still be served as one more rerun (fetch #3), not
        // dropped just because it is not the original fetch.
        async let secondWaiterCall: Void = model.refreshBoardDisplay(connection: connection)
        _ = await (ownerCall, firstWaiterCall, secondWaiterCall)

        XCTAssertEqual(transport.getFrameCount, 3,
                       "A trigger that arrives during the rerun must still produce one more fetch")
    }

    func testCancelledOwnerDoesNotAdoptFrameAfterCancellation() async throws {
        let (model, connection, transport) = try await connectedFixture()
        // A large in-flight delay against a 100 ms bound gives far more
        // discrimination than a 150 ms delay would on a heavily loaded Mac.
        transport.getFrameDelay = .milliseconds(600)
        var differing = PackedFrame()
        differing.set(7)
        transport.displayFrame = differing
        let before = model.draftFrame
        XCTAssertNotEqual(before, differing)

        let ownerTask = Task { await model.refreshBoardDisplay(connection: connection) }
        await waitUntil { transport.getFrameStarted >= 1 }
        ownerTask.cancel()

        // A structured, inline fetch must be cancelled promptly along with
        // its caller, not block for the whole in-flight delay — the exact
        // regression an unstructured `Task {}` around the fetch reintroduces.
        let cancelledAt = ContinuousClock.now
        await ownerTask.value
        XCTAssertLessThan(cancelledAt.duration(to: .now), .milliseconds(100),
                          "Cancelling the caller must cancel the in-flight fetch, not wait for it")

        // Give the (now-ignored) reply time to land; it must never adopt.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(model.draftFrame, before,
                       "A cancelled fetch must never adopt a frame that lands after teardown")
    }

    func testCancelledWaiterReturnsPromptlyWithoutCancellingTheFetch() async throws {
        let (model, connection, transport) = try await connectedFixture()
        transport.getFrameDelay = .milliseconds(600)
        var bumped = PackedFrame()
        bumped.set(11)
        transport.displayFrame = bumped

        let ownerTask = Task { await model.refreshBoardDisplay(connection: connection) }
        await waitUntil { transport.getFrameStarted >= 1 }

        let waiterTask = Task { await model.refreshBoardDisplay(connection: connection) }
        try await Task.sleep(for: .milliseconds(20)) // let the waiter actually park
        let cancelledAt = ContinuousClock.now
        waiterTask.cancel()
        await waiterTask.value
        XCTAssertLessThan(cancelledAt.duration(to: .now), .milliseconds(100),
                          "A cancelled waiter must return immediately, not wait for the fetch")

        // The owner's own fetch must be unaffected by the waiter's cancellation.
        await ownerTask.value
        XCTAssertEqual(model.draftFrame, bumped,
                       "Cancelling a waiter must never cancel the fetch it was waiting on")
    }

    func testCancelledOwnerHandsOffToAParkedWaiterInsteadOfDroppingItsRequest() async throws {
        let (model, connection, transport) = try await connectedFixture()
        transport.getFrameDelay = .milliseconds(300)
        var bumped = PackedFrame()
        bumped.set(23)

        // Owner fetch #1 starts; it will be cancelled mid-flight.
        let ownerTask = Task { await model.refreshBoardDisplay(connection: connection) }
        await waitUntil { transport.getFrameStarted >= 1 }

        // A waiter parks behind it, requesting a refresh of its own.
        let waiterTask = Task { await model.refreshBoardDisplay(connection: connection) }
        try await Task.sleep(for: .milliseconds(20)) // let it actually park

        // The frame the waiter is trying to observe only lands once the
        // owner is cancelled — mirroring a board switch tearing down the
        // old owner's `.task(id:)` right as the new tab's request parks.
        transport.displayFrame = bumped
        ownerTask.cancel()
        await ownerTask.value

        // The waiter's own task is still live: it must inherit ownership and
        // actually run a fetch, not just be released having served nothing
        // (which would leave the preview stale until the 1 Hz fallback).
        await waiterTask.value
        await waitUntil { model.draftFrame == bumped }
        XCTAssertEqual(model.draftFrame, bumped,
                       "A parked waiter's request must be served, not dropped, when the owner is cancelled")
        XCTAssertGreaterThanOrEqual(transport.getFrameStarted, 2,
                                    "The handed-off request must actually run its own fetch")
    }

    // MARK: Fixture

    private func connectedFixture(
        version: Int? = 1, controlMode: Bool = true
    ) async throws -> (ControlViewModel, BoardConnection, ControlEventRefreshTransport) {
        let model = ControlViewModel()
        let connection = BoardConnection()
        let transport = ControlEventRefreshTransport()
        transport.initialVersion = version
        transport.initialControlMode = controlMode
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        // `connect()` itself issues a setup-time GET_STATUS/GET_FRAME/
        // GET_PREVIEW_SYNC read (BoardConnection.refreshBoardSnapshot); reset
        // so every test's counts describe only what's under test.
        transport.resetCounters()
        model.boardModeSynchronized(generation: connection.connectionGeneration)
        return (model, connection, transport)
    }

    private func waitUntil(timeoutMs: Int = 1000, _ condition: @MainActor () -> Bool) async {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        while !condition(), DispatchTime.now() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Minimal transport that answers GET_STATUS/GET_FRAME, tracks how many
/// GET_FRAME requests were served, and can push unsolicited EV_STATUS events
/// (§established facts: firmware broadcasts EV_STATUS with a bumped
/// `v` to every connected client whenever the board's Control-mode display
/// changes).
@MainActor
private final class ControlEventRefreshTransport: @MainActor RinaTransport {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 512

    var displayFrame = PackedFrame()
    var initialVersion: Int? = 1
    var initialControlMode = true
    /// Artificial delay before a GET_FRAME reply is sent, so a test can
    /// observe a fetch "in flight" while pushing a burst of events.
    var getFrameDelay: Duration?
    private(set) var getFrameCount = 0
    /// Incremented the moment a GET_FRAME request is received, before any
    /// artificial delay — lets a test know the first fetch has started
    /// without waiting for it to finish.
    private(set) var getFrameStarted = 0
    /// Highest number of GET_FRAME requests this transport was ever handling
    /// at once. Stays 1 as long as callers are properly single-flighted.
    private(set) var maxConcurrentGetFrames = 0
    private var currentConcurrentGetFrames = 0

    /// Zeroes every counter. `BoardConnection.connect()` runs its own setup
    /// GET_STATUS/GET_FRAME/GET_PREVIEW_SYNC read before returning, so a test
    /// that wants exact counts must call this right after `connect()`
    /// succeeds, before starting whatever is under test.
    func resetCounters() {
        getFrameCount = 0
        getFrameStarted = 0
        maxConcurrentGetFrames = 0
        currentConcurrentGetFrames = 0
    }

    private let decoder = RinaLinkDecoder()
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    func stateStream() -> AsyncStream<TransportState> {
        AsyncStream { stateContinuation = $0 }
    }

    func incomingStream() -> AsyncStream<Data> {
        AsyncStream { incomingContinuation = $0 }
    }

    func connect() async throws {
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
    }

    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            switch request.type {
            case RinaLinkMessageType.getFrame.rawValue:
                getFrameStarted += 1
                currentConcurrentGetFrames += 1
                maxConcurrentGetFrames = max(maxConcurrentGetFrames, currentConcurrentGetFrames)
                if let delay = getFrameDelay { try? await Task.sleep(for: delay) }
                currentConcurrentGetFrames -= 1
                getFrameCount += 1
                reply(to: request, payload: Data(displayFrame.bytes))
            case RinaLinkMessageType.getStatus.rawValue:
                reply(to: request, payload: statusJSON(version: initialVersion, controlMode: initialControlMode))
            default:
                reply(to: request, payload: Data(#"{"ok":true}"#.utf8))
            }
        }
    }

    /// Pushes an unsolicited EV_STATUS frame the way firmware broadcasts one
    /// on a runtime-state-version bump.
    func pushStatus(version: Int?, controlMode: Bool = true) {
        incomingContinuation?.yield(
            (try? RinaLinkEncoder.encode(
                RinaLinkFrame(type: RinaLinkMessageType.evStatus.rawValue, seq: 0, flags: 0,
                              payload: statusJSON(version: version, controlMode: controlMode))
            )) ?? Data()
        )
    }

    private func reply(to request: RinaLinkFrame, payload: Data) {
        guard let encoded = try? RinaLinkEncoder.encode(
            RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: 0, payload: payload)
        ) else { return }
        incomingContinuation?.yield(encoded)
    }

    private func statusJSON(version: Int?, controlMode: Bool) -> Data {
        var object: [String: Any] = ["ok": true]
        if let version { object["v"] = version }
        if controlMode { object["renderer"] = ["outputMode": "control"] }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
