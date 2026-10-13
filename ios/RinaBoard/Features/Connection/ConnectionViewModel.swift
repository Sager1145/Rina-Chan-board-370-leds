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
    public private(set) var isSwitchingTransport = false
    public private(set) var isApplyingWifiMode = false
    public var manualHost: String = ""
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

    public private(set) var directAPStage: DirectAPStage = .idle
    public private(set) var homeProvisionStage: ProvisionStage = .idle

    public init(startBonjourBrowsing: Bool = true) {
        // Signposts for PR-14 measurement: `RootTabView`'s `reconnectModel`
        // constructs this with `startBonjourBrowsing: false`, so only the
        // Keychain read below runs synchronously on the main actor at
        // launch; `bonjour.start()` runs later, from `ConnectionView` and
        // `BoardControlCenterView`, when browsing is actually needed.
        if startBonjourBrowsing {
            let state = RinaPerf.signposter.beginInterval("ConnectionInit.bonjourStart")
            #if DEBUG || RINA_PERF_LOG
            let bonjourStart = ContinuousClock.now
            bonjour.start()
            LaunchTiming.record(name: "ConnectionInit.bonjourStart", milliseconds: LaunchTiming.ms(ContinuousClock.now - bonjourStart))
            #else
            bonjour.start()
            #endif
            RinaPerf.signposter.endInterval("ConnectionInit.bonjourStart", state)
        }
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
                    physicalBoardID: connection.boardIdentity,
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
                                      preferredTransport: "bluetooth", physicalBoardID: connection.boardIdentity,
                                      lastSeen: Date()))
        await refreshBoardName(connection: connection)
        await refreshSavedAPMetadata(connection: connection, boardStore: boardStore, savedID: boardID)
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
        await connectManualHost(connection: connection, boardStore: boardStore,
                                transportFactory: { TCPTransport(host: $0) })
    }

    func connectManualHost(
        connection: BoardConnection,
        boardStore: BoardStore,
        transportFactory: @MainActor (String) -> any RinaTransport
    ) async {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        guard !isConnectingHome else { return }
        isConnectingHome = true
        lastErrorMessage = nil
        defer { isConnectingHome = false }
        let transport = transportFactory(host)
        let connected = await connection.connect(using: transport)
        guard connected, connection.connectionState == .connected else {
            // A nil error identifies an intentional disconnect or a newer
            // connection superseding this attempt. Keep that outcome quiet.
            lastErrorMessage = connection.lastError
            return
        }
        boardStore.upsert(KnownBoard(id: host, name: connection.deviceName ?? host, preferredTransport: "wifi",
                                      lastHost: host, lastSeen: Date()))
    }

    // MARK: Hotspot ("direct")

    /// - Parameter disconnectOtherHotspotSessions: The phone can only associate with one board SoftAP at
    ///   a time. Called right before joining so any other session's hotspot
    ///   connection cannot later reconnect its TCP link onto *this* board once
    ///   the phone's Wi-Fi moves — the caller is expected to disconnect every
    ///   other `.hotspot` session it knows about.
    public func connectHotspot(sessions: BoardSessionStore, boardStore: BoardStore) async {
        await connectHotspot(
            sessions: sessions, boardStore: boardStore,
            joinBoardHotspot: { try await HotspotJoiner.join() },
            connectTransport: { session, transport in
                await session.connection.connect(using: transport,
                    expectedBoardIdentity: session.connection.boardIdentity
                        ?? session.connection.lastKnownBoardIdentity
                        ?? session.connection.expectedHotspotSSID.flatMap(BoardIdentity.boardID(fromAPSSID:)))
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
        do {
            let joinedSSID = try await joinBoardHotspot()
            directAPStage = .connectingToBoard
            let boardID = KnownBoard.hotspotStorageID(ssid: joinedSSID)
            let physicalID = BoardIdentity.boardID(fromAPSSID: joinedSSID)
            let known = boardStore.boards.first {
                $0.hotspotSSID == joinedSSID
                    || (physicalID != nil && $0.physicalBoardID == physicalID)
            }
            let target = sessions.existingSession(for: boardID)
                ?? known.map { sessions.session(for: $0.id, name: $0.name) }
                ?? sessions.session(for: boardID, name: joinedSSID)
            // One Wi-Fi interface can reach one board AP at a time. Once
            // association succeeds, retire other AP retry loops while keeping
            // BLE and Home Wi-Fi siblings available.
            for session in sessions.sessions where session !== target && session.connection.transportKind == .hotspot {
                session.connection.disconnect()
            }
            sessions.select(target)
            let connection = target.connection
            let identifiers = Set(target.knownIdentifiers)
            let savedID = boardStore.boards.first(where: { identifiers.contains($0.id) })?.id
                ?? target.boardID ?? boardID
            connection.expectedHotspotSSID = joinedSSID
            let host = hotspotHost(ssid: joinedSSID, connection: connection, known: known)
            let attempt = await connectHotspotGateway(ssid: joinedSSID, host: host, known: known,
                connection: connection, boardStore: boardStore,
                connectTransport: { await connectTransport(target, $0) })
            guard attempt.connected, connection.connectionState == .connected else {
                let message = connection.lastError ?? NSLocalizedString("已连接璃奈板热点，但未能建立控制连接", comment: "direct AP control connection failed")
                directAPStage = .failed(message)
                return
            }
            sessions.consolidateVerifiedSession(target)
            boardStore.upsert(KnownBoard(
                id: savedID,
                name: connection.deviceName ?? joinedSSID,
                preferredTransport: "hotspot",
                lastHost: known?.lastHostForHomeWifi,
                hotspotSSID: joinedSSID,
                hotspotIP: connection.wifi?.apIp.flatMap(BoardAPAddress.canonicalPrivateAddress) ?? attempt.host,
                physicalBoardID: connection.boardIdentity,
                lastSeen: Date()
            ))
            await refreshSavedAPMetadata(connection: connection, boardStore: boardStore, savedID: savedID)
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

    // MARK: Selected board transport

    public enum TransportSelection: String, Hashable {
        case bluetooth, wifi, hotspot
    }

    public func selectedTransport(for session: BoardSession) -> TransportSelection {
        switch session.connection.transportKind {
        case .bluetooth: .bluetooth
        case .wifi: .wifi
        case .hotspot: .hotspot
        case nil: .bluetooth
        }
    }

    public func canSelectTransport(_ selection: TransportSelection, session: BoardSession,
                                   boardStore: BoardStore) -> Bool {
        switch selection {
        case .bluetooth: bluetoothIdentifier(for: session) != nil
        case .wifi: wifiHost(for: session, boardStore: boardStore) != nil
        case .hotspot: selectedAPSSID(for: session, boardStore: boardStore) != nil
        }
    }

    public func selectTransport(_ selection: TransportSelection, session: BoardSession? = nil, sessions: BoardSessionStore,
                                boardStore: BoardStore) async {
        await selectTransport(selection, session: session, sessions: sessions, boardStore: boardStore,
                              connectTransport: { session, transport, expectedIdentity in
            await session.connection.connect(using: transport, expectedBoardIdentity: expectedIdentity)
        })
    }

    func selectTransport(
        _ selection: TransportSelection,
        session: BoardSession? = nil,
        sessions: BoardSessionStore,
        boardStore: BoardStore,
        joinBoardHotspot: @escaping @MainActor (String) async throws -> String = { try await HotspotJoiner.join(ssid: $0) },
        connectTransport: @escaping @MainActor (BoardSession, any RinaTransport, String?) async -> Bool
    ) async {
        guard !isSwitchingTransport else { return }
        let target = session ?? sessions.active
        guard sessions.sessions.contains(where: { $0 === target }) else { return }
        guard let fallbackID = target.boardID else { return }
        if target.connection.connectionState == .connected, selectedTransport(for: target) == selection { return }
        // Read the old carrier before connecting clears it, retaining its
        // identity for saved-board lookup and forgetting after a switch.
        let oldIdentifiers = Set(target.knownIdentifiers)
        let known = boardStore.boards.first { oldIdentifiers.contains($0.id) }
        let expectedIdentity = target.connection.boardIdentity ?? target.connection.lastKnownBoardIdentity
            ?? known?.physicalBoardID ?? known?.hotspotSSID.flatMap(BoardIdentity.boardID(fromAPSSID:))
        let bluetoothID = bluetoothIdentifier(for: target)
        let name = target.connection.deviceName ?? target.name
        let host = wifiHost(for: target, boardStore: boardStore)
        let transport: any RinaTransport
        var joinedAPSSID: String?
        var joinedAPHost: String?
        isSwitchingTransport = true
        lastErrorMessage = nil
        defer { isSwitchingTransport = false }
        switch selection {
        case .bluetooth:
            guard let bluetoothID else {
                lastErrorMessage = NSLocalizedString("请先在添加璃奈板中扫描并连接这块板的蓝牙", comment: "selected board missing BLE address")
                return
            }
            target.bleTransport.peripheralIdentifier = bluetoothID
            transport = target.bleTransport
        case .wifi:
            guard let host else {
                lastErrorMessage = NSLocalizedString("请先在 Wi-Fi 与热点中选择扫描到的网络，让板子加入 Wi-Fi", comment: "selected board missing Wi-Fi address")
                return
            }
            transport = TCPTransport(host: host)
        case .hotspot:
            guard let ssid = selectedAPSSID(for: target, boardStore: boardStore) else {
                lastErrorMessage = NSLocalizedString("请先通过蓝牙连接这块板，读取热点设置", comment: "selected board missing AP address")
                return
            }
            do {
                let joined = try await joinBoardHotspot(ssid)
                guard !Task.isCancelled, sessions.sessions.contains(where: { $0 === target }) else { return }
                guard joined == ssid else {
                    lastErrorMessage = NSLocalizedString("连接地址对应另一块璃奈板，已停止连接", comment: "joined wrong selected hotspot")
                    return
                }
                for other in sessions.sessions where other !== target && other.connection.transportKind == .hotspot {
                    other.connection.disconnect()
                }
                target.connection.expectedHotspotSSID = joined
                let apHost = hotspotHost(ssid: joined, connection: target.connection, known: known)
                joinedAPSSID = joined
                joinedAPHost = apHost
                transport = HotspotJoiner.makeTransport(host: apHost)
            } catch {
                if sessions.active === target { lastErrorMessage = error.localizedDescription }
                return
            }
        }
        let connected: Bool
        if let joinedAPSSID, let host = joinedAPHost {
            let attempt = await connectHotspotGateway(ssid: joinedAPSSID, host: host, known: known,
                connection: target.connection, boardStore: boardStore,
                connectTransport: { await connectTransport(target, $0, expectedIdentity) })
            connected = attempt.connected
            joinedAPHost = attempt.host
        } else {
            connected = await connectTransport(target, transport, expectedIdentity)
        }
        guard connected, target.connection.connectionState == .connected else {
            if sessions.active === target { lastErrorMessage = target.connection.lastError }
            return
        }
        // The user's selection can change while this board connects. Keep its
        // own carrier, but never select it over the board the user chose next.
        guard sessions.sessions.contains(where: { $0 === target }) else { return }
        sessions.consolidateVerifiedSession(target)
        let id = bluetoothID?.uuidString ?? fallbackID
        var saved = boardStore.boards.first { $0.id == id }
            ?? boardStore.boards.first { oldIdentifiers.contains($0.id) }
            ?? KnownBoard(id: id, name: name)
        saved.id = id
        let savedHomeHost = saved.lastHostForHomeWifi
        saved.name = target.connection.deviceName ?? name
        saved.preferredTransport = selection.rawValue
        saved.physicalBoardID = target.connection.boardIdentity
        if selection == .wifi { saved.lastHost = host }
        if selection == .hotspot {
            saved.lastHost = savedHomeHost
            saved.hotspotSSID = joinedAPSSID
            saved.hotspotIP = target.connection.wifi?.apIp.flatMap(BoardAPAddress.canonicalPrivateAddress) ?? joinedAPHost
        }
        saved.lastSeen = Date()
        boardStore.upsert(saved)
        await refreshSavedAPMetadata(connection: target.connection, boardStore: boardStore, savedID: id)
        // Register the successful Wi-Fi spelling against the same session.
        _ = target.knownIdentifiers
    }

    private func selectedAPSSID(for session: BoardSession, boardStore: BoardStore) -> String? {
        let identifiers = Set(session.knownIdentifiers)
        let ssid = session.connection.wifi?.apSsid ?? session.connection.expectedHotspotSSID
            ?? boardStore.boards.first(where: { identifiers.contains($0.id) })?.hotspotSSID
        return ssid.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func bluetoothIdentifier(for session: BoardSession) -> UUID? {
        session.bleTransport.peripheralIdentifier
            ?? session.knownIdentifiers.compactMap(UUID.init(uuidString:)).first
    }

    private func wifiHost(for session: BoardSession, boardStore: BoardStore) -> String? {
        if session.connection.wifi?.staConnected == true,
           let ip = session.connection.wifi?.ip, !ip.isEmpty { return ip }
        if case .wifi(let host, _) = session.connection.transportKind { return host }
        let identifiers = Set(session.knownIdentifiers)
        return boardStore.boards.filter {
            identifiers.contains($0.id)
        }
            .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            .compactMap(\.lastHostForHomeWifi).first
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
                await session.connection.connect(using: transport,
                    expectedBoardIdentity: board.physicalBoardID
                        ?? board.hotspotSSID.flatMap(BoardIdentity.boardID(fromAPSSID:))
                        ?? session.connection.boardIdentity ?? session.connection.lastKnownBoardIdentity)
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
        sessions.consolidateVerifiedSession(target)
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
            connectTransport: { transport in
                await connection.connect(using: transport, expectedBoardIdentity: board.physicalBoardID
                    ?? board.hotspotSSID.flatMap(BoardIdentity.boardID(fromAPSSID:)))
            },
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
        var dialedHotspotHost: String?
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
        case .boardHotspot(_, let ssid):
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
            if let ssid, ssid != joinedSSID {
                lastErrorMessage = NSLocalizedString("连接地址对应另一块璃奈板，已停止连接", comment: "joined wrong saved hotspot")
                return
            }
            if board.hotspotSSID == nil { migratedHotspotSSID = joinedSSID }
            connection.expectedHotspotSSID = joinedSSID
            // Prefix association may have landed on another known board; read
            // that board's gateway only after the actual SSID is known.
            let joinedKnown = boardStore.boards.first { $0.hotspotSSID == joinedSSID }
            let actualHost = hotspotHost(ssid: joinedSSID, connection: connection,
                known: ssid == nil ? joinedKnown : board)
            let attempt = await connectHotspotGateway(ssid: joinedSSID, host: actualHost,
                known: ssid == nil ? joinedKnown : board, connection: connection, boardStore: boardStore,
                connectTransport: { await connectTransport($0) })
            dialedHotspotHost = attempt.host
            connected = attempt.connected
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
        if let dialedHotspotHost {
            refreshed.hotspotIP = connection.wifi?.apIp.flatMap(BoardAPAddress.canonicalPrivateAddress) ?? dialedHotspotHost
            refreshed.lastHost = board.lastHostForHomeWifi
        }
        refreshed.name = connection.deviceName ?? board.name
        refreshed.physicalBoardID = connection.boardIdentity ?? board.physicalBoardID
        if updateLastSeen { refreshed.lastSeen = Date() }
        boardStore.upsert(refreshed)
        await refreshBoardName(connection: connection)
        await refreshSavedAPMetadata(connection: connection, boardStore: boardStore, savedID: refreshed.id)
    }

    /// One upgrade attempt shared by direct, saved, and selected-board AP dials.
    /// Older rows stored a factory gateway in lastHost; explicit AP overrides
    /// never fall back, and cancelled/forgotten attempts stop immediately.
    private func connectHotspotGateway(ssid: String, host: String, known: KnownBoard?,
                                       connection: BoardConnection, boardStore: BoardStore,
                                       connectTransport: @MainActor (TCPTransport) async -> Bool) async -> (connected: Bool, host: String) {
        let connected = await connectTransport(HotspotJoiner.makeTransport(host: host))
        guard !connected, !Task.isCancelled, connection.lastError != nil,
              let known, known.hotspotIP == nil, host == known.lastHost,
              boardStore.boards.contains(where: { $0.id == known.id }),
              let identity = BoardIdentity.boardID(fromAPSSID: ssid),
              let factoryHost = BoardAPAddress.defaultAddress(boardID: identity),
              factoryHost != host else { return (connected, host) }
        return (await connectTransport(HotspotJoiner.makeTransport(host: factoryHost)), factoryHost)
    }

    /// The caller must resolve the joined board's session first. A selected
    /// sibling's previous status is never a source for this gateway.
    private func hotspotHost(ssid: String, connection: BoardConnection, known: KnownBoard?) -> String {
        let expectedID = known?.physicalBoardID ?? BoardIdentity.boardID(fromAPSSID: ssid)
        let liveID = connection.boardIdentity ?? connection.lastKnownBoardIdentity
        if let liveID, let expectedID, liveID.uppercased() == expectedID.uppercased(),
           let host = connection.wifi?.apIp.flatMap(BoardAPAddress.canonicalPrivateAddress) { return host }
        if let host = known?.resolvedHotspotIP { return host }
        return BoardIdentity.boardID(fromAPSSID: ssid)
            .flatMap { BoardAPAddress.defaultAddress(boardID: $0) } ?? RinaLinkConstants.apIP
    }

    /// Capture configured AP metadata even while BLE is the preferred carrier.
    /// Router Wi-Fi and AP addresses have separate persistence lifetimes.
    private func refreshSavedAPMetadata(connection: BoardConnection, boardStore: BoardStore,
                                        savedID: String) async {
        let generation = connection.connectionGeneration
        let previous = connection.wifi
        let refreshed = try? await connection.refreshWifiStatus()
        guard connection.connectionGeneration == generation,
              connection.connectionState == .connected else { return }
        let identity = connection.boardIdentity
        guard var board = boardStore.boards.first(where: { $0.id == savedID })
                ?? boardStore.boards.first(where: {
                    identity != nil && $0.physicalBoardID?.uppercased() == identity?.uppercased()
                }) else { return }
        let reported = refreshed?.apIp == nil ? previous : refreshed
        if let reportedID = reported?.boardId, let identity,
           reportedID.uppercased() != identity.uppercased() { return }
        board.hotspotIP = reported?.apIp.flatMap(BoardAPAddress.canonicalPrivateAddress) ?? board.hotspotIP
        board.hotspotSSID = reported?.apSsid ?? board.hotspotSSID
        board.physicalBoardID = identity ?? board.physicalBoardID
        if reported?.staConnected == true, let host = reported?.ip, !host.isEmpty { board.lastHost = host }
        boardStore.upsert(board)
    }

    // MARK: On-board Wi-Fi management

    public func setMode(_ mode: String, connection: BoardConnection) async {
        guard !isApplyingWifiMode else { return }
        isApplyingWifiMode = true
        defer { isApplyingWifiMode = false }
        do {
            _ = try await connection.command(.wifiSetMode(mode: mode))
            _ = try await connection.refreshWifiStatus()
        }
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

    @discardableResult
    public func setAp(ssid: String, password: String, ip: String? = nil,
                      connection: BoardConnection, boardStore: BoardStore) async -> Bool {
        lastErrorMessage = nil
        let canonicalIP: String?
        if let ip {
            guard let canonical = BoardAPAddress.canonicalPrivateAddress(ip) else {
                lastErrorMessage = NSLocalizedString("请输入有效的私有 IPv4 地址，末位需为 1–254", comment: "invalid AP IP")
                return false
            }
            let identity = connection.boardIdentity ?? connection.lastKnownBoardIdentity
            let currentSSID = connection.wifi?.apSsid ?? connection.expectedHotspotSSID
            let conflicts = boardStore.boards.contains { board in
                let savedIdentity = board.physicalBoardID ?? board.hotspotSSID.flatMap(BoardIdentity.boardID(fromAPSSID:))
                let sameBoard = identity != nil && savedIdentity?.uppercased() == identity?.uppercased()
                let sameSSID = currentSSID != nil && board.hotspotSSID == currentSSID
                    && (identity == nil || savedIdentity == nil)
                return !sameBoard && !sameSSID && board.resolvedHotspotIP == canonical
            }
            guard !conflicts else {
                lastErrorMessage = NSLocalizedString("此热点 IP 已被另一块已保存的璃奈板使用", comment: "AP IP conflicts with sibling")
                return false
            }
            canonicalIP = canonical
        } else { canonicalIP = nil }
        let generation = connection.connectionGeneration
        let previousSSID = connection.expectedHotspotSSID ?? connection.wifi?.apSsid
        do {
            let reply = try await connection.command(.wifiSetAp(ssid: ssid, password: password, ip: canonicalIP))
            guard connection.connectionGeneration == generation else { return false }
            guard reply.ok else {
                lastErrorMessage = reply.error ?? NSLocalizedString("热点设置未能保存", comment: "AP settings rejected")
                return false
            }
            if !ssid.isEmpty, connection.transportKind == .hotspot { connection.expectedHotspotSSID = ssid }
            let reported = try await connection.refreshWifiStatus()
            guard connection.connectionGeneration == generation else { return false }
            if let canonicalIP, reported.apIp.flatMap(BoardAPAddress.canonicalPrivateAddress) != canonicalIP {
                lastErrorMessage = NSLocalizedString("未能确认热点 IP 已保存，请重新读取后重试", comment: "AP IP save not verified")
                return false
            }
            let identity = connection.boardIdentity
            if let reportedID = reported.boardId, let identity,
               reportedID.uppercased() != identity.uppercased() {
                lastErrorMessage = NSLocalizedString("连接地址对应另一块璃奈板，已停止连接", comment: "AP settings board identity mismatch")
                return false
            }
            let identifiedBoard = identity.flatMap { physicalID in
                boardStore.boards.first { board in
                    let savedIdentity = board.physicalBoardID ?? board.hotspotSSID.flatMap(BoardIdentity.boardID(fromAPSSID:))
                    return savedIdentity?.uppercased() == physicalID.uppercased()
                }
            }
            let ssidCandidates = boardStore.boards.filter { board in
                guard previousSSID != nil, board.hotspotSSID == previousSSID else { return false }
                let savedIdentity = board.physicalBoardID ?? board.hotspotSSID.flatMap(BoardIdentity.boardID(fromAPSSID:))
                // An SSID alone cannot override a known different identity.
                return identity == nil || savedIdentity == nil
            }
            if var saved = identifiedBoard ?? (ssidCandidates.count == 1 ? ssidCandidates.first : nil) {
                let newSSID = reported.apSsid ?? (ssid.isEmpty ? saved.hotspotSSID : ssid)
                if saved.id.hasPrefix("hotspot:"), let newSSID, newSSID != saved.hotspotSSID {
                    boardStore.remove(id: saved.id)
                    saved.id = KnownBoard.hotspotStorageID(ssid: newSSID)
                }
                saved.hotspotSSID = newSSID
                saved.hotspotIP = reported.apIp.flatMap(BoardAPAddress.canonicalPrivateAddress) ?? canonicalIP ?? saved.hotspotIP
                saved.physicalBoardID = identity ?? saved.physicalBoardID
                boardStore.upsert(saved)
            }
            return true
        } catch {
            guard connection.connectionGeneration == generation else { return false }
            lastErrorMessage = error.localizedDescription
            return false
        }
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
