import Foundation
import Network
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class SavedConnectionRecoveryTests: XCTestCase {
    func testLegacySavedBoardWithoutBonjourIdentityStillLoadsByHost() throws {
        let suiteName = "SavedConnectionRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = [[
            "id": "192.168.1.42",
            "name": "璃奈板",
            "preferredTransport": "wifi",
            "lastHost": "192.168.1.42"
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy),
                     forKey: "com.rinachan.board.knownBoards")

        let store = BoardStore(defaults: defaults)

        let board = try XCTUnwrap(store.boards.first)
        XCTAssertNil(board.bonjourService)
        XCTAssertEqual(board.connectionTarget, .host("192.168.1.42", isBoardHotspot: false))
    }

    func testBonjourIdentityWinsOverPreviouslyResolvedDHCPHost() {
        let identity = BonjourServiceIdentity(name: "Rina-1234", domain: "local.")
        let board = KnownBoard(id: identity.storageID, name: "璃奈板", preferredTransport: "wifi",
                               lastHost: "192.168.1.42", bonjourService: identity)

        XCTAssertEqual(board.connectionTarget, .bonjour(identity))
    }

    func testLegacyBonjourBoardWithoutHostReconstructsDefaultServiceIdentity() {
        let board = KnownBoard(id: "Rina-1234", name: "Rina-1234", preferredTransport: "wifi")

        XCTAssertEqual(board.connectionTarget,
                       .bonjour(BonjourServiceIdentity(name: "Rina-1234")))
    }

    func testBonjourBoardWithNoHostPersistsServiceIdentityAndMigratesLegacyRecord() throws {
        let suiteName = "SavedConnectionRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BoardStore(defaults: defaults)
        store.upsert(KnownBoard(id: "Rina-1234", name: "旧名称", preferredTransport: "wifi"))
        let identity = BonjourServiceIdentity(name: "Rina-1234", domain: "local.")

        store.upsert(KnownBoard(id: identity.storageID, name: "新名称", preferredTransport: "wifi",
                                lastHost: nil, bonjourService: identity))

        XCTAssertEqual(store.boards.count, 1)
        XCTAssertEqual(store.boards[0].id, identity.storageID)
        XCTAssertEqual(store.boards[0].name, "新名称")
        XCTAssertNil(store.boards[0].lastHost)
        XCTAssertEqual(store.boards[0].bonjourService, identity)
        let reloaded = BoardStore(defaults: defaults)
        XCTAssertEqual(reloaded.boards, store.boards)
    }

    func testSavedBonjourIdentityRecreatesServiceEndpoint() {
        let browser = BonjourBrowser()
        let identity = BonjourServiceIdentity(name: "Rina-1234", type: "_rinalink._tcp",
                                               domain: "local.")

        let endpoint = browser.endpoint(for: identity)

        guard case let .service(name, type, domain, interface) = endpoint else {
            return XCTFail("Expected a Bonjour service endpoint")
        }
        XCTAssertEqual(name, identity.name)
        XCTAssertEqual(type, identity.type)
        XCTAssertEqual(domain, identity.domain)
        XCTAssertNil(interface)
    }

    func testSavedBoardHotspotJoinsBeforeOpeningTCP() async {
        let store = makeStore()
        defer { clear(store.defaultsSuiteName) }
        let board = KnownBoard(id: RinaLinkConstants.apIP, name: "璃奈板",
                               preferredTransport: "hotspot", lastHost: RinaLinkConstants.apIP)
        store.value.upsert(board)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let connection = BoardConnection()
        let ble = BLETransport()
        var events: [String] = []

        await model.connectSavedBoard(
            board,
            ble: ble,
            connection: connection,
            boardStore: store.value,
            joinBoardHotspot: { events.append("join") },
            connectTransport: { transport in
                events.append("connect")
                XCTAssertEqual(transport.kind, .hotspot)
                return false
            }
        )

        XCTAssertEqual(events, ["join", "connect"])
        XCTAssertNil(model.lastErrorMessage)
    }

    func testForgettingHotspotWhileJoinIsInflightPreventsTCPAndResave() async throws {
        let store = makeStore()
        defer { clear(store.defaultsSuiteName) }
        let board = KnownBoard(id: RinaLinkConstants.apIP, name: "璃奈板",
                               preferredTransport: "hotspot", lastHost: RinaLinkConstants.apIP)
        store.value.upsert(board)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let connection = BoardConnection()
        let ble = BLETransport()
        var joinContinuation: CheckedContinuation<Void, Never>?
        var didTryTCP = false

        let reconnect = Task { @MainActor in
            await model.connectSavedBoard(
                board,
                ble: ble,
                connection: connection,
                boardStore: store.value,
                joinBoardHotspot: {
                    await withCheckedContinuation { joinContinuation = $0 }
                    throw SavedConnectionTestError.associationFailed
                },
                connectTransport: { _ in
                    didTryTCP = true
                    return true
                }
            )
        }
        for _ in 0..<1_000 where joinContinuation == nil { await Task.yield() }
        XCTAssertNotNil(joinContinuation)

        model.forgetBoard(board, ble: ble, connection: connection, boardStore: store.value)
        joinContinuation?.resume()
        await reconnect.value

        XCTAssertFalse(didTryTCP)
        XCTAssertTrue(store.value.boards.isEmpty)
        XCTAssertNil(model.connectingSavedBoardID)
        XCTAssertNil(model.lastErrorMessage)
    }

    func testSavedBoardWithoutAddressPublishesVisibleError() async {
        let store = makeStore()
        defer { clear(store.defaultsSuiteName) }
        let board = KnownBoard(id: "unsupported", name: "璃奈板", preferredTransport: "satellite")
        store.value.upsert(board)
        let model = ConnectionViewModel(startBonjourBrowsing: false)

        await model.connectSavedBoard(board, ble: BLETransport(), connection: BoardConnection(),
                                      boardStore: store.value)

        XCTAssertNotNil(model.lastErrorMessage)
    }

    func testSupersededSavedReconnectWithoutTransportErrorStaysQuiet() async {
        let store = makeStore()
        defer { clear(store.defaultsSuiteName) }
        let board = KnownBoard(id: "192.168.1.42", name: "璃奈板", preferredTransport: "wifi",
                               lastHost: "192.168.1.42")
        store.value.upsert(board)
        let model = ConnectionViewModel(startBonjourBrowsing: false)

        await model.connectSavedBoard(
            board,
            ble: BLETransport(),
            connection: BoardConnection(),
            boardStore: store.value,
            joinBoardHotspot: {},
            connectTransport: { _ in false }
        )

        XCTAssertNil(model.lastErrorMessage)
    }

    func testForgettingSavedBLEWhileConnectIsInflightDoesNotRestoreItOrShowError() async {
        let store = makeStore()
        defer { clear(store.defaultsSuiteName) }
        let identifier = UUID()
        let board = KnownBoard(id: identifier.uuidString, name: "璃奈板",
                               preferredTransport: "bluetooth")
        store.value.upsert(board)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let connection = BoardConnection()
        let ble = BLETransport()
        var connectContinuation: CheckedContinuation<Bool, Never>?

        let reconnect = Task { @MainActor in
            await model.connectBLE(
                DiscoveredPeripheral(id: identifier, advertisedName: "璃奈板", rssi: -50),
                ble: ble,
                connection: connection,
                boardStore: store.value,
                connectTransport: { _ in
                    await withCheckedContinuation { connectContinuation = $0 }
                }
            )
        }
        for _ in 0..<1_000 where connectContinuation == nil { await Task.yield() }
        XCTAssertNotNil(connectContinuation)

        model.forgetBoard(board, ble: ble, connection: connection, boardStore: store.value)
        connectContinuation?.resume(returning: false)
        await reconnect.value

        XCTAssertTrue(store.value.boards.isEmpty)
        XCTAssertNil(model.lastErrorMessage)
        XCTAssertFalse(model.isConnectingBLE)
    }

    private func makeStore() -> (value: BoardStore, defaultsSuiteName: String) {
        let suiteName = "SavedConnectionRecoveryTests.\(UUID().uuidString)"
        return (BoardStore(defaults: UserDefaults(suiteName: suiteName)!), suiteName)
    }

    private func clear(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}

private enum SavedConnectionTestError: Error {
    case associationFailed
}
