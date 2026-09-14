import XCTest
@testable import RinaBoard

@MainActor
final class BLETransportSignalTests: XCTestCase {
    func testNormalizesConnectedRSSIAndRejectsUnavailableSentinel() {
        XCTAssertEqual(BLETransport.normalizedRSSI(NSNumber(value: -67)), -67)
        XCTAssertEqual(BLETransport.normalizedRSSI(NSNumber(value: 0)), 0)
        XCTAssertNil(BLETransport.normalizedRSSI(NSNumber(value: 127)))
    }
}
