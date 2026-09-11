import Foundation
import RinaCore

/// Drives the Connection tab (FEATURE_INVENTORY §E): BLE scan/connect, home
/// Wi-Fi discovery via Bonjour + manual host, hotspot join, and on-board
/// Wi-Fi provisioning (`wifi_*` commands over whatever transport is active).
@Observable
@MainActor
public final class ConnectionViewModel {
    public let bonjour = BonjourBrowser()

    public private(set) var isScanningBLE = false
    public private(set) var isJoiningHotspot = false
    public private(set) var isScanningNetworks = false
    public var manualHost: String = ""
    public var lastErrorMessage: String?

    public var wifiNetworks: [WifiNetwork] = []

    public init() {
        bonjour.start()
    }

    deinit {
        let bonjour = bonjour
        Task { @MainActor in bonjour.stop() }
    }

    // MARK: BLE

    public func toggleBLEScan(ble: BLETransport) {
        isScanningBLE.toggle()
        if isScanningBLE {
            ble.startScan()
            // Surface an error instead of silently no-oping (e.g. Bluetooth off).
            if let error = ble.lastError {
                lastErrorMessage = error
                isScanningBLE = false
            }
        } else {
            ble.stopScan()
        }
    }

    public func connectBLE(_ peripheral: DiscoveredPeripheral, ble: BLETransport, connection: BoardConnection, boardStore: BoardStore) async {
        ble.stopScan()
        isScanningBLE = false
        ble.peripheralIdentifier = peripheral.id
        await connection.connect(using: ble)
        guard connection.connectionState == .connected else {
            lastErrorMessage = "连接失败"
            return
        }
        boardStore.upsert(KnownBoard(id: peripheral.id.uuidString, name: peripheral.name,
                                      preferredTransport: "bluetooth", lastSeen: Date()))
    }

    // MARK: Home Wi-Fi (Bonjour / manual)

    public func connectBonjour(_ board: DiscoveredBoard, connection: BoardConnection, boardStore: BoardStore) async {
        let host = board.host ?? board.name
        let port = board.port ?? RinaLinkConstants.tcpPort
        let transport: TCPTransport
        if let endpoint = board.endpoint {
            // H4: connect directly via the resolved endpoint, no manual resolve needed.
            transport = TCPTransport(endpoint: endpoint, kind: .wifi(host: host, port: port))
        } else {
            transport = TCPTransport(host: host, port: port, kind: .wifi(host: host, port: port))
        }
        await connection.connect(using: transport)
        guard connection.connectionState == .connected else {
            lastErrorMessage = "连接失败"
            return
        }
        boardStore.upsert(KnownBoard(id: host, name: board.name, preferredTransport: "wifi",
                                      lastHost: host, lastSeen: Date()))
    }

    public func connectManualHost(connection: BoardConnection, boardStore: BoardStore) async {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        let transport = TCPTransport(host: host)
        await connection.connect(using: transport)
        guard connection.connectionState == .connected else {
            lastErrorMessage = "连接失败"
            return
        }
        boardStore.upsert(KnownBoard(id: host, name: host, preferredTransport: "wifi",
                                      lastHost: host, lastSeen: Date()))
    }

    // MARK: Hotspot ("direct")

    public func connectHotspot(connection: BoardConnection, boardStore: BoardStore) async {
        isJoiningHotspot = true
        defer { isJoiningHotspot = false }
        do {
            try await HotspotJoiner.join()
            let transport = HotspotJoiner.makeTransport()
            await connection.connect(using: transport)
            guard connection.connectionState == .connected else {
                lastErrorMessage = "连接失败"
                return
            }
            boardStore.upsert(KnownBoard(id: RinaLinkConstants.apIP, name: RinaLinkConstants.apSSID,
                                          preferredTransport: "hotspot", lastHost: RinaLinkConstants.apIP, lastSeen: Date()))
        } catch {
            lastErrorMessage = String(describing: error)
        }
    }

    /// After provisioning STA over BLE, switch the active connection to TCP
    /// at the board's reported IP.
    public func switchToWifi(connection: BoardConnection, boardStore: BoardStore) async {
        guard let ip = connection.wifi?.ip, !ip.isEmpty else { return }
        let transport = TCPTransport(host: ip)
        await connection.connect(using: transport)
        guard connection.connectionState == .connected else {
            lastErrorMessage = "切换失败"
            return
        }
        if let ssid = connection.wifi?.ssid {
            boardStore.upsert(KnownBoard(id: ip, name: ssid, preferredTransport: "wifi", lastHost: ip, lastSeen: Date()))
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
        do {
            _ = try await connection.command(.wifiSetCredentials(ssid: ssid, password: password))
            _ = try await connection.command(.wifiSetMode(mode: "sta_or_ap"))
            _ = try await connection.command(.wifiConnect)
        } catch {
            lastErrorMessage = String(describing: error)
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
}
