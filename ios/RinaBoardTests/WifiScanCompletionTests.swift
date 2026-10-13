import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class WifiScanCompletionTests: XCTestCase {
    func testLegacySynchronousNetworksReturnWithoutPolling() async throws {
        let (connection, transport) = await connectedFixture()
        defer { connection.disconnect() }
        transport.commandReply = completedScan
        let reply = try await connection.wifiScan(eventTimeout: .milliseconds(10))
        XCTAssertEqual(reply.networks?.map(\.ssid), ["ciallo"])
        XCTAssertEqual(scanCommands(transport), ["wifi_scan"])
    }

    func testMissingCompletionEventRecoversUsingScanResult() async throws {
        let (connection, transport) = await connectedFixture()
        defer { connection.disconnect() }
        transport.automaticallyReplies = false
        let scan = Task { try await connection.wifiScan(eventTimeout: .milliseconds(10)) }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true, "scanning": true])
        try await transport.waitForSent(type: .cmd, count: 2)
        var result = completedScan
        result["scanning"] = false
        transport.replyToNext(type: .cmd, json: result)
        let reply = try await scan.value
        XCTAssertEqual(reply.networks?.map(\.ssid), ["ciallo"])
        XCTAssertEqual(connection.lastWifiScan, reply)
        XCTAssertEqual(scanCommands(transport), ["wifi_scan", "wifi_scan_result"])
    }

    func testStillScanningReplyNeverReportsStaleNetworksAsCompletion() async throws {
        let (connection, transport) = await connectedFixture()
        defer { connection.disconnect() }
        var reply = completedScan
        reply["scanning"] = true
        transport.commandReply = reply
        do {
            _ = try await connection.wifiScan(eventTimeout: .milliseconds(10))
            XCTFail("an unfinished scan must not report success")
        } catch RinaTransportError.timeout {
        }
        XCTAssertEqual(scanCommands(transport), ["wifi_scan", "wifi_scan_result"])
    }

    func testCompletionEventKeepsFastPathWithoutPolling() async throws {
        let (connection, transport) = await connectedFixture()
        defer { connection.disconnect() }
        transport.automaticallyReplies = false
        let scan = Task { try await connection.wifiScan(eventTimeout: .seconds(1)) }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true, "scanning": true])
        transport.emitEvent(type: .evWifiScan, json: completedScan)
        let reply = try await scan.value
        XCTAssertEqual(reply.networks?.map(\.ssid), ["ciallo"])
        XCTAssertEqual(scanCommands(transport), ["wifi_scan"])
    }

    func testDisconnectDuringEventWaitCannotPollOrPublishSuccess() async throws {
        let (connection, transport) = await connectedFixture()
        transport.automaticallyReplies = false
        let scan = Task { try await connection.wifiScan(eventTimeout: .milliseconds(10)) }
        try await transport.waitForSent(type: .cmd, count: 1)
        transport.replyToNext(type: .cmd, json: ["ok": true, "scanning": true])
        connection.disconnect(userInitiated: true)
        do {
            _ = try await scan.value
            XCTFail("a disconnected scan must not complete")
        } catch {
            XCTAssertTrue(error is RinaTransportError || error is CancellationError)
        }
        XCTAssertEqual(scanCommands(transport), ["wifi_scan"])
    }

    private var completedScan: [String: Any] {
        ["ok": true, "networks": [["ssid": "ciallo", "rssi": -45, "secure": true]]]
    }

    private func connectedFixture() async -> (BoardConnection, FakeRinaTransport) {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.resetRecordedFrames()
        return (connection, transport)
    }

    private func scanCommands(_ transport: FakeRinaTransport) -> [String] {
        transport.sentFrames(type: .cmd).compactMap { frame in
            let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
            return json?["cmd"] as? String
        }
    }
}
