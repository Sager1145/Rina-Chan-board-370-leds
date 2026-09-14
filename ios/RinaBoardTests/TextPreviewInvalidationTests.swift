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
/// Hosts the real view in a `UIHostingController` inside a `UIWindow`, the
/// same environment objects `RootTabView` injects, and reads the `DEBUG`-only
/// `PR9BodyProbe` counters (compiled out of Release, so this file only
/// exercises code paths already gone from a release build).
@MainActor
final class TextPreviewInvalidationTests: XCTestCase {
    func testPreviewTicksDoNotReevaluateParentBody() async throws {
        let (connection, model) = try await boundPlayingModel()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
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

        // Let a first layout/render pass land before the loop starts ticking
        // in earnest, so the baseline reflects steady state, not mount cost.
        try await Task.sleep(for: .milliseconds(150))
        model.startPreviewLoop()
        try await Task.sleep(for: .milliseconds(150))

        let parentBaseline = PR9BodyProbe.count("ScrollTextView")
        let previewBaseline = PR9BodyProbe.count("TextPreviewBoard")

        try await Task.sleep(for: .seconds(1))

        let parentDelta = PR9BodyProbe.count("ScrollTextView") - parentBaseline
        let previewDelta = PR9BodyProbe.count("TextPreviewBoard") - previewBaseline

        print("[TextPreviewInvalidation] parentDelta=\(parentDelta) previewDelta=\(previewDelta)")

        model.suspendPreviewLoop()
        window.isHidden = true
        window.rootViewController = nil

        XCTAssertLessThanOrEqual(parentDelta, 2,
                                 "the Text tab's parent body must not re-evaluate on every preview tick")
        XCTAssertGreaterThan(previewDelta, 10,
                             "the preview subview should have re-rendered many times over one second of playback")
    }

    /// A `TextViewModel` bound to a running timeline, with the same transport
    /// fake `BoardConnectionOutputTests` uses.
    private func boundPlayingModel() async throws -> (BoardConnection, TextViewModel) {
        PR9BodyProbe.reset()
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)

        let url = try XCTUnwrap(Bundle.main.url(forResource: "ark12", withExtension: "json"),
                                "Hosted tests need the app's bundled font")
        let font = try ArkPixelFont.loadBundled(url: url)
        let timeline = try ScrollRasterizer.makeTimeline(text: "Rina PR-9 preview", font: font, fps: 30)
        XCTAssertGreaterThan(timeline.frameCount, 10)

        let model = TextViewModel()
        model.timeline = timeline
        model.boundTimelineId = timeline.timelineId
        model.boardPaused = false
        return (connection, model)
    }
}
