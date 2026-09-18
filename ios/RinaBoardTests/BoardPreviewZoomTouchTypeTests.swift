import UIKit
import XCTest
@testable import RinaBoard

/// The board's two-finger zoom must count fingers only: an Apple Pencil
/// drawing on the board plus one finger is not a pinch.
@MainActor
final class BoardPreviewZoomTouchTypeTests: XCTestCase {
    func testTwoFingerTransformAcceptsDirectTouchesOnly() {
        let recognizer = TwoFingerTransformRecognizer(target: nil, action: nil)
        XCTAssertEqual(recognizer.allowedTouchTypes,
                       [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        XCTAssertFalse(recognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)))
    }
}
