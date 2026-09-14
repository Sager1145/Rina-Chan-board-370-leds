import XCTest
@testable import RinaCore

/// `BoardIdentity` (RINALINK_PROTOCOL_V1 "Board identity"): reconciles a
/// saved board's expected hotspot SSID against what the board itself reports
/// over the just-established link. Every board's SoftAP shares one IP, so a
/// TCP link that answers is not by itself proof it's the *expected* board.
final class BoardIdentityTests: XCTestCase {
    func testBoardIDFromValidSSID() {
        XCTAssertEqual(BoardIdentity.boardID(fromAPSSID: "RinaChanBoard-80B54EF48E09"), "80B54EF48E09")
        XCTAssertEqual(BoardIdentity.boardID(fromAPSSID: "RinaChanBoard-80b54ef48e09"), "80B54EF48E09")
    }

    func testBoardIDRejectsLegacyAndMalformedSSIDs() {
        XCTAssertNil(BoardIdentity.boardID(fromAPSSID: "RinaChanBoard-V2"))
        XCTAssertNil(BoardIdentity.boardID(fromAPSSID: "RinaChanBoard-XYZ"))
        XCTAssertNil(BoardIdentity.boardID(fromAPSSID: "SomeOtherNetwork"))
    }

    func testMatchesReturnsNilForLegacySharedSSID() {
        let reported = WifiStatus(apSsid: "RinaChanBoard-V2")
        XCTAssertNil(BoardIdentity.matches(expectedHotspotSSID: "RinaChanBoard-V2", reported: reported))
    }

    func testMatchesReturnsNilWhenNoExpectedSSID() {
        let reported = WifiStatus(apSsid: "RinaChanBoard-80B54EF48E09")
        XCTAssertNil(BoardIdentity.matches(expectedHotspotSSID: nil, reported: reported))
    }

    func testMatchesReturnsNilWhenNoReportedStatus() {
        XCTAssertNil(BoardIdentity.matches(expectedHotspotSSID: "RinaChanBoard-80B54EF48E09", reported: nil))
    }

    func testMatchesTrueWhenApSsidMatches() {
        let reported = WifiStatus(apSsid: "RinaChanBoard-80B54EF48E09")
        XCTAssertEqual(BoardIdentity.matches(expectedHotspotSSID: "RinaChanBoard-80B54EF48E09", reported: reported), true)
    }

    func testMatchesFalseWhenApSsidDiffers() {
        let reported = WifiStatus(apSsid: "RinaChanBoard-000000000000")
        XCTAssertEqual(BoardIdentity.matches(expectedHotspotSSID: "RinaChanBoard-80B54EF48E09", reported: reported), false)
    }

    func testMatchesFallsBackToBoardIdWhenApSsidMissing() {
        let matchingID = WifiStatus(boardId: "80b54ef48e09")
        XCTAssertEqual(BoardIdentity.matches(expectedHotspotSSID: "RinaChanBoard-80B54EF48E09", reported: matchingID), true)

        let mismatchedID = WifiStatus(boardId: "000000000000")
        XCTAssertEqual(BoardIdentity.matches(expectedHotspotSSID: "RinaChanBoard-80B54EF48E09", reported: mismatchedID), false)
    }

    func testMatchesNilWhenNeitherApSsidNorBoardIdReported() {
        let reported = WifiStatus(ip: "192.168.1.14")
        XCTAssertNil(BoardIdentity.matches(expectedHotspotSSID: "RinaChanBoard-80B54EF48E09", reported: reported))
    }

    /// The user renamed the board's AP SSID via `wifi_set_ap` after it was
    /// saved: `apSsid` no longer matches the expected SSID string, but the
    /// board's stable `boardId` still does, and takes precedence.
    func testMatchesTrueForRenamedApWhenBoardIdMatches() {
        let reported = WifiStatus(apSsid: "RinaChanBoard-Home", boardId: "80B54EF48E09")
        XCTAssertEqual(BoardIdentity.matches(expectedHotspotSSID: "RinaChanBoard-80B54EF48E09", reported: reported), true)
    }

    func testMatchesFalseForRenamedApWhenBoardIdDiffers() {
        let reported = WifiStatus(apSsid: "RinaChanBoard-Home", boardId: "80B54EF74801")
        XCTAssertEqual(BoardIdentity.matches(expectedHotspotSSID: "RinaChanBoard-80B54EF48E09", reported: reported), false)
    }

    /// The phone joined the legacy shared SoftAP but landed on a board that
    /// reports a unique identity — provably a different board, not "unknown".
    func testMatchesFalseWhenLegacyExpectedButReportedUnique() {
        let reported = WifiStatus(apSsid: "RinaChanBoard-80B54EF48E09")
        XCTAssertEqual(BoardIdentity.matches(expectedHotspotSSID: RinaLinkConstants.apSSID, reported: reported), false)

        let reportedByID = WifiStatus(boardId: "80B54EF48E09")
        XCTAssertEqual(BoardIdentity.matches(expectedHotspotSSID: RinaLinkConstants.apSSID, reported: reportedByID), false)
    }

    func testMatchesNilWhenLegacyExpectedAndReportedLegacyWithNoBoardId() {
        let reported = WifiStatus(apSsid: RinaLinkConstants.apSSID)
        XCTAssertNil(BoardIdentity.matches(expectedHotspotSSID: RinaLinkConstants.apSSID, reported: reported))
    }

    /// Fullwidth digits pass `Character.isHexDigit` but are not ASCII hex —
    /// `boardID(fromAPSSID:)` must reject them.
    func testBoardIDNilForFullwidthHexSSID() {
        XCTAssertNil(BoardIdentity.boardID(fromAPSSID: "RinaChanBoard-\u{FF10}\u{FF10}\u{FF10}\u{FF10}\u{FF10}\u{FF10}\u{FF10}\u{FF10}\u{FF10}\u{FF10}\u{FF10}\u{FF10}"))
    }
}
