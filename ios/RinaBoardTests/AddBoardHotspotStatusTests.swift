import XCTest
@testable import RinaBoard

@MainActor
final class AddBoardHotspotStatusTests: XCTestCase {
    func testConnectedHotspotStatusFollowsTheLiveTransport() async {
        let hotspot = BoardConnection()
        let connected = await hotspot.connect(using: FakeRinaTransport(kind: .hotspot))
        XCTAssertTrue(connected)

        XCTAssertEqual(AddBoardView.directAPStatusText(stage: .connected, connections: [hotspot]),
                       String(localized: "已连接到板子（板载热点）"))
        XCTAssertEqual(AddBoardView.directAPStatusText(stage: .idle, connections: [hotspot]),
                       String(localized: "已连接到板子（板载热点）"))
        XCTAssertEqual(AddBoardView.directAPStatusText(stage: .failed("重新连接失败"), connections: [hotspot]),
                       "重新连接失败")

        hotspot.disconnect()
        XCTAssertEqual(AddBoardView.directAPStatusText(stage: .connected, connections: [hotspot]),
                       String(localized: "热点连接已断开，请重新连接"))
    }

    func testAnotherOnlineBoardDoesNotKeepHotspotStatusConnected() async {
        let hotspot = BoardConnection()
        let bluetooth = BoardConnection()
        let hotspotConnected = await hotspot.connect(using: FakeRinaTransport(kind: .hotspot))
        let bluetoothConnected = await bluetooth.connect(using: FakeRinaTransport(kind: .bluetooth))
        XCTAssertTrue(hotspotConnected)
        XCTAssertTrue(bluetoothConnected)

        hotspot.disconnect()
        XCTAssertEqual(AddBoardView.directAPStatusText(stage: .connected, connections: [hotspot, bluetooth]),
                       String(localized: "热点连接已断开，请重新连接"))
        XCTAssertNil(AddBoardView.directAPStatusText(stage: .idle, connections: [bluetooth]))
        bluetooth.disconnect()
    }

    func testFailedJoinReasonSurvivesAnotherBoardBeingOnline() async {
        let bluetooth = BoardConnection()
        let connected = await bluetooth.connect(using: FakeRinaTransport(kind: .bluetooth))
        XCTAssertTrue(connected)

        XCTAssertEqual(AddBoardView.directAPStatusText(stage: .failed("无法建立控制连接"), connections: [bluetooth]),
                       "无法建立控制连接")
        bluetooth.disconnect()
    }
}
