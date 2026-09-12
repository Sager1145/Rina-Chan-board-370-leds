import XCTest
@testable import RinaBoard

@MainActor
final class AcceptanceDefaultsTests: XCTestCase {
    func testRealtimeOutputIsOffForANewEditor() {
        XCTAssertFalse(ControlViewModel().livePreview,
                       "A new editor must stay local until the user explicitly enables realtime output")
    }
}
