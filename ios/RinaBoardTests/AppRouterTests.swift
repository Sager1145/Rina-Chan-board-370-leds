import XCTest
@testable import RinaBoard

/// The launch preview gate (user requirement: "刚打开app同步时，完成同步再显示预览画面，不要让
/// 预览画面闪一下"): one-shot per launch, idempotent, and self-releasing on a
/// timeout so a board that never answers cannot hold every preview blank for
/// the rest of the run.
@MainActor
final class AppRouterTests: XCTestCase {
    func testArmSetsPending() {
        let router = AppRouter()
        XCTAssertFalse(router.launchPreviewPending)
        router.armLaunchPreviewGate(timeout: .seconds(8))
        XCTAssertTrue(router.launchPreviewPending)
    }

    func testReleaseClearsPending() {
        let router = AppRouter()
        router.armLaunchPreviewGate(timeout: .seconds(8))
        router.releaseLaunchPreviewGate()
        XCTAssertFalse(router.launchPreviewPending)
    }

    func testArmAgainAfterReleaseIsANoOp() {
        let router = AppRouter()
        router.armLaunchPreviewGate(timeout: .seconds(8))
        router.releaseLaunchPreviewGate()
        router.armLaunchPreviewGate(timeout: .seconds(8))
        XCTAssertFalse(router.launchPreviewPending,
                       "the gate is one-shot per launch — a later arm attempt must not reopen it")
    }

    func testTimeoutReleasesTheGate() async throws {
        let router = AppRouter()
        router.armLaunchPreviewGate(timeout: .milliseconds(50))
        XCTAssertTrue(router.launchPreviewPending)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(router.launchPreviewPending,
                       "a board that never answers must not hold every preview blank forever")
    }
}
