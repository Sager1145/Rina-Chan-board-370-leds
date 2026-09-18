import XCTest
import RinaCore
@testable import RinaBoard

/// Covers the association predicate behind both Wi-Fi provisioning paths
/// (`provisionPhoneHotspot` and `connectNetwork`).
///
/// `wifiManagerSetHotspotCredentials` / `wifiManagerSetCredentials` only start an
/// async scan (`startStaSelection` in `esp32s3_firmware/src/wifi_manager.cpp`)
/// while the previous association stays up, so the first `EV_WIFI` after the
/// provisioning commands normally still describes the OLD network under the same
/// `activeProfile`. Matching profile alone therefore reports success — and
/// persists credentials — for a network the board never joined.
@MainActor
final class ConnectionProvisioningTests: XCTestCase {
    private func makeViewModel() -> ConnectionViewModel {
        ConnectionViewModel(startBonjourBrowsing: false)
    }

    private func stream(_ events: [BoardEvent]) -> AsyncStream<BoardEvent> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    private func associated(_ ssid: String?, profile: String = "hotspot", ip: String? = nil) -> BoardEvent {
        .wifi(WifiStatus(staConnected: true, ssid: ssid, ip: ip, activeProfile: profile))
    }

    func testStaleAssociationForPreviousSSIDIsNotAccepted() async {
        let viewModel = makeViewModel()
        let matched = await viewModel.waitForAssociation(
            in: stream([associated("OldPhone", ip: "10.0.0.5")]),
            profile: "hotspot",
            expectedSSID: "NewPhone")
        XCTAssertNil(matched, "a same-profile event for the previous SSID must not count as joining")
    }

    func testRequestedSSIDIsAcceptedAfterAStaleEvent() async {
        let viewModel = makeViewModel()
        let matched = await viewModel.waitForAssociation(
            in: stream([
                associated("OldPhone", ip: "10.0.0.5"),
                associated("NewPhone", ip: "172.20.10.2"),
            ]),
            profile: "hotspot",
            expectedSSID: "NewPhone")
        XCTAssertEqual(matched?.ssid, "NewPhone")
        XCTAssertEqual(matched?.ip, "172.20.10.2", "the IP must come from the matching association")
    }

    /// Older firmware that reports no `ssid` keeps the profile-only behavior.
    func testFirmwareWithoutReportedSSIDStillMatches() async {
        let viewModel = makeViewModel()
        let matched = await viewModel.waitForAssociation(
            in: stream([associated(nil, ip: "172.20.10.2")]),
            profile: "hotspot",
            expectedSSID: "NewPhone")
        XCTAssertEqual(matched?.ip, "172.20.10.2")

        let emptySSID = await viewModel.waitForAssociation(
            in: stream([associated("", ip: "172.20.10.2")]),
            profile: "hotspot",
            expectedSSID: "NewPhone")
        XCTAssertEqual(emptySSID?.ip, "172.20.10.2")
    }

    func testOtherProfileNeverMatches() async {
        let viewModel = makeViewModel()
        let matched = await viewModel.waitForAssociation(
            in: stream([associated("HomeNet", profile: "home")]),
            profile: "hotspot",
            expectedSSID: "HomeNet")
        XCTAssertNil(matched)
    }

    func testDisconnectedStatusNeverMatches() async {
        let viewModel = makeViewModel()
        let matched = await viewModel.waitForAssociation(
            in: stream([.wifi(WifiStatus(staConnected: false, ssid: "NewPhone", activeProfile: "hotspot"))]),
            profile: "hotspot",
            expectedSSID: "NewPhone")
        XCTAssertNil(matched)
    }

    /// The home path shares the same waiter, so it gets the same guarantee.
    func testHomeProfileRejectsPreviousNetwork() async {
        let viewModel = makeViewModel()
        let matched = await viewModel.waitForAssociation(
            in: stream([
                associated("OldHome", profile: "home"),
                associated("NewHome", profile: "home", ip: "192.168.1.40"),
            ]),
            profile: "home",
            expectedSSID: "NewHome")
        XCTAssertEqual(matched?.ssid, "NewHome")
    }
}
