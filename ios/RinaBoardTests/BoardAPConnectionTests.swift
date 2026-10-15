import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class BoardAPConnectionTests: XCTestCase {
    private let identityA = "80B54EF48E09"
    private let identityB = "80B54EF74801"
    private var ssidA: String { "RinaChanBoard-\(identityA)" }
    private var ssidB: String { "RinaChanBoard-\(identityB)" }

    func testSavedAPAddressSurvivesColdLoadWithoutReplacingHomeWifiHost() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString
        store.upsert(KnownBoard(id: id, name: "A", preferredTransport: "hotspot",
            lastHost: "192.168.1.22", hotspotSSID: ssidA, hotspotIP: "10.20.30.40", physicalBoardID: identityA))
        var cold = try XCTUnwrap(BoardStore(defaults: defaults).boards.first)
        XCTAssertEqual(cold.id, id)
        XCTAssertEqual(cold.connectionTarget, .boardHotspot(host: "10.20.30.40", ssid: ssidA))
        cold.preferredTransport = "wifi"
        XCTAssertEqual(cold.connectionTarget, .host("192.168.1.22"))
    }

    func testPrefixJoinDialsJoinedSiblingSavedIPInsteadOfPreviouslySelectedBoard() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = makeSessions()
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let idA = UUID().uuidString, idB = UUID().uuidString
        let selectedA = sessions.session(for: idA, name: "A")
        let oldA = wire(identity: identityA, ssid: ssidA, ip: "10.1.2.3")
        _ = await selectedA.connection.connect(using: oldA)
        boards.upsert(KnownBoard(id: idA, name: "A", hotspotSSID: ssidA, hotspotIP: "10.1.2.3", physicalBoardID: identityA))
        boards.upsert(KnownBoard(id: idB, name: "B", hotspotSSID: ssidB, hotspotIP: "10.4.5.6", physicalBoardID: identityB))
        sessions.select(selectedA)
        let newB = wire(identity: identityB, ssid: ssidB, ip: "10.4.5.6", kind: .hotspot)
        await ConnectionViewModel(startBonjourBrowsing: false).connectHotspot(
            sessions: sessions, boardStore: boards, joinBoardHotspot: { self.ssidB },
            connectTransport: { target, transport in
                XCTAssertEqual((transport as? TCPTransport)?.host, "10.4.5.6")
                XCTAssertEqual(target.boardID, idB)
                return await target.connection.connect(using: newB, expectedBoardIdentity: self.identityB)
            })
        XCTAssertEqual(selectedA.connection.boardIdentity, identityA)
        XCTAssertEqual(selectedA.connection.connectionState, .connected)
        XCTAssertEqual(sessions.active.connection.boardIdentity, identityB)
        XCTAssertEqual(boards.boards.count, 2)
    }

    func testUnknownFactorySSIDUsesDerivedGatewayAndChecksWrongPhysicalBoard() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = makeSessions()
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let wrong = wire(identity: identityB, ssid: ssidB, ip: "10.247.72.1", kind: .hotspot)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        await model.connectHotspot(sessions: sessions, boardStore: boards,
            joinBoardHotspot: { self.ssidA }, connectTransport: { target, transport in
                XCTAssertEqual((transport as? TCPTransport)?.host, "10.244.142.9")
                return await target.connection.connect(using: wrong, expectedBoardIdentity: self.identityA)
            })
        XCTAssertTrue(boards.boards.isEmpty)
        if case .failed = model.directAPStage {} else { XCTFail("wrong board must fail") }
        XCTAssertNil(sessions.active.connection.boardIdentity)
    }

    func testLiveBLEReportedGatewayWinsOverStaleSavedAPAddressAndKeepsBLESession() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = makeSessions()
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let id = UUID().uuidString
        let original = sessions.session(for: id, name: "A")
        original.bleTransport.peripheralIdentifier = UUID(uuidString: id)
        let ble = wire(identity: identityA, ssid: ssidA, ip: "10.20.30.40")
        _ = await original.connection.connect(using: ble)
        _ = try await original.connection.refreshWifiStatus()
        boards.upsert(KnownBoard(id: id, name: "A", hotspotSSID: ssidA, hotspotIP: "10.244.142.9", physicalBoardID: identityA))
        let tcp = wire(identity: identityA, ssid: ssidA, ip: "10.20.30.40", kind: .hotspot)
        await ConnectionViewModel(startBonjourBrowsing: false).connectHotspot(sessions: sessions, boardStore: boards,
            joinBoardHotspot: { self.ssidA }, connectTransport: { target, transport in
                XCTAssertTrue(target === original)
                XCTAssertEqual((transport as? TCPTransport)?.host, "10.20.30.40")
                return await target.connection.connect(using: tcp, expectedBoardIdentity: self.identityA)
            })
        XCTAssertEqual(sessions.sessions.count, 1)
        XCTAssertTrue(sessions.existingSession(for: id) === original)
        XCTAssertTrue(sessions.existingSession(for: KnownBoard.hotspotStorageID(ssid: ssidA)) === original)
        XCTAssertEqual(boards.boards.first?.id, id)
        XCTAssertEqual(boards.boards.first?.hotspotIP, "10.20.30.40")
    }

    func testIPOnlySavePersistsBLEAddressHomeHostAndSiblingThenColdReconnectUsesEditedGateway() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = makeSessions()
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let id = UUID().uuidString
        let board = sessions.session(for: id, name: "A")
        let transport = wire(identity: identityA, ssid: ssidA, ip: "10.244.142.9")
        _ = await board.connection.connect(using: transport)
        _ = try await board.connection.refreshWifiStatus()
        boards.upsert(KnownBoard(id: id, name: "A", preferredTransport: "bluetooth", lastHost: "192.168.1.22",
            hotspotSSID: ssidA, hotspotIP: "10.244.142.9", physicalBoardID: identityA))
        let sibling = KnownBoard(id: UUID().uuidString, name: "B", hotspotSSID: ssidB,
            hotspotIP: "10.247.72.1", physicalBoardID: identityB)
        boards.upsert(sibling)
        transport.commandReply["apIp"] = "10.20.30.40"
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let saved = await model.setAp(ssid: "", password: "", ip: "10.20.30.40", connection: board.connection, boardStore: boards)
        XCTAssertTrue(saved)
        let commands = try transport.sentFrames(type: .cmd).map {
            try JSONSerialization.jsonObject(with: $0.payload) as? [String: Any]
        }
        let update = try XCTUnwrap(commands.first { $0?["cmd"] as? String == "wifi_set_ap" })
        XCTAssertEqual(update?["ssid"] as? String, "")
        XCTAssertEqual(update?["password"] as? String, "")
        XCTAssertEqual(update?["ip"] as? String, "10.20.30.40")
        let cold = BoardStore(defaults: defaults)
        XCTAssertTrue(cold.boards.contains(sibling))
        var record = try XCTUnwrap(cold.boards.first { $0.id == id })
        XCTAssertEqual(record.preferredTransport, "bluetooth")
        XCTAssertEqual(record.lastHost, "192.168.1.22")
        XCTAssertEqual(record.hotspotSSID, ssidA)
        record.preferredTransport = "hotspot"
        cold.upsert(record)
        let freshSessions = makeSessions()
        defer { freshSessions.sessions.forEach { $0.connection.disconnect() } }
        let newWire = wire(identity: identityA, ssid: ssidA, ip: "10.20.30.40", kind: .hotspot)
        await model.connectSavedBoard(record, sessions: freshSessions, boardStore: cold,
            joinBoardHotspot: { expected in XCTAssertEqual(expected, self.ssidA); return self.ssidA },
            connectTransport: { target, transport in
                XCTAssertEqual((transport as? TCPTransport)?.host, "10.20.30.40")
                return await target.connection.connect(using: newWire, expectedBoardIdentity: self.identityA)
            })
        XCTAssertEqual(freshSessions.sessions.count, 1)
        XCTAssertTrue(freshSessions.existingSession(for: id) === freshSessions.active)
        XCTAssertEqual(cold.boards.first { $0.id == id }?.lastHost, "192.168.1.22")
    }

    func testInvalidConflictFirmwareRejectionAndUnverifiedUpdateDoNotReportSuccess() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = BoardConnection()
        let transport = wire(identity: identityA, ssid: ssidA, ip: "10.244.142.9")
        _ = await connection.connect(using: transport)
        _ = try await connection.refreshWifiStatus()
        defer { connection.disconnect() }
        let original = KnownBoard(id: UUID().uuidString, name: "A", hotspotSSID: ssidA,
            hotspotIP: "10.244.142.9", physicalBoardID: identityA)
        boards.upsert(original)
        let sibling = KnownBoard(id: UUID().uuidString, name: "B", hotspotSSID: ssidB,
            hotspotIP: "10.247.72.1", physicalBoardID: identityB)
        boards.upsert(sibling)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let count = transport.sentFrames(type: .cmd).count
        for invalid in ["8.8.8.8", "10.0.0.0", "10.247.72.1"] {
            let result = await model.setAp(ssid: "", password: "", ip: invalid, connection: connection, boardStore: boards)
            XCTAssertFalse(result)
            XCTAssertNotNil(model.lastErrorMessage)
        }
        XCTAssertEqual(transport.sentFrames(type: .cmd).count, count)
        transport.commandReply = ["ok": false, "error": "Use Bluetooth to change IP"]
        let rejected = await model.setAp(ssid: "", password: "", ip: "10.20.30.40", connection: connection, boardStore: boards)
        XCTAssertFalse(rejected)
        XCTAssertTrue(model.lastErrorMessage?.contains("Use Bluetooth to change IP") == true)
        transport.commandReply = ["ok": true, "apIp": "10.244.142.9", "boardId": identityA]
        let ignored = await model.setAp(ssid: "", password: "", ip: "10.20.30.40", connection: connection, boardStore: boards)
        XCTAssertFalse(ignored)
        XCTAssertEqual(boards.boards, [original, sibling])
    }

    func testBLEConnectRefreshesReportedConfiguredAPAddressEvenWhenAPIsOff() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let connection = BoardConnection()
        defer { connection.disconnect() }
        let ble = APTestBLE()
        let transport = wire(identity: identityA, ssid: ssidA, ip: "10.20.30.40")
        transport.commandReply["apActive"] = false
        await ConnectionViewModel(startBonjourBrowsing: false).connectBLE(
            DiscoveredPeripheral(id: id, advertisedName: "A", rssi: -50),
            ble: ble, connection: connection, boardStore: boards,
            connectTransport: { _ in await connection.connect(using: transport) })
        let cold = try XCTUnwrap(BoardStore(defaults: defaults).boards.first)
        XCTAssertEqual(cold.id, id.uuidString)
        XCTAssertEqual(cold.preferredTransport, "bluetooth")
        XCTAssertEqual(cold.hotspotIP, "10.20.30.40")
        XCTAssertEqual(cold.hotspotSSID, ssidA)
        XCTAssertNil(cold.lastHost)
    }

    func testSavedAPSwitchStopsPreviousDifferentAPGatewayButKeepsBLESibling() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = makeSessions()
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let old = sessions.session(for: UUID().uuidString, name: "A")
        let oldWire = wire(identity: identityA, ssid: ssidA, ip: "10.244.142.9", kind: .hotspot)
        _ = await old.connection.connect(using: oldWire)
        let sibling = sessions.session(for: UUID().uuidString, name: "C")
        let bleWire = wire(identity: "AAAAAAAAAAAA", ssid: "RinaChanBoard-AAAAAAAAAAAA", ip: "10.170.170.170")
        _ = await sibling.connection.connect(using: bleWire)
        let boardB = KnownBoard(id: UUID().uuidString, name: "B", preferredTransport: "hotspot",
            hotspotSSID: ssidB, hotspotIP: "10.247.72.1", physicalBoardID: identityB)
        boards.upsert(boardB)
        let tcp = wire(identity: identityB, ssid: ssidB, ip: "10.247.72.1", kind: .hotspot)
        await ConnectionViewModel(startBonjourBrowsing: false).connectSavedBoard(boardB,
            sessions: sessions, boardStore: boards, joinBoardHotspot: { _ in
                XCTAssertEqual(old.connection.connectionState, .disconnected)
                XCTAssertEqual(sibling.connection.connectionState, .connected)
                return self.ssidB
            }, connectTransport: { target, transport in
                XCTAssertEqual((transport as? TCPTransport)?.host, "10.247.72.1")
                return await target.connection.connect(using: tcp, expectedBoardIdentity: self.identityB)
            })
        XCTAssertEqual(old.connection.connectionState, .disconnected)
        XCTAssertEqual(bleWire.disconnectCount, 0)
        XCTAssertEqual(sibling.connection.connectionState, .connected)
        XCTAssertEqual(sessions.active.connection.boardIdentity, identityB)
    }

    func testColdLegacyFactoryGatewayFallsBackOnceAfterFirmwareUpgradeAndPersistsNewGateway() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString
        let old = KnownBoard(id: id, name: "A", preferredTransport: "hotspot",
            lastHost: "192.168.1.14", hotspotSSID: ssidA, physicalBoardID: identityA)
        boards.upsert(old)
        let cold = BoardStore(defaults: defaults)
        let saved = try XCTUnwrap(cold.boards.first)
        let sessions = makeSessions()
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let unavailable = wire(identity: identityA, ssid: ssidA, ip: "192.168.1.14", kind: .hotspot)
        unavailable.connectFailure = "Legacy gateway is unreachable"
        let upgraded = wire(identity: identityA, ssid: ssidA, ip: "10.244.142.9", kind: .hotspot)
        var attempted: [String] = []
        await ConnectionViewModel(startBonjourBrowsing: false).connectSavedBoard(saved,
            sessions: sessions, boardStore: cold, joinBoardHotspot: { _ in self.ssidA },
            connectTransport: { target, transport in
                let host = try! XCTUnwrap((transport as? TCPTransport)?.host)
                attempted.append(host)
                return await target.connection.connect(using: host == "192.168.1.14" ? unavailable : upgraded,
                    expectedBoardIdentity: self.identityA)
            })
        XCTAssertEqual(attempted, ["192.168.1.14", "10.244.142.9"])
        XCTAssertEqual(sessions.active.connection.boardIdentity, identityA)
        let restored = try XCTUnwrap(BoardStore(defaults: defaults).boards.first)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.hotspotIP, "10.244.142.9")
        XCTAssertNil(restored.lastHost)
        XCTAssertEqual(restored.connectionTarget, .boardHotspot(host: "10.244.142.9", ssid: ssidA))
    }

    func testColdAPUpgradeFallbackPreservesExplicitOverrideAndSuccessfulOldFirmware() async throws {
        for useOverride in [false, true] {
            let (boards, defaults, suite) = try makeStore()
            defer { defaults.removePersistentDomain(forName: suite) }
            let saved = KnownBoard(id: UUID().uuidString, name: "A", preferredTransport: "hotspot",
                lastHost: "192.168.1.14", hotspotSSID: ssidA,
                hotspotIP: useOverride ? "10.20.30.40" : nil, physicalBoardID: identityA)
            boards.upsert(saved)
            let sessions = makeSessions()
            defer { sessions.sessions.forEach { $0.connection.disconnect() } }
            let transport = wire(identity: identityA, ssid: ssidA,
                ip: useOverride ? "10.20.30.40" : "192.168.1.14", kind: .hotspot)
            if useOverride { transport.connectFailure = "Edited gateway is unreachable" }
            var attempted: [String] = []
            await ConnectionViewModel(startBonjourBrowsing: false).connectSavedBoard(saved,
                sessions: sessions, boardStore: boards, joinBoardHotspot: { _ in self.ssidA },
                connectTransport: { target, proposed in
                    attempted.append((proposed as! TCPTransport).host)
                    return await target.connection.connect(using: transport, expectedBoardIdentity: self.identityA)
                })
            XCTAssertEqual(attempted, [useOverride ? "10.20.30.40" : "192.168.1.14"])
            if useOverride { XCTAssertEqual(boards.boards, [saved]) }
            else { XCTAssertEqual(sessions.active.connection.boardIdentity, identityA) }
        }
    }

    func testSelectingBoardHotspotJoinsExactSSIDKeepsPhysicalSessionAndStopsOnlyPreviousAP() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = makeSessions()
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let oldA = sessions.session(for: UUID().uuidString, name: "A")
        let oldAP = wire(identity: identityA, ssid: ssidA, ip: "10.244.142.9", kind: .hotspot)
        _ = await oldA.connection.connect(using: oldAP)
        let bleID = UUID().uuidString
        let targetB = sessions.session(for: bleID, name: "B")
        targetB.bleTransport.peripheralIdentifier = UUID(uuidString: bleID)
        let originalBLE = wire(identity: identityB, ssid: ssidB, ip: "10.20.30.40")
        _ = await targetB.connection.connect(using: originalBLE)
        let bleSibling = sessions.session(for: UUID().uuidString, name: "C")
        let siblingBLE = wire(identity: "AAAAAAAAAAAA", ssid: "RinaChanBoard-AAAAAAAAAAAA", ip: "10.170.170.170")
        _ = await bleSibling.connection.connect(using: siblingBLE)
        let lanSibling = sessions.session(for: "192.168.1.44", name: "D")
        let siblingLAN = wire(identity: "BBBBBBBBBBBB", ssid: "RinaChanBoard-BBBBBBBBBBBB", ip: "10.187.187.187",
            kind: .wifi(host: "192.168.1.44", port: RinaLinkConstants.tcpPort))
        _ = await lanSibling.connection.connect(using: siblingLAN)
        boards.upsert(KnownBoard(id: bleID, name: "B", preferredTransport: "bluetooth", lastHost: "192.168.1.22",
            hotspotSSID: ssidB, hotspotIP: "10.20.30.40", physicalBoardID: identityB))
        sessions.select(targetB)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        XCTAssertTrue(model.canSelectTransport(.hotspot, session: targetB, boardStore: boards))
        let newAP = wire(identity: identityB, ssid: ssidB, ip: "10.20.30.40", kind: .hotspot)
        var joined: [String] = []
        await model.selectTransport(.hotspot, sessions: sessions, boardStore: boards,
            joinBoardHotspot: { expectedSSID in
                joined.append(expectedSSID)
                XCTAssertEqual(expectedSSID, self.ssidB)
                XCTAssertEqual(oldA.connection.connectionState, .connected)
                return expectedSSID
            }, connectTransport: { target, proposed, expectedIdentity in
                XCTAssertTrue(target === targetB)
                XCTAssertEqual((proposed as? TCPTransport)?.host, "10.20.30.40")
                XCTAssertEqual(expectedIdentity, self.identityB)
                XCTAssertEqual(oldA.connection.connectionState, .disconnected)
                return await target.connection.connect(using: newAP, expectedBoardIdentity: expectedIdentity)
            })
        XCTAssertEqual(joined, [ssidB])
        XCTAssertTrue(sessions.active === targetB)
        XCTAssertTrue(sessions.existingSession(for: bleID) === targetB)
        XCTAssertTrue(sessions.existingSession(for: KnownBoard.hotspotStorageID(ssid: ssidB)) === targetB)
        XCTAssertEqual(targetB.connection.transportKind, .hotspot)
        XCTAssertEqual(targetB.connection.boardIdentity, identityB)
        XCTAssertEqual(oldAP.disconnectCount, 1)
        XCTAssertEqual(siblingBLE.disconnectCount, 0)
        XCTAssertEqual(siblingLAN.disconnectCount, 0)
        XCTAssertEqual(bleSibling.connection.connectionState, .connected)
        XCTAssertEqual(lanSibling.connection.connectionState, .connected)
        let saved = try XCTUnwrap(boards.boards.first { $0.id == bleID })
        XCTAssertEqual(saved.preferredTransport, "hotspot")
        XCTAssertEqual(saved.hotspotIP, "10.20.30.40")
        XCTAssertEqual(saved.lastHost, "192.168.1.22")
        XCTAssertFalse(model.isSwitchingTransport)
    }

    func testSelectedHotspotJoinFailureKeepsPreviousAPAndSelectedBLECarriers() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = makeSessions()
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        let oldA = sessions.session(for: UUID().uuidString, name: "A")
        let oldAP = wire(identity: identityA, ssid: ssidA, ip: "10.244.142.9", kind: .hotspot)
        _ = await oldA.connection.connect(using: oldAP)
        let targetB = sessions.session(for: UUID().uuidString, name: "B")
        let ble = wire(identity: identityB, ssid: ssidB, ip: "10.247.72.1")
        _ = await targetB.connection.connect(using: ble)
        sessions.select(targetB)
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        await model.selectTransport(.hotspot, sessions: sessions, boardStore: boards,
            joinBoardHotspot: { _ in throw RinaTransportError.underlying("Association failed") },
            connectTransport: { _, _, _ in XCTFail("Do not dial after failed association"); return false })
        XCTAssertEqual(oldA.connection.connectionState, .connected)
        XCTAssertEqual(targetB.connection.connectionState, .connected)
        XCTAssertEqual(targetB.connection.transportKind, .bluetooth)
        XCTAssertEqual(oldAP.disconnectCount, 0)
        XCTAssertEqual(ble.disconnectCount, 0)
        XCTAssertEqual(model.lastErrorMessage, "Association failed")
        XCTAssertFalse(model.isSwitchingTransport)
    }

    func testSharedCustomSSIDDoesNotExemptSiblingIPConflictOrMisattributeSavedUpdate() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sharedSSID = "RinaChanBoard-Custom"
        let sibling = KnownBoard(id: UUID().uuidString, name: "B", hotspotSSID: sharedSSID,
            hotspotIP: "10.247.72.1", physicalBoardID: identityB)
        let original = KnownBoard(id: UUID().uuidString, name: "A", hotspotSSID: sharedSSID,
            hotspotIP: "10.244.142.9", physicalBoardID: identityA)
        // B comes first so an SSID-first saved lookup would mutate B.
        boards.upsert(sibling)
        boards.upsert(original)
        let connection = BoardConnection()
        let transport = wire(identity: identityA, ssid: sharedSSID, ip: "10.244.142.9")
        _ = await connection.connect(using: transport)
        defer { connection.disconnect() }
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        let commandCount = transport.sentFrames(type: .cmd).count
        let conflict = await model.setAp(ssid: "", password: "", ip: "10.247.72.1",
            connection: connection, boardStore: boards)
        XCTAssertFalse(conflict)
        XCTAssertNotNil(model.lastErrorMessage)
        XCTAssertEqual(transport.sentFrames(type: .cmd).count, commandCount)
        XCTAssertEqual(boards.boards, [sibling, original])
        transport.commandReply["apIp"] = "10.20.30.40"
        let saved = await model.setAp(ssid: "", password: "", ip: "10.20.30.40",
            connection: connection, boardStore: boards)
        XCTAssertTrue(saved)
        XCTAssertEqual(boards.boards.first { $0.id == sibling.id }, sibling)
        XCTAssertEqual(boards.boards.first { $0.id == original.id }?.hotspotIP, "10.20.30.40")
        XCTAssertEqual(boards.boards.first { $0.id == original.id }?.physicalBoardID, identityA)
        XCTAssertEqual(boards.boards.count, 2)
    }

    func testColdLegacyDirectAndSelectedAPDialsUseOneFactoryUpgradeFallback() async throws {
        for useSelection in [false, true] {
            let (boards, defaults, suite) = try makeStore()
            defer { defaults.removePersistentDomain(forName: suite) }
            let id = UUID().uuidString
            boards.upsert(KnownBoard(id: id, name: "A", preferredTransport: "hotspot",
                lastHost: "192.168.4.1", hotspotSSID: ssidA, physicalBoardID: identityA))
            let cold = BoardStore(defaults: defaults)
            let sessions = makeSessions()
            defer { sessions.sessions.forEach { $0.connection.disconnect() } }
            let unavailable = wire(identity: identityA, ssid: ssidA, ip: "192.168.4.1", kind: .hotspot)
            unavailable.connectFailure = "Legacy gateway is unreachable"
            let upgraded = wire(identity: identityA, ssid: ssidA, ip: "10.244.142.9", kind: .hotspot)
            let model = ConnectionViewModel(startBonjourBrowsing: false)
            var attempted: [String] = []
            if useSelection {
                let target = sessions.session(for: id, name: "A")
                sessions.select(target)
                XCTAssertTrue(model.canSelectTransport(.hotspot, session: target, boardStore: cold))
                await model.selectTransport(.hotspot, sessions: sessions, boardStore: cold,
                    joinBoardHotspot: { expected in XCTAssertEqual(expected, self.ssidA); return expected },
                    connectTransport: { session, proposed, expectedIdentity in
                        let host = (proposed as! TCPTransport).host
                        attempted.append(host)
                        XCTAssertEqual(expectedIdentity, self.identityA)
                        return await session.connection.connect(using: host == "192.168.4.1" ? unavailable : upgraded,
                            expectedBoardIdentity: expectedIdentity)
                    })
            } else {
                await model.connectHotspot(sessions: sessions, boardStore: cold,
                    joinBoardHotspot: { self.ssidA }, connectTransport: { target, proposed in
                        let host = (proposed as! TCPTransport).host
                        attempted.append(host)
                        return await target.connection.connect(using: host == "192.168.4.1" ? unavailable : upgraded,
                            expectedBoardIdentity: self.identityA)
                    })
                XCTAssertEqual(model.directAPStage, .connected)
            }
            XCTAssertEqual(attempted, ["192.168.4.1", "10.244.142.9"])
            XCTAssertEqual(sessions.sessions.count, 1)
            XCTAssertTrue(sessions.existingSession(for: id) === sessions.active)
            XCTAssertEqual(sessions.active.connection.boardIdentity, identityA)
            let saved = try XCTUnwrap(BoardStore(defaults: defaults).boards.first)
            XCTAssertEqual(saved.id, id)
            XCTAssertEqual(saved.hotspotIP, "10.244.142.9")
            XCTAssertNil(saved.lastHost)
        }
    }

    /// A manual-host connect must persist the handshake `boardId`. Restoring
    /// that record against a host that now answers as a different board stops
    /// before the connection is published ready.
    func testManualHostSavesHandshakeIdentityAndRejectsDifferentBoardBeforeReady() async throws {
        let (boards, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = "192.168.1.40"
        let model = ConnectionViewModel(startBonjourBrowsing: false)
        model.manualHost = host
        let connection = BoardConnection(reconnectDelay: { _ in 60 })
        defer { connection.disconnect() }
        let transport = wire(identity: identityA, ssid: ssidA, ip: host,
                             kind: .wifi(host: host, port: RinaLinkConstants.tcpPort))
        await model.connectManualHost(connection: connection, boardStore: boards,
                                      transportFactory: { _ in transport })
        let saved = try XCTUnwrap(boards.boards.first)
        XCTAssertEqual(saved.id, host)
        XCTAssertEqual(saved.physicalBoardID, identityA)
        XCTAssertEqual(connection.boardIdentity, identityA)
        connection.disconnect()

        let sessions = makeSessions()
        defer { sessions.sessions.forEach { $0.connection.disconnect() } }
        var becameReady = false
        let impostor = wire(identity: identityB, ssid: ssidB, ip: host,
                            kind: .wifi(host: host, port: RinaLinkConstants.tcpPort))
        await model.connectSavedBoard(saved, sessions: sessions, boardStore: boards,
            joinBoardHotspot: { _ in
                XCTFail("a saved home-Wi-Fi host must not join a hotspot")
                return ""
            },
            connectTransport: { target, _ in
                await target.connection.connect(using: impostor,
                    expectedBoardIdentity: saved.physicalBoardID,
                    onReady: { becameReady = true })
            })
        XCTAssertFalse(becameReady, "a different boardId must be rejected before ready")
        guard case .failed(let message) = sessions.active.connection.connectionState else {
            XCTFail("identity mismatch must fail the restore, state=\(sessions.active.connection.connectionState)")
            return
        }
        XCTAssertNil(sessions.active.connection.boardIdentity)
        XCTAssertEqual(boards.boards.first?.physicalBoardID, identityA)
        XCTAssertEqual(model.lastErrorMessage, message)
        XCTAssertEqual(message, Bundle(identifier: "com.rinachan.board")?.localizedString(
            forKey: "连接地址对应另一块璃奈板，已停止连接", value: nil, table: nil))
    }

    private func wire(identity: String, ssid: String, ip: String, kind: TransportKind = .bluetooth) -> APTestWire {
        let wire = APTestWire(kind: kind)
        wire.commandReply = ["ok": true, "boardId": identity, "defaultName": "RinaBoard-\(identity)", "apSsid": ssid, "apIp": ip]
        return wire
    }

    private func makeStore() throws -> (BoardStore, UserDefaults, String) {
        let suite = "BoardAPConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (BoardStore(defaults: defaults), defaults, suite)
    }

    private func makeSessions() -> BoardSessionStore {
        BoardSessionStore(scanner: APTestBLE(), makeBLETransport: { APTestBLE() })
    }
}

@MainActor
private final class APTestBLE: @MainActor RinaTransport, @MainActor BLEConnecting {
    let kind: TransportKind = .bluetooth
    let preferredChunkBytes = 180
    var peripheralIdentifier: UUID?
    var connectingPeripheralID: UUID? { nil }
    var connectedPeripheralID: UUID? { peripheralIdentifier }
    var connectedPeripheralName: String? { nil }
    var connectedRSSI: Int? { nil }
    var discoveredPeripherals: [DiscoveredPeripheral] { [] }
    var isScanning = false
    var scanDidTimeOut = false
    var lastError: String?
    func updateConnectedPeripheralName(_ name: String) {}
    func startScan() { isScanning = true }
    func stopScan() { isScanning = false }
    func stateStream() -> AsyncStream<TransportState> { AsyncStream { $0.finish() } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { $0.finish() } }
    func connect() async throws { throw RinaTransportError.notConnected }
    func disconnect() {}
    func send(_ data: Data) async throws { throw RinaTransportError.notConnected }
}

@MainActor
private final class APTestWire: @MainActor RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 512
    var commandReply: [String: Any] = ["ok": true]
    private(set) var disconnectCount = 0
    var connectFailure: String?
    private let decoder = RinaLinkDecoder()
    private var sent: [RinaLinkFrame] = []
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var incomingContinuation: AsyncStream<Data>.Continuation?

    init(kind: TransportKind) { self.kind = kind }
    func stateStream() -> AsyncStream<TransportState> { AsyncStream { stateContinuation = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { incomingContinuation = $0 } }
    func connect() async throws {
        if let connectFailure { throw RinaTransportError.underlying(connectFailure) }
        stateContinuation?.yield(.connected)
    }
    func disconnect() {
        disconnectCount += 1
        stateContinuation?.yield(.disconnected)
    }
    func sentFrames(type: RinaLinkMessageType) -> [RinaLinkFrame] { sent.filter { $0.type == type.rawValue } }
    func send(_ data: Data) async throws {
        for request in decoder.feed(data) {
            sent.append(request)
            let reply: [String: Any] = request.type == RinaLinkMessageType.getStatus.rawValue
                ? ["ok": true, "wifi": commandReply] : commandReply
            incomingContinuation?.yield(try RinaLinkEncoder.encode(RinaLinkFrame(
                type: request.type | 0x80, seq: request.seq, flags: 0,
                payload: JSONSerialization.data(withJSONObject: reply))))
        }
    }
}
