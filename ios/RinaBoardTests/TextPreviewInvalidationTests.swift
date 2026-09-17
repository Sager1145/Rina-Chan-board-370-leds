import SwiftUI
import UIKit
import XCTest
import RinaCore
@testable import RinaBoard

/// Proves the perf PR-9 split: while the Text tab's preview loop is running
/// (up to 120 Hz), `ScrollTextView`'s own body must not be re-evaluated on
/// every tick — only the small subviews that read `TextViewModel.playhead`
/// (`TextPreviewBoard`, `TextPreviewStatusFooter`, `TextPlaybackProgressBar`)
/// should.
///
/// Hosts the real view in a `UIHostingController` inside a `UIWindow`
/// attached to the test host app's real scene, with the same environment
/// objects `RootTabView` injects, and reads the `DEBUG`-only `PR9BodyProbe`
/// counters (compiled out of Release, so this file only exercises code paths
/// already gone from a release build).
@MainActor
final class TextPreviewInvalidationTests: XCTestCase {
    /// Frames tick at ~30 fps with nothing correcting phase (no board
    /// telemetry arrives from the fake transport), so `nextDelayMs` settles
    /// on ~33 ms/tick — about this many ticks over the wait window below.
    private static let expectedTicks = 25

    private var connection: BoardConnection?
    private var model: TextViewModel?
    private var window: UIWindow?
    /// The test host's own key window, taken over by `makeKeyAndVisible()`
    /// below; restored in `tearDown` so this test cannot leave another
    /// agent's simulator session (or a later test) without a key window.
    private var previousKeyWindow: UIWindow?

    override func tearDown() {
        model?.suspendPreviewLoop()
        model = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKeyAndVisible()
        previousKeyWindow = nil
        connection?.disconnect()
        connection = nil
        super.tearDown()
    }

    func testPreviewTicksDoNotReevaluateParentBody() async throws {
        // A backgrounded host (another agent's simulator work stealing focus)
        // suspends the preview loop via `scenePhase`, which would fail this
        // test for a reason unrelated to what it's checking.
        try XCTSkipUnless(UIApplication.shared.applicationState == .active,
                          "requires the host app to be foregrounded for real render passes")

        let (connection, model) = try await boundPlayingModel()
        self.connection = connection
        self.model = model

        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "hosted tests need a real scene to get render passes"
        )
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        self.window = window
        let hosting = UIHostingController(
            rootView: ScrollTextView()
                .environment(connection)
                .environment(model)
        )
        window.rootViewController = hosting
        window.isHidden = false
        window.makeKeyAndVisible()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        // Let the first layout/render pass land before sampling a baseline,
        // so it reflects steady state, not mount cost.
        _ = await waitForTicks(model: model, atLeast: 2, timeout: 3)

        let parentBaseline = PR9BodyProbe.count("ScrollTextView")
        let previewBaseline = PR9BodyProbe.count("TextPreviewBoard")
        let displayIndexBaseline = model.displayIndex

        let observedTicks = await waitForTicks(model: model, atLeast: Self.expectedTicks, timeout: 8)

        let parentDelta = PR9BodyProbe.count("ScrollTextView") - parentBaseline
        let previewDelta = PR9BodyProbe.count("TextPreviewBoard") - previewBaseline

        print("[TextPreviewInvalidation] observedTicks=\(observedTicks) parentDelta=\(parentDelta) previewDelta=\(previewDelta)")

        // The playhead must have genuinely advanced, not merely stayed put.
        // `frameCount` is guarded well above `expectedTicks` below, so this
        // can never be a same-index wrap back onto the baseline.
        XCTAssertNotEqual(model.displayIndex, displayIndexBaseline)
        let ticksThreshold = Int(Double(Self.expectedTicks) * 0.3)
        XCTAssertGreaterThanOrEqual(observedTicks, ticksThreshold,
                                    "expected at least 30% of ~\(Self.expectedTicks) ticks in the wait window")
        // Derived from what actually happened, not the static target, so a
        // regression that drops most (but not all) preview re-renders still
        // fails this instead of only being checked against a fixed floor.
        XCTAssertGreaterThanOrEqual(previewDelta, observedTicks - 2,
                                    "the preview subview must re-render for essentially every observed tick")
        // Window-proportional, not a fixed constant: under machine load the
        // window can stretch well past 1 s, during which a couple of
        // legitimate one-off invalidations (mount's `.task`, `onAppear`)
        // are expected and must not fail this test — but the bound must
        // still stay far below the tick count so a per-tick regression trips it.
        let parentBound = max(3, observedTicks / 8)
        XCTAssertLessThanOrEqual(parentDelta, parentBound,
                                 "the Text tab's parent body must not re-evaluate on every preview tick")
    }

    /// A `TextViewModel` bound to a running timeline via the real send path
    /// (as `TextTransportTests.testUploadCarriesIntervalMatchingRequestedFps`
    /// does), so `pll` is genuinely bound and `startPreviewLoop()` is the
    /// same one `sendDraft` starts — not a hand-assembled stand-in.
    private func boundPlayingModel() async throws -> (BoardConnection, TextViewModel) {
        PR9BodyProbe.reset()
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)

        let model = TextViewModel()
        model.text = "Rina PR-9 preview invalidation check"
        model.requestedFps = 30

        await model.send(connection: connection)

        XCTAssertNotNil(model.boundTimelineId, "send must bind a timeline for the preview loop to tick")
        // Well above `expectedTicks` so the loop cannot wrap the ring back
        // onto the baseline index within the wait window — a shorter
        // fixture later could otherwise make `testPreviewTicksDoNotReevaluateParentBody`'s
        // "actually advanced" check pass by accident.
        XCTAssertGreaterThan(model.frameCount, Self.expectedTicks * 2)
        return (connection, model)
    }

    /// Polls (20 ms steps) until `model.displayIndex` has changed at least
    /// `target` times, or `timeout` elapses; returns however many changes
    /// were actually observed. Counts *changes*, not raw index deltas, so a
    /// wrap around a short ring still counts every tick.
    private func waitForTicks(model: TextViewModel, atLeast target: Int, timeout: TimeInterval) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var last = model.displayIndex
        var changes = 0
        while Date() < deadline, changes < target {
            try? await Task.sleep(for: .milliseconds(20))
            let current = model.displayIndex
            if current != last {
                changes += 1
                last = current
            }
        }
        return changes
    }
}
