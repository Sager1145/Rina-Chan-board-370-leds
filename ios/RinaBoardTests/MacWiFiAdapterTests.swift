#if targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import RinaBoard

@MainActor
final class MacWiFiAdapterTests: XCTestCase {
    func testEmbeddedNativeBridgeLoadsWithoutReadingWiFi() throws {
        // Exercise the actual Catalyst -> signed native bundle boundary.
        // Loading only constructs the bridge; it calls no Wi-Fi API and
        // does not request Location Services authorization.
        _ = try MacWiFiAdapter.load()
    }

    func testExactJoinReturnsConfirmedBoardSSID() async throws {
        let bridge = FakeMacWiFiBridge()
        bridge.joinedSSID = "RinaChanBoard-001122334455"
        let adapter = MacWiFiAdapter(bridge: bridge)
        let joined = try await adapter.join(ssid: bridge.joinedSSID, prefix: "RinaChanBoard-", password: "fixture")
        XCTAssertEqual(joined, bridge.joinedSSID)
    }

    func testPrefixJoinRejectsUnrelatedNetwork() async {
        let bridge = FakeMacWiFiBridge()
        bridge.joinedSSID = "Home Wi-Fi"
        let adapter = MacWiFiAdapter(bridge: bridge)
        do {
            _ = try await adapter.join(ssid: nil, prefix: "RinaChanBoard-", password: "fixture")
            XCTFail("an unrelated SSID must never identify a board")
        } catch {
            XCTAssertEqual(error as? MacWiFiAdapter.JoinError, .unexpectedNetwork)
        }
    }

    func testExactJoinRejectsDifferentBoard() async {
        let bridge = FakeMacWiFiBridge()
        bridge.joinedSSID = "RinaChanBoard-AABBCCDDEEFF"
        let adapter = MacWiFiAdapter(bridge: bridge)
        do {
            _ = try await adapter.join(ssid: "RinaChanBoard-001122334455", prefix: "RinaChanBoard-", password: "fixture")
            XCTFail("another board must not satisfy an exact join")
        } catch {
            XCTAssertEqual(error as? MacWiFiAdapter.JoinError, .unexpectedNetwork)
        }
    }

    func testBridgeFailurePreservesErrorDomainAndCode() async {
        let bridge = FakeMacWiFiBridge()
        bridge.error = NSError(domain: "CoreWLANFixture", code: 17)
        let adapter = MacWiFiAdapter(bridge: bridge)
        do {
            _ = try await adapter.join(ssid: nil, prefix: "RinaChanBoard-", password: "fixture")
            XCTFail("association failure must be reported")
        } catch {
            XCTAssertEqual((error as NSError).domain, "CoreWLANFixture")
            XCTAssertEqual((error as NSError).code, 17)
        }
    }

    func testMissingSSIDDoesNotReportSuccess() async {
        let adapter = MacWiFiAdapter(bridge: FakeMacWiFiBridge())
        do {
            _ = try await adapter.join(ssid: nil, prefix: "RinaChanBoard-", password: "fixture")
            XCTFail("a successful join requires a concrete board SSID")
        } catch {
            XCTAssertEqual(error as? MacWiFiAdapter.JoinError, .ssidUnavailable)
        }
    }

    func testDirectedMissReturnsBroadcastCatalogContainingSelectedBoard() throws {
        let selectedSSID = "RinaChanBoard-B"
        let catalog: Set<String> = ["RinaChanBoard-A", selectedSSID, "Home Wi-Fi"]
        var probes: [Data?] = []

        let networks = try MacWiFiScanPolicy.networks(forSSID: selectedSSID) { probe -> Set<String> in
            probes.append(probe)
            return probe == nil ? catalog : []
        }

        XCTAssertEqual(networks, catalog)
        XCTAssertTrue(networks.contains(selectedSSID))
        XCTAssertEqual(probes, [Data(selectedSSID.utf8), nil])
    }

    func testExactScanUsesUTF8AndStopsAfterSuccess() throws {
        var probes: [Data?] = []
        let networks = try MacWiFiScanPolicy.networks(forSSID: "璃奈板") { probe -> [String] in
            probes.append(probe)
            return ["璃奈板"]
        }

        XCTAssertEqual(networks, ["璃奈板"])
        XCTAssertEqual(probes, [Data([0xE7, 0x92, 0x83, 0xE5, 0xA5, 0x88, 0xE6, 0x9D, 0xBF])])
    }

    func testPrefixScanPerformsOneBroadcastScanEvenWhenEmpty() throws {
        var probes: [Data?] = []
        let networks = try MacWiFiScanPolicy.networks(forSSID: nil) { probe -> Set<String> in
            probes.append(probe)
            return []
        }

        XCTAssertTrue(networks.isEmpty)
        XCTAssertEqual(probes, [nil])
    }

    func testDirectedScanErrorPropagatesWithoutBroadcastFallback() {
        var probes: [Data?] = []
        let failure = NSError(domain: "CoreWLANFixture", code: 17)

        XCTAssertThrowsError(try MacWiFiScanPolicy.networks(forSSID: "RinaChanBoard-B") { probe -> [String] in
            probes.append(probe)
            throw failure
        }) { error in
            XCTAssertEqual((error as NSError).domain, "CoreWLANFixture")
            XCTAssertEqual((error as NSError).code, 17)
        }
        XCTAssertEqual(probes, [Data("RinaChanBoard-B".utf8)])
    }

    func testEmptyBroadcastFallbackReturnsAbsenceWithoutAnotherScan() throws {
        var probes: [Data?] = []
        let networks = try MacWiFiScanPolicy.networks(forSSID: "RinaChanBoard-B") { probe -> [String] in
            probes.append(probe)
            return []
        }

        XCTAssertTrue(networks.isEmpty)
        XCTAssertEqual(probes, [Data("RinaChanBoard-B".utf8), nil])
    }
}

private final class FakeMacWiFiBridge: NSObject, MacWiFiBridgeProtocol {
    var joinedSSID: String?
    var error: NSError?

    required override init() { super.init() }

    func currentSSID() -> String? { joinedSSID }

    func join(ssid: String?, prefix: String, password: String,
              completion: @escaping @Sendable (String?, NSError?) -> Void) {
        completion(joinedSSID, error)
    }
}
#endif
