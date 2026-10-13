import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class ManualHostConnectionTests: XCTestCase {
    func testManualHostPreservesTransportFailureDiagnostic() async {
        let suite = "ManualHostConnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardStore(defaults: defaults)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        model.manualHost = "board.local"
        let connection = BoardConnection(reconnectDelay: { _ in 60 })
        defer { connection.disconnect() }
        let transport = FakeRinaTransport(kind: .wifi(host: "board.local", port: 80))
        transport.failNextSend = true

        await model.connectManualHost(connection: connection, boardStore: store,
                                      transportFactory: { _ in transport })

        XCTAssertEqual(model.lastErrorMessage, "short write")
        XCTAssertTrue(store.boards.isEmpty)
        XCTAssertFalse(model.isConnectingHome)
    }

    func testIntentionalDisconnectDuringManualHostConnectStaysQuiet() async throws {
        let suite = "ManualHostConnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardStore(defaults: defaults)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        model.manualHost = "board.local"
        let connection = BoardConnection()
        let transport = FakeRinaTransport(connectImmediately: false)
        let attempt = Task { @MainActor in
            await model.connectManualHost(connection: connection, boardStore: store,
                                          transportFactory: { _ in transport })
        }
        try await transport.waitForConnectStarted()
        connection.disconnect(userInitiated: true)
        transport.completeDeferredConnect()
        await attempt.value

        XCTAssertNil(model.lastErrorMessage)
        XCTAssertTrue(store.boards.isEmpty)
        XCTAssertFalse(model.isConnectingHome)
    }

    func testSupersededManualHostConnectDoesNotSaveOldHost() async throws {
        let suite = "ManualHostConnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardStore(defaults: defaults)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        model.manualHost = "old-board.local"
        let connection = BoardConnection()
        defer { connection.disconnect() }
        let oldTransport = FakeRinaTransport(connectImmediately: false)
        let attempt = Task { @MainActor in
            await model.connectManualHost(connection: connection, boardStore: store,
                                          transportFactory: { _ in oldTransport })
        }
        try await oldTransport.waitForConnectStarted()
        let newTransport = FakeRinaTransport(kind: .wifi(host: "new-board.local", port: 80))
        let connected = await connection.connect(using: newTransport)
        XCTAssertTrue(connected)
        oldTransport.completeDeferredConnect()
        await attempt.value

        XCTAssertNil(model.lastErrorMessage)
        XCTAssertTrue(store.boards.isEmpty)
        XCTAssertEqual(connection.transportKind, newTransport.kind)
        XCTAssertFalse(model.isConnectingHome)
    }
}
