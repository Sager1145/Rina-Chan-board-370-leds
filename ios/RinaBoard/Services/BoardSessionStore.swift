import Foundation
import RinaCore

/// The resources and connection state belonging to one board. A session owns
/// its transport so connecting one board never replaces another board's link.
@Observable
@MainActor
public final class BoardSession: Identifiable {
    public let id = UUID()
    public fileprivate(set) var boardID: String?
    public var name: String
    public let connection: BoardConnection
    /// Built by the store's factory rather than constructed here, because
    /// `BLETransport.init` opens a `CBCentralManager` immediately: a session
    /// that hardcoded it would power the radio even in a virtual run.
    public let bleTransport: any BLEConnecting

    /// A board can be reached by its BLE UUID, a Bonjour identity, and a Wi-Fi
    /// host over its lifetime. Keep every observed spelling for lookup.
    @ObservationIgnored fileprivate var aliases: Set<String> = []
    /// A local TCP address learned from a completed, identified handshake,
    /// never merely from a saved preference or an unverified host spelling.
    @ObservationIgnored fileprivate var verifiedLocalEndpoint: (host: String, port: UInt16, identity: String)?

    fileprivate init(
        boardID: String? = nil,
        name: String = String(localized: "璃奈板"),
        makeBLETransport: @MainActor () -> any BLEConnecting,
        makeConnection: @MainActor () -> BoardConnection
    ) {
        self.boardID = boardID
        self.name = name
        self.connection = makeConnection()
        self.bleTransport = makeBLETransport()
        if let boardID { aliases.insert(boardID) }
        connection.reconnectCandidatesProvider = { [weak self] failedKind, wifi in
            self?.reconnectCandidates(after: failedKind, wifi: wifi) ?? []
        }
    }

    fileprivate func remember(_ boardID: String) {
        aliases.insert(boardID)
        if self.boardID == nil { self.boardID = boardID }
        rememberCurrentTransportIdentity()
    }

    fileprivate func matches(_ boardID: String) -> Bool {
        rememberCurrentTransportIdentity()
        if boardID.hasPrefix("hotspot:"),
           let physicalID = BoardIdentity.boardID(fromAPSSID: String(boardID.dropFirst("hotspot:".count))),
           (connection.boardIdentity ?? connection.lastKnownBoardIdentity) == physicalID {
            return true
        }
        return self.boardID == boardID || aliases.contains(boardID)
    }

    /// Shared board-group member-resolution rule for `GroupControlFanOut`
    /// and `BoardGroupCoordinator.session(for:)`: a member's
    /// `physicalBoardID` is `BoardConnection.boardIdentity` (or, once this
    /// connection has disconnected and cleared it, the last identity it ever
    /// reported), never `boardID` (the session's own persistent slot id) —
    /// the two callers must agree, or a just-disconnected primary/sink would
    /// resolve differently in each.
    public func matchesGroupMember(physicalBoardID: String) -> Bool {
        (connection.boardIdentity ?? connection.lastKnownBoardIdentity) == physicalBoardID
    }

    /// Every `KnownBoard.id` spelling (BLE UUID/host/Bonjour storage id) this
    /// session has ever been reached by, plus its own `boardID` — what
    /// `BoardGroupEditorView.addMember` snapshots into a fresh member's
    /// `knownBoardIDs` (BOARD_GROUP_SPEC.md §3 auto-connect addendum).
    public var knownIdentifiers: [String] {
        rememberCurrentTransportIdentity()
        var ids = aliases
        if let boardID { ids.insert(boardID) }
        return Array(ids)
    }

    /// Supplies one same-board alternate; BoardConnection owns attempt
    /// ordering, identity verification, and the user's stopped-retry guard.
    private func reconnectCandidates(after failedKind: TransportKind?, wifi: WifiStatus?) -> [BoardReconnectCandidate] {
        rememberCurrentTransportIdentity()
        guard let identity = connection.reconnectCandidateIdentity else { return [] }
        switch failedKind {
        case .wifi, .hotspot:
            if bleTransport.peripheralIdentifier == nil {
                let uuid = aliases.sorted().compactMap { alias -> UUID? in
                    let raw = alias.hasPrefix("ble:") ? String(alias.dropFirst(4)) : alias
                    return UUID(uuidString: raw)
                }.first
                bleTransport.peripheralIdentifier = uuid
            }
            guard bleTransport.peripheralIdentifier != nil else { return [] }
            return [BoardReconnectCandidate(transport: bleTransport, expectedBoardIdentity: identity)]
        case .bluetooth:
            if wifi?.staConnected == true,
               wifi?.boardId == nil || wifi?.boardId?.uppercased() == identity.uppercased(),
               let host = wifi?.ip?.trimmingCharacters(in: .whitespacesAndNewlines),
               Self.isUsableStationAddress(host) {
                let reportedPort = wifi?.tcpPort ?? Int(RinaLinkConstants.tcpPort)
                if let port = UInt16(exactly: reportedPort), port > 0 {
                    return [BoardReconnectCandidate(transport: TCPTransport(host: host, port: port),
                                                    expectedBoardIdentity: identity)]
                }
            }
            if let endpoint = verifiedLocalEndpoint, endpoint.identity.uppercased() == identity.uppercased() {
                return [BoardReconnectCandidate(transport: TCPTransport(host: endpoint.host, port: endpoint.port),
                                                expectedBoardIdentity: identity)]
            }
            return []
        case nil:
            return []
        }
    }

    private static func isUsableStationAddress(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ UInt8($0) != nil }) else { return false }
        return host != "0.0.0.0" && host != "255.255.255.255"
    }

    private func rememberCurrentTransportIdentity() {
        if let peripheralID = bleTransport.peripheralIdentifier?.uuidString {
            aliases.insert(peripheralID)
        }
        if connection.connectionState == .connected,
           case .wifi(let host, let port) = connection.transportKind {
            aliases.insert(host)
            if !host.isEmpty, host != "0.0.0.0", port > 0,
               let identity = connection.boardIdentity {
                verifiedLocalEndpoint = (host: host, port: port, identity: identity)
            }
        }
        // AP metadata arrives over BLE too. Register a renamed SSID against
        // the same verified physical session without changing its BLE slot.
        if connection.connectionState == .connected,
           let ssid = connection.wifi?.apSsid,
           let identity = connection.boardIdentity,
           connection.wifi?.boardId?.uppercased() == identity.uppercased() {
            aliases.insert(KnownBoard.hotspotStorageID(ssid: ssid))
        }
        if connection.connectionState == .connected,
           connection.transportKind == .hotspot,
           let ssid = connection.expectedHotspotSSID,
           BoardIdentity.matches(expectedHotspotSSID: ssid, reported: connection.wifi) != false {
            aliases.insert(KnownBoard.hotspotStorageID(ssid: ssid))
        }
    }
}

/// Keeps independent board sessions while retaining one scanner for discovery.
/// The scanner deliberately is not any session's connecting BLE transport,
/// because CoreBluetooth scanning is shared across boards.
///
/// `scanner` and `makeBLETransport` are protocol-typed rather than
/// `BLETransport` so a caller can supply BLE stand-ins that never touch
/// CoreBluetooth. Both defaults construct a real `BLETransport`, which opens a
/// `CBCentralManager` in its initializer — overriding *both* is what keeps the
/// radio out of a virtual run.
@Observable
@MainActor
public final class BoardSessionStore {
    public private(set) var sessions: [BoardSession] = []
    public private(set) var active: BoardSession
    public let scanner: any BoardScanning
    /// Lets `BoardGroupCoordinator` (BOARD_GROUP_SPEC §3) claim that a session
    /// is currently group-owned, so `select(_:)` leaves its output lease
    /// alone instead of invalidating a running group upload/playback just
    /// because a person tapped that board's tab. Kept as an injected closure
    /// rather than a hard dependency on the coordinator type, so this store
    /// stays usable (and testable) without board groups at all.
    public var isGroupOwned: ((BoardSession) -> Bool)?
    /// One carrier per session, so connecting one board never replaces another
    /// board's link.
    @ObservationIgnored private let makeBLETransport: @MainActor () -> any BLEConnecting
    /// Tests inject a `BoardConnection` with short reconnect delays so the
    /// real connect/reconnect path runs in milliseconds. Production uses the
    /// default `BoardConnection()`.
    @ObservationIgnored private let makeConnection: @MainActor () -> BoardConnection

    /// The defaults are resolved in the body rather than as default arguments,
    /// because a default argument is evaluated in a nonisolated context and
    /// `BLETransport.init` is main-actor isolated.
    public init(
        scanner: (any BoardScanning)? = nil,
        makeBLETransport: (@MainActor () -> any BLEConnecting)? = nil,
        makeConnection: (@MainActor () -> BoardConnection)? = nil
    ) {
        let make: @MainActor () -> any BLEConnecting = makeBLETransport ?? { BLETransport() }
        let makeConn: @MainActor () -> BoardConnection = makeConnection ?? { BoardConnection() }
        self.makeBLETransport = make
        self.makeConnection = makeConn
        self.scanner = scanner ?? BLETransport()
        self.active = BoardSession(makeBLETransport: make, makeConnection: makeConn)
    }

    /// Finds a session by its persisted or currently connected identity, or
    /// turns the initial empty session into the first board session.
    public func session(for id: String, name: String) -> BoardSession {
        if let existing = existingSession(for: id) {
            existing.name = name
            existing.remember(id)
            return existing
        }

        if sessions.isEmpty, active.boardID == nil {
            active.boardID = id
            active.name = name
            active.remember(id)
            sessions = [active]
            return active
        }

        let session = BoardSession(boardID: id, name: name, makeBLETransport: makeBLETransport,
                                   makeConnection: makeConnection)
        sessions.append(session)
        return session
    }

    /// Like `session(for:name:)` but for background (non-user-initiated)
    /// callers such as `GroupAutoConnector`: finds an existing session by
    /// id/alias, or appends a brand-new session — never binds or replaces
    /// `active`, even when `active` is still the launch-time unbound
    /// placeholder. `session(for:name:)` turning that placeholder into the
    /// first background member it dials made `RootTabView`'s autoReconnect
    /// guard (`active.boardID == expected` / `.disconnected`) see an
    /// already-claimed active session and skip the user's real last-used
    /// board.
    public func backgroundSession(for id: String, name: String) -> BoardSession {
        if let existing = existingSession(for: id) {
            existing.name = name
            existing.remember(id)
            return existing
        }
        let session = BoardSession(boardID: id, name: name, makeBLETransport: makeBLETransport,
                                   makeConnection: makeConnection)
        sessions.append(session)
        return session
    }

    /// Returns a retained session without creating one; used by status and
    /// forget flows that should not create an empty board row.
    public func existingSession(for id: String) -> BoardSession? {
        if id.hasPrefix("hotspot:"),
           let physicalID = BoardIdentity.boardID(fromAPSSID: String(id.dropFirst("hotspot:".count))),
           let live = sessions.first(where: {
               $0.connection.connectionState == .connected && $0.connection.boardIdentity == physicalID
           }) { return live }
        return sessions.first { $0.matches(id) }
    }

    /// A legacy BLE UUID and AP row can start as separate slots until a
    /// handshake reveals they are one device. Retain the newly selected
    /// carrier, merge its aliases, and stop the retired carrier/reconnect loop.
    public func consolidateVerifiedSession(_ retained: BoardSession) {
        guard retained.connection.connectionState == .connected,
              let identity = retained.connection.boardIdentity,
              sessions.contains(where: { $0 === retained }) else { return }
        _ = retained.knownIdentifiers // Capture this verified carrier before retiring aliases.
        let duplicates = sessions.filter {
            $0 !== retained && ($0.connection.boardIdentity ?? $0.connection.lastKnownBoardIdentity) == identity
        }
        for duplicate in duplicates {
            retained.aliases.formUnion(duplicate.knownIdentifiers)
            if retained.verifiedLocalEndpoint == nil,
               let endpoint = duplicate.verifiedLocalEndpoint,
               endpoint.identity.uppercased() == identity.uppercased() {
                retained.verifiedLocalEndpoint = endpoint
            }
            duplicate.connection.disconnect()
            if active === duplicate { select(retained) }
        }
        sessions.removeAll { session in duplicates.contains { $0 === session } }
    }

    /// Every retained session answering to any of `ids` (persisted id or
    /// alias). Like `existingSession(for:)`, never creates, renames or
    /// selects a session.
    public func existingSessions(matchingAnyOf ids: Set<String>) -> [BoardSession] {
        guard !ids.isEmpty else { return [] }
        return sessions.filter { session in ids.contains { session.matches($0) } }
    }

    /// Shared board-group member-resolution rule (M3): `GroupControlFanOut`
    /// and `BoardGroupCoordinator.session(for:)` both call this instead of
    /// picking `sessions.first(where: matchesGroupMember:)` on their own, so
    /// two sessions that both resolve to the same `physicalBoardID` (e.g. a
    /// stale, disconnected session still holding the identity in
    /// `lastKnownBoardIdentity`, alongside a freshly (re)connected one)
    /// always resolve to the same session in both callers. Prefers a
    /// currently CONNECTED session whose live `boardIdentity` matches;
    /// falls back to `BoardSession.matchesGroupMember(physicalBoardID:)`
    /// (which also accepts `lastKnownBoardIdentity`) only when no session is
    /// connected under that identity.
    public func session(matchingGroupMember physicalBoardID: String) -> BoardSession? {
        if let connected = sessions.first(where: {
            $0.connection.connectionState == .connected && $0.connection.boardIdentity == physicalBoardID
        }) {
            return connected
        }
        return sessions.first { $0.matchesGroupMember(physicalBoardID: physicalBoardID) }
    }

    /// Changes the visible board and stops its old producers, while leaving
    /// both underlying connections intact.
    public func select(_ session: BoardSession) {
        guard active !== session else { return }
        if isGroupOwned?(active) != true {
            active.connection.output.invalidate()
        }
        active = session
    }

    /// Starts launch-time recovery only while the session selected when the
    /// launch task began is still current. Draft restoration yields long
    /// enough for a person to choose another board, and that choice wins.
    func sessionForAutomaticReconnect(
        id: String,
        name: String,
        ifCurrent expected: BoardSession,
        withBoardID expectedBoardID: String?
    ) -> BoardSession? {
        guard active === expected,
              active.boardID == expectedBoardID,
              active.connection.connectionState == .disconnected else { return nil }
        let target = session(for: id, name: name)
        select(target)
        return target
    }

    /// Removes one board session. Other board links remain connected.
    public func remove(id: String) {
        guard let index = sessions.firstIndex(where: { $0.matches(id) }) else { return }
        let removed = sessions.remove(at: index)
        removed.connection.disconnect()

        guard active === removed else { return }
        if let retained = sessions.first {
            select(retained)
        } else {
            let placeholder = BoardSession(makeBLETransport: makeBLETransport, makeConnection: makeConnection)
            // `select` deliberately invalidates the removed output again; it
            // is harmless and keeps the selection transition consistent.
            select(placeholder)
        }
    }
}
