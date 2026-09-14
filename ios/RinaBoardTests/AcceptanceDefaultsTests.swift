import XCTest
@testable import RinaBoard

@MainActor
final class AcceptanceDefaultsTests: XCTestCase {
    func testRealtimeOutputIsOnForANewEditor() {
        XCTAssertTrue(ControlViewModel().livePreview,
                      "A new editor streams edits to a connected board by default")
    }
}
