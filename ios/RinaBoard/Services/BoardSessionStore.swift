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
    public let bleTransport = BLETransport()

    /// A board can be reached by its BLE UUID, a Bonjour identity, and a Wi-Fi
    /// host over its lifetime. Keep every observed spelling for lookup.
    @ObservationIgnored fileprivate var aliases: Set<String> = []

    fileprivate init(boardID: String? = nil, name: String = "璃奈板") {
        self.boardID = boardID
        self.name = name
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

/// Keeps independent board sessions while retaining one BLE scanner for
/// discovery. The scanner deliberately is not any session's connecting BLE
/// transport, because CoreBluetooth scanning is shared across boards.
@Observable
@MainActor
public final class BoardSessionStore {
    public private(set) var sessions: [BoardSession] = []
    public private(set) var active: BoardSession
    public let scanner: BLETransport

    public init(scanner: BLETransport? = nil) {
        self.scanner = scanner ?? BLETransport()
        self.active = BoardSession()
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

        let session = BoardSession(boardID: id, name: name)
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
        active.connection.output.invalidate()
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
            let placeholder = BoardSession()
            // `select` deliberately invalidates the removed output again; it
            // is harmless and keeps the selection transition consistent.
            select(placeholder)
        }
    }
}
