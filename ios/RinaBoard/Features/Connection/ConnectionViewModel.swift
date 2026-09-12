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

    public init() {
        bonjour.start()
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

    public func toggleBLEScan(ble: BLETransport) {
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

    public func connectBLE(_ peripheral: DiscoveredPeripheral, ble: BLETransport, connection: BoardConnection, boardStore: BoardStore) async {
        guard !isConnectingBLE else { return }
        isConnectingBLE = true
        defer { isConnectingBLE = false }

        ble.stopScan()
        lastErrorMessage = nil
        ble.peripheralIdentifier = peripheral.id
        let connected = await connection.connect(using: ble)
        guard connected, ble.connectedPeripheralID == peripheral.id else {
            // Prefer the transport's own reason ("蓝牙已关闭…", a connect
            // timeout) over a generic failure the user cannot act on.
            lastErrorMessage = ble.lastError ?? connection.lastError ?? NSLocalizedString("连接失败", comment: "board connection failed")
            return
        }
        boardStore.upsert(KnownBoard(id: peripheral.id.uuidString, name: peripheral.name,
                                      preferredTransport: "bluetooth", lastSeen: Date()))
        await refreshBoardName(connection: connection)
    }

    // MARK: Board name

    /// Seeds the rename field from the connected board. Silent on failure: an
    /// older firmware simply has no name to report and the field stays empty.
    public func refreshBoardName(connection: BoardConnection) async {
        guard let reply = try? await connection.command(.getInfo) else { return }
        boardDefaultName = reply.defaultName
        boardHasCustomName = reply.customName ?? false
        if let name = reply.name, !name.isEmpty {
            boardNameInput = name
        }
    }

    /// Renames the board. An empty name clears the override and restores the
    /// MAC-derived default, which is the only way back from a bad name.
    public func renameBoard(connection: BoardConnection, boardStore: BoardStore, ble: BLETransport) async {
        let requested = boardNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceNameValidator.validateDeviceName(requested) {
        case .tooLong(let bytes):
            // Byte count, not character count: CJK costs 3 bytes per character
            // and the BLE scan response has a hard 31-byte payload.
            lastErrorMessage = String(
                format: NSLocalizedString(
                    "名称过长（%1$lld 字节，上限 %2$lld 字节，中文约 8 个字）",
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
            if let id = ble.connectedPeripheralID?.uuidString,
               var known = boardStore.boards.first(where: { $0.id == id }) {
                known.name = effective
                known.lastSeen = Date()
                boardStore.upsert(known)
            }
            ble.updateConnectedPeripheralName(effective)
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
        let transport: TCPTransport
        if let endpoint = board.endpoint {
            transport = TCPTransport(endpoint: endpoint, kind: .wifi(host: displayHost, port: port))
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
        boardStore.upsert(KnownBoard(id: displayHost, name: board.name, preferredTransport: "wifi",
                                      lastHost: board.host, lastSeen: Date()))
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
        boardStore.upsert(KnownBoard(id: host, name: host, preferredTransport: "wifi",
                                      lastHost: host, lastSeen: Date()))
    }

    // MARK: Hotspot ("direct")

    public func connectHotspot(connection: BoardConnection, boardStore: BoardStore) async {
        guard directAPStage != .joiningPhoneToBoardAP,
              directAPStage != .connectingToBoard else { return }
        directAPStage = .joiningPhoneToBoardAP
        lastErrorMessage = nil
        do {
            try await HotspotJoiner.join()
            directAPStage = .connectingToBoard
            let transport = HotspotJoiner.makeTransport()
            await connection.connect(using: transport)
            guard connection.connectionState == .connected else {
                let message = connection.lastError ?? NSLocalizedString("已加入板子热点，但未能连接璃奈板", comment: "direct AP control connection failed")
                directAPStage = .failed(message)
                return
            }
            boardStore.upsert(KnownBoard(id: RinaLinkConstants.apIP, name: RinaLinkConstants.apSSID,
                                          preferredTransport: "hotspot", lastHost: RinaLinkConstants.apIP, lastSeen: Date()))
            directAPStage = .connected
        } catch {
            directAPStage = .failed(error.localizedDescription)
        }
    }

    /// After provisioning STA over BLE, switch the active connection to TCP
    /// at the board's reported IP.
    public func switchToWifi(connection: BoardConnection, boardStore: BoardStore) async {
        guard let ip = connection.wifi?.ip, !ip.isEmpty else { return }
        homeProvisionStage = .connectingToBoard
        let transport = TCPTransport(host: ip)
        await connection.connect(using: transport)
        guard connection.connectionState == .connected else {
            let message = connection.lastError ?? NSLocalizedString("板子已接入 Wi-Fi，但 App 连接失败", comment: "TCP control connection failed")
            homeProvisionStage = .failed(message)
            return
        }
        if let ssid = connection.wifi?.ssid {
            boardStore.upsert(KnownBoard(id: ip, name: ssid, preferredTransport: "wifi", lastHost: ip, lastSeen: Date()))
        }
        homeProvisionStage = .connected
    }

    // MARK: Saved boards

    public func connectSavedBoard(_ board: KnownBoard, ble: BLETransport, connection: BoardConnection, boardStore: BoardStore) async {
        guard connectingSavedBoardID == nil else { return }
        connectingSavedBoardID = board.id
        lastErrorMessage = nil
        defer { connectingSavedBoardID = nil }

        let connected: Bool
        if board.preferredTransport == "bluetooth", let id = UUID(uuidString: board.id) {
            ble.peripheralIdentifier = id
            connected = await connection.connect(using: ble)
        } else if let host = board.lastHost {
            let kind: TransportKind = board.preferredTransport == "hotspot"
                ? .hotspot
                : .wifi(host: host, port: RinaLinkConstants.tcpPort)
            connected = await connection.connect(using: TCPTransport(host: host, kind: kind))
        } else {
            lastErrorMessage = NSLocalizedString("这个已保存设备没有可用的连接地址，请重新扫描", comment: "saved board missing address")
            return
        }

        guard connected else {
            if board.preferredTransport == "bluetooth" {
                lastErrorMessage = ble.lastError ?? connection.lastError ?? NSLocalizedString("连接失败，请重试", comment: "board connection retry")
            } else {
                lastErrorMessage = connection.lastError ?? NSLocalizedString("连接失败，请重试", comment: "board connection retry")
            }
            return
        }
        var refreshed = board
        refreshed.lastSeen = Date()
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

            let joined: Bool = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await event in stream {
                        if case .wifi(let status) = event,
                           status.staConnected == true, status.activeProfile == "hotspot" {
                            return true
                        }
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }

            guard joined, let ip = connection.wifi?.ip, !ip.isEmpty else {
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
            boardStore.upsert(KnownBoard(id: ip, name: ssid, preferredTransport: "hotspot-tcp", lastHost: ip, lastSeen: Date()))
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

            let associated = await waitForAssociation(in: stream, profile: "home")
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

    public func setAp(ssid: String, password: String, connection: BoardConnection) async {
        do { _ = try await connection.command(.wifiSetAp(ssid: ssid, password: password)) }
        catch { lastErrorMessage = String(describing: error) }
    }

    private func waitForAssociation(in stream: AsyncStream<BoardEvent>, profile: String) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream {
                    if case .wifi(let status) = event,
                       status.staConnected == true,
                       status.activeProfile == profile {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
