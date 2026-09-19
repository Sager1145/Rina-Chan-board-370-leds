import Foundation
import RinaCore

/// Drives the Connection tab (FEATURE_INVENTORY §E): BLE scan/connect, home
/// Wi-Fi discovery via Bonjour + manual host, hotspot join, and on-board
/// Wi-Fi provisioning (`wifi_*` commands over whatever transport is active).
@Observable
@MainActor
public final class ConnectionViewModel {
    public enum DirectAPStage: Equatable {
        case idle
        case joiningPhoneToBoardAP
        case connectingToBoard
        case connected
        case failed(String)
    }

    public enum ProvisionStage: Equatable {
        case idle
        case sendingCredentials
        case waitingForBoard
        case boardJoined
        case connectingToBoard
        case connected
        case failed(String)
    }

    public let bonjour = BonjourBrowser()

    public private(set) var isConnectingBLE = false
    public private(set) var isConnectingHome = false
    public private(set) var connectingHomeBoardID: String?
    public private(set) var connectingSavedBoardID: String?
    public private(set) var isScanningNetworks = false
    public var manualHost: String = ""
    public var manualPhoneSSID: String = ""
    public var lastErrorMessage: String?

    public var wifiNetworks: [WifiNetwork] = []

    // MARK: Board name (RinaLink `set_device_name`)

    /// Bound to the rename field. Seeded from the board on connect so the user
    /// edits the current name rather than an empty box.
    public var boardNameInput: String = ""
    public private(set) var isRenamingBoard = false
    public private(set) var boardNameStatus: String?
    /// The MAC-derived name the board falls back to when the custom name is
    /// cleared, so the UI can show what "reset" would give you.
    public private(set) var boardDefaultName: String?
    /// `get_info`'s firmware version and build stamp, shown on the 面板 page.
    public private(set) var boardFirmware: String?
    public private(set) var boardBuild: String?
    public private(set) var boardHasCustomName = false

    // MARK: iPhone Personal Hotspot profile (RINALINK_PROTOCOL_V1 §8)

    /// iOS doesn't expose a reliable Personal Hotspot SSID. This starts with
    /// the last SSID that successfully connected a board, or remains empty.
    public var hotspotName: String
    /// The Personal Hotspot password iOS never exposes to apps — typed once,
    /// then remembered in the Keychain (`KeychainStore`), keyed by SSID.
    public var hotspotPassword: String = ""
    public private(set) var isProvisioningHotspot = false
    public private(set) var hotspotPasswordIsSaved = false
    public private(set) var directAPStage: DirectAPStage = .idle
    public private(set) var homeProvisionStage: ProvisionStage = .idle
    public private(set) var hotspotProvisionStage: ProvisionStage = .idle

    private static let confirmedHotspotSSIDKey = "com.rinachan.board.confirmedHotspotSSID"

    public init(startBonjourBrowsing: Bool = true) {
        if startBonjourBrowsing { bonjour.start() }
        hotspotName = UserDefaults.standard.string(forKey: Self.confirmedHotspotSSIDKey) ?? ""
        let savedPassword = KeychainStore.load(account: hotspotName)
        hotspotPassword = savedPassword ?? ""
        hotspotPasswordIsSaved = savedPassword != nil
    }

    deinit {
        let bonjour = bonjour
        Task { @MainActor in bonjour.stop() }
    }

    // MARK: BLE

    public func toggleBLEScan(ble: any BoardScanning) {
        if ble.isScanning {
            ble.stopScan()
        } else {
            lastErrorMessage = nil
            ble.startScan()
            // Surface an error instead of silently no-oping (e.g. Bluetooth off).
            if let error = ble.lastError {
                lastErrorMessage = error
            }
        }
    }

    public func connectBLE(_ peripheral: DiscoveredPeripheral, ble: any BLEConnecting, connection: BoardConnection, boardStore: BoardStore) async {
        let boardID = peripheral.id.uuidString
        let reconnectingSavedBoard = boardStore.boards.contains { $0.id == boardID }
        await connectBLE(peripheral, ble: ble, connection: connection, boardStore: boardStore) { [connection, boardStore] transport in
            await connection.connect(using: transport) { [weak connection, weak boardStore] in
                guard let connection, let boardStore else { return }
                if reconnectingSavedBoard,
                   !boardStore.boards.contains(where: { $0.id == boardID }) {
                    return
                }
                boardStore.upsert(KnownBoard(
                    id: boardID,
                    name: connection.deviceName ?? peripheral.name,
                    preferredTransport: "bluetooth",
                    lastSeen: Date()
                ))
            }
        }
    }

    func connectBLE(
        _ peripheral: DiscoveredPeripheral,
        ble: any BLEConnecting,
        connection: BoardConnection,
        boardStore: BoardStore,
        connectTransport: @escaping @MainActor (any BLEConnecting) async -> Bool
    ) async {
        guard !isConnectingBLE else { return }
        isConnectingBLE = true
        defer { isConnectingBLE = false }

        let boardID = peripheral.id.uuidString
        let reconnectingSavedBoard = boardStore.boards.contains { $0.id == boardID }
        ble.stopScan()
        lastErrorMessage = nil
        ble.peripheralIdentifier = peripheral.id
        let connected = await connectTransport(ble)
        // A saved row can be forgotten while its BLE connection is pending.
        // Treat that as intentional cancellation: do not publish an error or
        // recreate the row after the old operation resumes.
        if reconnectingSavedBoard,
           !boardStore.boards.contains(where: { $0.id == boardID }) {
            return
        }
        guard connected, ble.connectedPeripheralID == peripheral.id else {
            if !connected {
                // BoardConnection owns connect failure reporting. A nil error
                // means this attempt was superseded or intentionally stopped.
                lastErrorMessage = connection.lastError
                return
            }
            // Prefer the transport's own reason ("蓝牙已关闭…", a connect
            // timeout) for the distinct case where another peripheral became
            // connected while this request was pending.
            lastErrorMessage = ble.lastError ?? connection.lastError ?? NSLocalizedString("连接失败", comment: "board connection failed")
            return
        }
        boardStore.upsert(KnownBoard(id: boardID, name: connection.deviceName ?? peripheral.name,
                                      preferredTransport: "bluetooth", lastSeen: Date()))
        await refreshBoardName(connection: connection)
    }

    // MARK: Board name

    /// Seeds the rename field from the connected board. Silent on failure: an
    /// older firmware simply has no name to report and the field stays empty.
    public func resetBoardDetails() {
        boardNameInput = ""
        boardDefaultName = nil
        boardFirmware = nil
        boardBuild = nil
        boardHasCustomName = false
        boardNameStatus = nil
        wifiNetworks = []
    }

    /// One connected board session, as the Connection page sees it.
    public struct BoardDetailsKey: Hashable, Sendable {
        let connection: ObjectIdentifier
        let generation: UUID
    }

    /// The session whose details were cleared for / fully loaded into the
    /// fields. Two keys, so a load cancelled halfway (the page left the
    /// screen) is retried without wiping what the user typed since.
    @ObservationIgnored private var clearedBoardDetailsKey: BoardDetailsKey??
    @ObservationIgnored private var loadedBoardDetailsKey: BoardDetailsKey??

    /// Loads the rename field and default name for `key`'s session, once.
    /// The Connection page calls this every time it is built, which includes
    /// every Settings layout change; only a different board session (or a
    /// disconnect) clears the fields, and a reply is dropped if the board
    /// changed while it was in flight or the user already started typing.
    public func loadBoardDetails(for key: BoardDetailsKey?, connection: BoardConnection) async {
        guard loadedBoardDetailsKey != .some(key) else { return }
        if clearedBoardDetailsKey != .some(key) {
            resetBoardDetails()
            clearedBoardDetailsKey = .some(key)
        }
        guard key != nil else {
            loadedBoardDetailsKey = .some(nil)
            return
        }
        let reply = try? await connection.command(.getInfo)
        guard !Task.isCancelled, clearedBoardDetailsKey == .some(key) else { return }
        // One attempt per session, as before: an older firmware that cannot
        // answer must not be asked again on every rebuild of the page.
        loadedBoardDetailsKey = .some(key)
        guard let reply else { return }
        boardDefaultName = reply.defaultName
        boardFirmware = reply.fw
        boardBuild = reply.build
        boardHasCustomName = reply.customName ?? false
        if boardNameInput.isEmpty, let name = reply.name, !name.isEmpty {
            boardNameInput = name
        }
    }

    public func refreshBoardName(connection: BoardConnection) async {
        guard let reply = try? await connection.command(.getInfo), !Task.isCancelled else { return }
        boardDefaultName = reply.defaultName
        boardHasCustomName = reply.customName ?? false
        if let name = reply.name, !name.isEmpty {
            boardNameInput = name
        }
    }

    /// Renames the board. An empty name clears the override and restores the
    /// MAC-derived default, which is the only way back from a bad name.
    public func renameBoard(connection: BoardConnection, boardStore: BoardStore, ble: any BLEConnecting) async {
        let requested = boardNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceNameValidator.validateDeviceName(requested) {
        case .tooLong(let bytes):
            // Byte count, not character count: CJK costs 3 bytes per character
            // and the BLE scan response has a hard 31-byte payload.
            lastErrorMessage = String(
                format: NSLocalizedString(
                    "名称过长（%1$lld 字节，上限 %2$lld 字节）",
                    comment: "board name UTF-8 byte limit"
                ),
                Int64(bytes),
                Int64(RinaLinkConstants.maxDeviceNameBytes)
            )
            return
        case .valid, .empty:
            break
        }

        isRenamingBoard = true
        boardNameStatus = nil
        defer { isRenamingBoard = false }

        do {
            let reply = try await connection.command(.setDeviceName(name: requested))
            guard reply.ok else {
                lastErrorMessage = reply.error ?? NSLocalizedString("重命名失败", comment: "board rename failed")
                return
            }
            let effective = reply.name ?? requested
            boardNameInput = effective
            boardHasCustomName = reply.customName ?? !requested.isEmpty
            if reply.persisted == false {
                // The name is live over BLE but did not reach flash, so it will
                // not survive a reboot. Say so rather than reporting success.
                boardNameStatus = NSLocalizedString("已生效，但未能写入板子存储（重启后会丢失）", comment: "board rename not persisted")
            } else {
                let format = boardHasCustomName
                    ? NSLocalizedString("已重命名为“%@”", comment: "board renamed confirmation")
                    : NSLocalizedString("已恢复默认名称“%@”", comment: "board default name restored")
                boardNameStatus = String(format: format, effective)
            }
            // Keep the saved-board list in step so the name shown before
            // connecting matches what the board now advertises.
            let currentBoardID: String?
            switch connection.transportKind {
            case .bluetooth: currentBoardID = ble.connectedPeripheralID?.uuidString
            case .wifi(let host, _):
                currentBoardID = boardStore.boards.first(where: { $0.lastHost == host || $0.id == host })?.id
            case .hotspot:
                // Identify from what the connected board itself just reported
                // (RINALINK_PROTOCOL_V1 "Board identity"), not the cache: every
                // board's SoftAP shares one IP, so a stale `lastJoinedSSID`
                // could otherwise write this rename into a different board's
                // saved record. Fall back to a fresh, positive read of the
                // phone's actual current SSID (never the cache alone) for
                // older firmware that doesn't report `apSsid`.
                if let reportedSSID = connection.wifi?.apSsid {
                    currentBoardID = KnownBoard.hotspotStorageID(ssid: reportedSSID)
                } else if let liveSSID = await HotspotJoiner.currentSSID() {
                    currentBoardID = KnownBoard.hotspotStorageID(ssid: liveSSID)
                } else {
                    currentBoardID = nil
                }
            case nil: currentBoardID = nil
            }
            if let id = currentBoardID,
               var known = boardStore.boards.first(where: { $0.id == id }) {
                known.name = effective
                known.lastSeen = Date()
                boardStore.upsert(known)
            }
            if connection.transportKind == .bluetooth {
                ble.updateConnectedPeripheralName(effective)
            }
        } catch {
            lastErrorMessage = String(
                format: NSLocalizedString("重命名失败：%@", comment: "board rename error"),
                error.localizedDescription
            )
        }
    }

    // MARK: Home Wi-Fi (Bonjour / manual)

    public func connectBonjour(_ board: DiscoveredBoard, connection: BoardConnection, boardStore: BoardStore) async {
        // `board.name` is a Bonjour service name, not a hostname — never use
        // it as a connection target. Callers should disable this row in the
        // UI until `board.isResolved` (endpoint or host present).
        guard board.isResolved else {
            lastErrorMessage = NSLocalizedString("尚未解析主机地址", comment: "Bonjour address unresolved")
            return
        }
        guard !isConnectingHome else { return }
        isConnectingHome = true
        connectingHomeBoardID = board.id
        lastErrorMessage = nil
        defer {
            isConnectingHome = false
            connectingHomeBoardID = nil
        }

        let port = board.port ?? RinaLinkConstants.tcpPort
        // `host` is only used for display/storage below; the transport
        // connects via the resolved `endpoint` directly when available (H4).
        let displayHost = board.host ?? board.name
        let serviceIdentity = board.serviceIdentity
        let transportIdentity = serviceIdentity?.storageID ?? displayHost
        let transport: TCPTransport
        if let endpoint = board.endpoint {
            transport = TCPTransport(endpoint: endpoint, kind: .wifi(host: transportIdentity, port: port))
        } else if let host = board.host {
            transport = TCPTransport(host: host, port: port, kind: .wifi(host: host, port: port))
        } else {
            lastErrorMessage = NSLocalizedString("尚未解析主机地址", comment: "Bonjour address unresolved")
            return
        }
        await connection.connect(using: transport)
        guard connection.connectionState == .connected else {
            lastErrorMessage = NSLocalizedString("连接失败", comment: "board connection failed")
            return
        }
        boardStore.upsert(KnownBoard(id: serviceIdentity?.storageID ?? displayHost,
                                      name: connection.deviceName ?? board.name,
                                      preferredTransport: "wifi", lastHost: board.host,
                                      bonjourService: serviceIdentity, lastSeen: Date()))
    }

    public func connectManualHost(connection: BoardConnection, boardStore: BoardStore) async {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        guard !isConnectingHome else { return }
        isConnectingHome = true
        lastErrorMessage = nil
        defer { isConnectingHome = false }
        let transport = TCPTransport(host: host)
        await connection.connect(using: transport)
        guard connection.connectionState == .connected else {
            lastErrorMessage = NSLocalizedString("连接失败", comment: "board connection failed")
            return
        }
        boardStore.upsert(KnownBoard(id: host, name: connection.deviceName ?? host, preferredTransport: "wifi",
                                      lastHost: host, lastSeen: Date()))
    }

    // MARK: Hotspot ("direct")

    /// - Parameter disconnectOtherHotspotSessions: Every board's SoftAP shares
    ///   one IP, so the phone can only ever be usefully associated with one at
    ///   a time. Called right before joining so any other session's hotspot
    ///   connection cannot later reconnect its TCP link onto *this* board once
    ///   the phone's Wi-Fi moves — the caller is expected to disconnect every
    ///   other `.hotspot` session it knows about.
    public func connectHotspot(sessions: BoardSessionStore, boardStore: BoardStore) async {
        await connectHotspot(
            sessions: sessions, boardStore: boardStore,
            joinBoardHotspot: { try await HotspotJoiner.join() },
            connectTransport: { session, transport in
                await session.connection.connect(using: transport)
            }
        )
    }

    /// A prefix join lands on whichever board's SoftAP is in range, so the
    /// session is resolved by the SSID actually joined. An offline hotspot
    /// session of another board must never be repointed at it: its name,
    /// board ID and aliases would then describe two boards at once.
    func connectHotspot(
        sessions: BoardSessionStore,
        boardStore: BoardStore,
        joinBoardHotspot: @escaping @MainActor () async throws -> String,
        connectTransport: @escaping @MainActor (BoardSession, RinaTransport) async -> Bool
    ) async {
        guard directAPStage != .joiningPhoneToBoardAP,
              directAPStage != .connectingToBoard else { return }
        if let online = sessions.sessions.first(where: {
            $0.connection.transportKind == .hotspot && $0.connection.connectionState == .connected
        }) {
            sessions.select(online)
            // D: a silent no-op here reads as a broken button — tell the user
            // which board is already occupying the one hotspot slot the
            // phone's Wi-Fi can be on.
            lastErrorMessage = String(
                format: NSLocalizedString("已连接到 %@，如需切换请先断开或选择已保存的璃奈板", comment: "hotspot already connected, switch via disconnect or saved board"),
                online.connection.deviceName ?? online.name
            )
            return
        }
        directAPStage = .joiningPhoneToBoardAP
        lastErrorMessage = nil
        // Every board's SoftAP shares one IP: stop any hotspot reconnect loop
        // before the join moves the phone's Wi-Fi onto a possibly other board.
        for session in sessions.sessions where session.connection.transportKind == .hotspot {
            session.connection.disconnect()
        }
        do {
            let joinedSSID = try await joinBoardHotspot()
            directAPStage = .connectingToBoard
            let boardID = KnownBoard.hotspotStorageID(ssid: joinedSSID)
            let target = sessions.existingSession(for: boardID)
                ?? sessions.session(for: boardID, name: joinedSSID)
            sessions.select(target)
            let connection = target.connection
            connection.expectedHotspotSSID = joinedSSID
            let connected = await connectTransport(target, HotspotJoiner.makeTransport())
            guard connected, connection.connectionState == .connected else {
                let message = connection.lastError ?? NSLocalizedString("已连接璃奈板热点，但未能建立控制连接", comment: "direct AP control connection failed")
                directAPStage = .failed(message)
                return
            }
            boardStore.upsert(KnownBoard(
                id: KnownBoard.hotspotStorageID(ssid: joinedSSID),
                name: connection.deviceName ?? joinedSSID,
                preferredTransport: "hotspot",
                lastHost: RinaLinkConstants.apIP,
                hotspotSSID: joinedSSID,
                lastSeen: Date()
            ))
            directAPStage = .connected
        } catch {
            directAPStage = .failed(error.localizedDescription)
        }
    }

    /// After provisioning STA over BLE, switch the active connection to TCP
    /// at the board's reported IP.
    public func switchToWifi(connection: BoardConnection, boardStore: BoardStore) async {
        guard let ip = connection.wifi?.ip, !ip.isEmpty else { return }
        let ssid = connection.wifi?.ssid
        homeProvisionStage = .connectingToBoard
        let transport = TCPTransport(host: ip)
        await connection.connect(using: transport)
        guard connection.connectionState == .connected else {
            let message = connection.lastError ?? NSLocalizedString("板子已接入 Wi-Fi，但 App 连接失败", comment: "TCP control connection failed")
            homeProvisionStage = .failed(message)
            return
        }
        if let ssid {
            boardStore.upsert(KnownBoard(id: ip, name: connection.deviceName ?? ssid, preferredTransport: "wifi", lastHost: ip, lastSeen: Date()))
        }
        homeProvisionStage = .connected
    }

    // MARK: Saved boards

    public func forgetBoard(_ board: KnownBoard, ble: any BLEConnecting,
                            connection: BoardConnection, boardStore: BoardStore) {
        let isCurrent: Bool
        switch connection.transportKind {
        case .bluetooth:
            isCurrent = ble.peripheralIdentifier?.uuidString == board.id
        case .wifi(let host, _):
            isCurrent = board.lastHost == host || board.id == host
        case .hotspot:
            // Compare the specific board, not just "some hotspot record":
            // every board's SoftAP shares one IP, so a phone that drifted
            // onto a *different* remembered board hotspot must not forget
            // this one out from under a connection that is actually to it.
            let ssid = connection.expectedHotspotSSID ?? HotspotJoiner.lastJoinedSSID
            isCurrent = ssid.map(KnownBoard.hotspotStorageID) == board.id
        case nil:
            isCurrent = false
        }
        if isCurrent {
            connection.disconnect()
            if board.preferredTransport == "bluetooth" {
                ble.peripheralIdentifier = nil
            }
        }
        boardStore.remove(id: board.id)
        lastErrorMessage = nil
    }

    /// Both saved-board surfaces select the board's own session before dialing.
    /// Never retarget the currently visible session to a different board.
    public func connectSavedBoard(
        _ board: KnownBoard,
        sessions: BoardSessionStore,
        boardStore: BoardStore
    ) async {
        await connectSavedBoard(
            board, sessions: sessions, boardStore: boardStore,
            joinBoardHotspot: { ssid in try await HotspotJoiner.join(ssid: ssid) },
            connectTransport: { session, transport in
                await session.connection.connect(using: transport)
            }
        )
    }

    func connectSavedBoard(
        _ board: KnownBoard,
        sessions: BoardSessionStore,
        boardStore: BoardStore,
        joinBoardHotspot: @escaping @MainActor (String?) async throws -> String,
        connectTransport: @escaping @MainActor (BoardSession, RinaTransport) async -> Bool
    ) async {
        guard connectingSavedBoardID == nil, !isConnectingBLE else { return }
        let target = sessions.session(for: board.id, name: board.name)
        sessions.select(target)
        lastErrorMessage = nil
        switch target.connection.connectionState {
        case .connected:
            // A shared SoftAP IP alone cannot prove which board is connected.
            let identityOK = board.preferredTransport != "hotspot"
                || BoardIdentity.matches(expectedHotspotSSID: board.hotspotSSID,
                                         reported: target.connection.wifi) != false
            if identityOK { return }
        case .connecting, .reconnecting:
            return
        case .disconnected, .failed:
            break
        }
        await connectSavedBoard(
            board, ble: target.bleTransport, connection: target.connection,
            boardStore: boardStore, joinBoardHotspot: joinBoardHotspot,
            connectTransport: { transport in await connectTransport(target, transport) },
            disconnectOtherHotspotSessions: {
                for session in sessions.sessions
                where session !== target && session.connection.transportKind == .hotspot {
                    session.connection.disconnect()
                }
            }
        )
    }

    public func connectSavedBoard(
        _ board: KnownBoard,
        ble: any BLEConnecting,
        connection: BoardConnection,
        boardStore: BoardStore,
        updateLastSeen: Bool = true,
        disconnectOtherHotspotSessions: () -> Void = {}
    ) async {
        await connectSavedBoard(
            board,
            ble: ble,
            connection: connection,
            boardStore: boardStore,
            joinBoardHotspot: { ssid in try await HotspotJoiner.join(ssid: ssid) },
            connectTransport: { transport in await connection.connect(using: transport) },
            updateLastSeen: updateLastSeen,
            disconnectOtherHotspotSessions: disconnectOtherHotspotSessions
        )
    }

    /// Injectable seams keep the ordering around the system hotspot prompt
    /// covered without touching the user's real Wi-Fi configuration in tests.
    /// - Parameter updateLastSeen: `false` for background (connector) dials,
    ///   so an auto-connected group member does not become next launch's
    ///   autoReconnect board just because it happened to answer first.
    /// - Parameter disconnectOtherHotspotSessions: See `connectHotspot`. Called
    ///   right before joining a board's SoftAP, so no other session can later
    ///   reconnect its TCP link onto the board this join lands the phone on —
    ///   every board's SoftAP shares one IP.
    func connectSavedBoard(
        _ board: KnownBoard,
        ble: any BLEConnecting,
        connection: BoardConnection,
        boardStore: BoardStore,
        joinBoardHotspot: @escaping @MainActor (String?) async throws -> String,
        connectTransport: @escaping @MainActor (RinaTransport) async -> Bool,
        updateLastSeen: Bool = true,
        disconnectOtherHotspotSessions: () -> Void = {}
    ) async {
        guard connectingSavedBoardID == nil else { return }
        connectingSavedBoardID = board.id
        lastErrorMessage = nil
        defer { connectingSavedBoardID = nil }

        guard let target = board.connectionTarget else {
            lastErrorMessage = NSLocalizedString("这个已保存设备没有可用的连接地址，请重新扫描", comment: "saved board missing address")
            return
        }

        let connected: Bool
        // Set when a legacy (pre-per-board-SSID) hotspot record resolves to a
        // concrete SSID, so the final upsert below can migrate it onto the
        // SSID-keyed id instead of re-saving the shared-IP legacy id.
        var migratedHotspotSSID: String?
        switch target {
        case .bluetooth(let id):
            ble.peripheralIdentifier = id
            connected = await connectTransport(ble)
        case .bonjour(let service):
            let endpoint = bonjour.endpoint(for: service)
            connected = await connectTransport(TCPTransport(
                endpoint: endpoint,
                kind: .wifi(host: board.id, port: RinaLinkConstants.tcpPort)
            ))
        case .host(let host):
            connected = await connectTransport(TCPTransport(
                host: host, kind: .wifi(host: host, port: RinaLinkConstants.tcpPort)
            ))
        case .boardHotspot(let host, let ssid):
            disconnectOtherHotspotSessions()
            let joinedSSID: String
            do {
                joinedSSID = try await joinBoardHotspot(ssid)
            } catch {
                guard boardStore.boards.contains(where: { $0.id == board.id }) else { return }
                lastErrorMessage = error.localizedDescription
                return
            }
            // The user can forget this board while the iOS association
            // prompt is pending. Do not continue into TCP or recreate it.
            guard boardStore.boards.contains(where: { $0.id == board.id }) else { return }
            if board.hotspotSSID == nil { migratedHotspotSSID = joinedSSID }
            connection.expectedHotspotSSID = joinedSSID
            connected = await connectTransport(TCPTransport(host: host, kind: .hotspot))
        }

        // Forgetting an in-flight connection cancels it intentionally. Do not
        // show a failure or recreate the deleted record when it resumes.
        guard boardStore.boards.contains(where: { $0.id == board.id }) else { return }
        guard connected else {
            // `false` with no transport error means this attempt was
            // superseded by a newer connect or an intentional disconnect.
            // The older launch-time task must stay quiet in that case.
            // Likewise while BoardConnection is still retrying on its own:
            // the status UI already shows 重连中, and an alert would report
            // a failure the next attempt may fix.
            if case .reconnecting = connection.connectionState { return }
            lastErrorMessage = connection.lastError
            return
        }
        var refreshed = board
        if let migratedHotspotSSID {
            refreshed.id = KnownBoard.hotspotStorageID(ssid: migratedHotspotSSID)
            refreshed.hotspotSSID = migratedHotspotSSID
        }
        refreshed.name = connection.deviceName ?? board.name
        if updateLastSeen { refreshed.lastSeen = Date() }
        boardStore.upsert(refreshed)
        await refreshBoardName(connection: connection)
    }

    // MARK: iPhone Personal Hotspot provisioning (RINALINK_PROTOCOL_V1 §8)

    /// Provisions the board with this phone's Personal Hotspot credentials
    /// over the active connection (BLE, or any other transport that's up),
    /// switches the board to `sta_or_ap`, tells it to connect, and waits for
    /// `EV_WIFI` to report it joined the `hotspot` profile — then opens TCP
    /// to the reported IP and remembers `hotspot-tcp` as this board's
    /// preferred transport.
    public func provisionPhoneHotspot(connection: BoardConnection, boardStore: BoardStore) async {
        guard connection.connectionState == .connected else {
            lastErrorMessage = NSLocalizedString("请先连接璃奈板", comment: "connect board first")
            return
        }
        let ssid = hotspotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            lastErrorMessage = NSLocalizedString("请输入热点名称", comment: "enter hotspot name")
            return
        }
        let password = hotspotPassword
        isProvisioningHotspot = true
        hotspotProvisionStage = .sendingCredentials
        lastErrorMessage = nil
        defer {
            isProvisioningHotspot = false
        }
        let (subID, stream) = connection.subscribeToEvents()
        defer { connection.unsubscribe(subID) }
        do {
            _ = try await connection.command(.wifiSetHotspotCredentials(ssid: ssid, password: password))
            _ = try await connection.command(.wifiSetMode(mode: "sta_or_ap"))
            _ = try await connection.command(.wifiConnect)
            hotspotProvisionStage = .waitingForBoard

            let joined = await waitForAssociation(
                in: stream, profile: "hotspot", expectedSSID: ssid)

            // Prefer the IP carried by the matching association; fall back to
            // the merged snapshot only for firmware that omits it.
            let joinedIP = joined.flatMap { status -> String? in
                if let ip = status.ip, !ip.isEmpty { return ip }
                return connection.wifi?.ip
            }
            guard joined != nil, let ip = joinedIP, !ip.isEmpty else {
                hotspotProvisionStage = .failed(NSLocalizedString(
                    "板子未能加入热点。请确认个人热点已开启，名称和密码正确，并按需打开“最大兼容性”。",
                    comment: "board failed to join phone hotspot"
                ))
                return
            }

            hotspotProvisionStage = .connectingToBoard
            let transport = TCPTransport(host: ip, kind: .wifi(host: ip, port: RinaLinkConstants.tcpPort))
            await connection.connect(using: transport)
            guard connection.connectionState == .connected else {
                hotspotProvisionStage = .failed(NSLocalizedString(
                    "板子已加入热点，但 App 未能建立连接。",
                    comment: "board joined hotspot but control connection failed"
                ))
                return
            }
            boardStore.upsert(KnownBoard(id: ip, name: connection.deviceName ?? ssid, preferredTransport: "hotspot-tcp", lastHost: ip, lastSeen: Date()))
            KeychainStore.save(password: password, account: ssid)
            hotspotPasswordIsSaved = true
            UserDefaults.standard.set(ssid, forKey: Self.confirmedHotspotSSIDKey)
            hotspotProvisionStage = .connected
        } catch {
            hotspotProvisionStage = .failed(error.localizedDescription)
        }
    }

    public func setHotspotName(_ name: String) {
        hotspotName = name
        let account = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedPassword = KeychainStore.load(account: account)
        hotspotPassword = savedPassword ?? ""
        hotspotPasswordIsSaved = savedPassword != nil
        hotspotProvisionStage = .idle
    }

    /// Clears the board's stored hotspot credentials and the locally cached
    /// Keychain password.
    public func clearPhoneHotspot(connection: BoardConnection) async {
        do {
            _ = try await connection.command(.wifiClearHotspotCredentials)
            KeychainStore.delete(account: hotspotName.trimmingCharacters(in: .whitespacesAndNewlines))
            hotspotPassword = ""
            hotspotPasswordIsSaved = false
            hotspotProvisionStage = .idle
        } catch {
            lastErrorMessage = String(describing: error)
        }
    }

    // MARK: On-board Wi-Fi management

    public func setMode(_ mode: String, connection: BoardConnection) async {
        do { _ = try await connection.command(.wifiSetMode(mode: mode)) }
        catch { lastErrorMessage = String(describing: error) }
    }

    public func scanNetworks(connection: BoardConnection) async {
        isScanningNetworks = true
        defer { isScanningNetworks = false }
        do {
            let reply = try await connection.wifiScan()
            wifiNetworks = reply.networks ?? []
        } catch {
            lastErrorMessage = String(describing: error)
        }
    }

    public func connectNetwork(ssid: String, password: String, connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            homeProvisionStage = .failed(NSLocalizedString("请先通过蓝牙或其他方式连接璃奈板", comment: "connect board before Wi-Fi provisioning"))
            return
        }
        homeProvisionStage = .sendingCredentials
        let (subID, stream) = connection.subscribeToEvents()
        defer { connection.unsubscribe(subID) }
        do {
            _ = try await connection.command(.wifiSetCredentials(ssid: ssid, password: password))
            _ = try await connection.command(.wifiSetMode(mode: "sta_or_ap"))
            _ = try await connection.command(.wifiConnect)
            homeProvisionStage = .waitingForBoard

            let associated = await waitForAssociation(
                in: stream, profile: "home", expectedSSID: ssid) != nil
            if associated {
                homeProvisionStage = .boardJoined
            } else {
                homeProvisionStage = .failed(NSLocalizedString(
                    "板子未能加入这个网络，请检查密码和信号后重试。",
                    comment: "board failed to join home Wi-Fi"
                ))
            }
        } catch {
            homeProvisionStage = .failed(error.localizedDescription)
        }
    }

    public func forgetNetwork(connection: BoardConnection) async {
        do { _ = try await connection.command(.wifiClearCredentials) }
        catch { lastErrorMessage = String(describing: error) }
    }

    public func setAp(ssid: String, password: String, connection: BoardConnection, boardStore: BoardStore) async {
        do {
            let reply = try await connection.command(.wifiSetAp(ssid: ssid, password: password))
            guard reply.ok else { return }
            applyRenamedAp(ssid, connection: connection, boardStore: boardStore)
        } catch { lastErrorMessage = String(describing: error) }
    }

    /// After a successful `wifi_set_ap` on a hotspot-connected session, the
    /// board's own SoftAP SSID just changed under us: keep this session's
    /// `expectedHotspotSSID` (RINALINK_PROTOCOL_V1 "Board identity") and the
    /// saved `KnownBoard` record for it in sync, rather than letting the next
    /// identity check or reconnect attempt see a stale expectation. Only runs
    /// when we can be reasonably sure this is still the same board (its
    /// reported `boardId`, if any, still matches the id embedded in the
    /// *previous* expected SSID) so a race with an unrelated board can't
    /// smear its record onto this one.
    private func applyRenamedAp(_ newSSID: String, connection: BoardConnection, boardStore: BoardStore) {
        guard connection.transportKind == .hotspot else { return }
        let oldSSID = connection.expectedHotspotSSID
        if let boardId = connection.boardIdentity,
           let oldSSID, let expectedID = BoardIdentity.boardID(fromAPSSID: oldSSID),
           boardId.uppercased() != expectedID {
            return
        }
        connection.expectedHotspotSSID = newSSID
        guard let oldSSID else { return }
        let oldID = KnownBoard.hotspotStorageID(ssid: oldSSID)
        guard let existing = boardStore.boards.first(where: { $0.id == oldID }) else { return }
        boardStore.remove(id: oldID)
        boardStore.upsert(KnownBoard(
            id: KnownBoard.hotspotStorageID(ssid: newSSID),
            name: existing.name,
            preferredTransport: "hotspot",
            lastHost: existing.lastHost,
            hotspotSSID: newSSID,
            lastSeen: existing.lastSeen
        ))
    }

    /// Waits for the board to report that it actually associated with
    /// `expectedSSID` on `profile`, and returns the matching status (its `ip`
    /// belongs to that association, unlike a later read of `connection.wifi`).
    ///
    /// Matching the profile alone is not enough. `wifiManagerSetHotspotCredentials`
    /// / `wifiManagerSetCredentials` only *start* an async scan
    /// (`startStaSelection` in `esp32s3_firmware/src/wifi_manager.cpp`) while the
    /// previous association stays up, so the first `EV_WIFI` after the commands
    /// normally still describes the OLD network under the same profile — a stale
    /// match reports success, and persists credentials, for a network the board
    /// never joined. `WifiStatus.ssid` is the associated SSID and is the only
    /// field that distinguishes them; `hotspotSsid`/`homeSsid` are updated by the
    /// set-credentials command itself and must not be used here. Firmware that
    /// does not report `ssid` at all falls back to the profile-only match so
    /// older boards keep provisioning as before.
    ///
    /// Internal rather than private so `ConnectionProvisioningTests` can pin the
    /// stale-association predicate without driving a real TCP connect.
    func waitForAssociation(
        in stream: AsyncStream<BoardEvent>,
        profile: String,
        expectedSSID: String
    ) async -> WifiStatus? {
        await withTaskGroup(of: WifiStatus?.self) { group in
            group.addTask {
                for await event in stream {
                    guard case .wifi(let status) = event,
                          status.staConnected == true,
                          status.activeProfile == profile
                    else { continue }
                    if let reported = status.ssid, !reported.isEmpty, reported != expectedSSID {
                        continue
                    }
                    return status
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
