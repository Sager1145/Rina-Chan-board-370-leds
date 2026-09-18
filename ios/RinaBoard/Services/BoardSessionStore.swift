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
    public let connection = BoardConnection()
    /// Built by the store's factory rather than constructed here, because
    /// `BLETransport.init` opens a `CBCentralManager` immediately: a session
    /// that hardcoded it would power the radio even in a virtual run.
    public let bleTransport: any BLEConnecting

    /// A board can be reached by its BLE UUID, a Bonjour identity, and a Wi-Fi
    /// host over its lifetime. Keep every observed spelling for lookup.
    @ObservationIgnored fileprivate var aliases: Set<String> = []

    fileprivate init(
        boardID: String? = nil,
        name: String = "璃奈板",
        makeBLETransport: @MainActor () -> any BLEConnecting
    ) {
        self.boardID = boardID
        self.name = name
        self.bleTransport = makeBLETransport()
        if let boardID { aliases.insert(boardID) }
    }

    fileprivate func remember(_ boardID: String) {
        aliases.insert(boardID)
        if self.boardID == nil { self.boardID = boardID }
        rememberCurrentTransportIdentity()
    }

    fileprivate func matches(_ boardID: String) -> Bool {
        rememberCurrentTransportIdentity()
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

    private func rememberCurrentTransportIdentity() {
        if let peripheralID = bleTransport.peripheralIdentifier?.uuidString {
            aliases.insert(peripheralID)
        }
        if case .wifi(let host, _) = connection.transportKind {
            aliases.insert(host)
        }
        // Direct joins begin with the legacy shared-IP session, but saving
        // the board uses its unique SSID. Resolve that spelling to this link.
        if connection.transportKind == .hotspot,
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

    /// The defaults are resolved in the body rather than as default arguments,
    /// because a default argument is evaluated in a nonisolated context and
    /// `BLETransport.init` is main-actor isolated.
    public init(
        scanner: (any BoardScanning)? = nil,
        makeBLETransport: (@MainActor () -> any BLEConnecting)? = nil
    ) {
        let make: @MainActor () -> any BLEConnecting = makeBLETransport ?? { BLETransport() }
        self.makeBLETransport = make
        self.scanner = scanner ?? BLETransport()
        self.active = BoardSession(makeBLETransport: make)
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

        let session = BoardSession(boardID: id, name: name, makeBLETransport: makeBLETransport)
        sessions.append(session)
        return session
    }

    /// Returns a retained session without creating one; used by status and
    /// forget flows that should not create an empty board row.
    public func existingSession(for id: String) -> BoardSession? {
        sessions.first { $0.matches(id) }
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
            let placeholder = BoardSession(makeBLETransport: makeBLETransport)
            // `select` deliberately invalidates the removed output again; it
            // is harmless and keeps the selection transition consistent.
            select(placeholder)
        }
    }
}
