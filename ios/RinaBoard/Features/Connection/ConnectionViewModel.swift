import Foundation
import RinaCore
#if canImport(UIKit)
import UIKit
#endif

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

    // MARK: iPhone Personal Hotspot profile (RINALINK_PROTOCOL_V1 §8)

    /// Pre-filled from `UIDevice.current.name`; iOS 16+ may return a generic
    /// "iPhone" instead of the user-set device name, so this field stays
    /// editable rather than read-only.
    public var hotspotName: String
    /// The Personal Hotspot password iOS never exposes to apps — typed once,
    /// then remembered in the Keychain (`KeychainStore`), keyed by SSID.
    public var hotspotPassword: String = ""
    public private(set) var isProvisioningHotspot = false
    public var hotspotStatusText: String?

    public init() {
        bonjour.start()
        #if canImport(UIKit)
        hotspotName = UIDevice.current.name
        #else
        hotspotName = ""
        #endif
        hotspotPassword = KeychainStore.load(account: hotspotName) ?? ""
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
        // `board.name` is a Bonjour service name, not a hostname — never use
        // it as a connection target. Callers should disable this row in the
        // UI until `board.isResolved` (endpoint or host present).
        guard board.isResolved else {
            lastErrorMessage = "尚未解析主机地址"
            return
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
            lastErrorMessage = "尚未解析主机地址"
            return
        }
        await connection.connect(using: transport)
        guard connection.connectionState == .connected else {
            lastErrorMessage = "连接失败"
            return
        }
        boardStore.upsert(KnownBoard(id: displayHost, name: board.name, preferredTransport: "wifi",
                                      lastHost: board.host, lastSeen: Date()))
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

    // MARK: iPhone Personal Hotspot provisioning (RINALINK_PROTOCOL_V1 §8)

    /// Provisions the board with this phone's Personal Hotspot credentials
    /// over the active connection (BLE, or any other transport that's up),
    /// switches the board to `sta_or_ap`, tells it to connect, and waits for
    /// `EV_WIFI` to report it joined the `hotspot` profile — then opens TCP
    /// to the reported IP and remembers `hotspot-tcp` as this board's
    /// preferred transport.
    public func provisionPhoneHotspot(connection: BoardConnection, boardStore: BoardStore) async {
        guard connection.connectionState == .connected else {
            lastErrorMessage = "请先连接璃奈板"
            return
        }
        let ssid = hotspotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            lastErrorMessage = "请输入热点名称"
            return
        }
        let password = hotspotPassword
        isProvisioningHotspot = true
        hotspotStatusText = "等待板子加入热点…"
        defer {
            isProvisioningHotspot = false
        }
        let (subID, stream) = connection.subscribeToEvents()
        defer { connection.unsubscribe(subID) }
        do {
            _ = try await connection.command(.wifiSetHotspotCredentials(ssid: ssid, password: password))
            KeychainStore.save(password: password, account: ssid)
            _ = try await connection.command(.wifiSetMode(mode: "sta_or_ap"))
            _ = try await connection.command(.wifiConnect)

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
                hotspotStatusText = "未能加入热点，请确认「个人热点」已开启且「允许其他人加入」/「与其他设备保持兼容」已打开"
                return
            }

            let transport = TCPTransport(host: ip, kind: .wifi(host: ip, port: RinaLinkConstants.tcpPort))
            await connection.connect(using: transport)
            guard connection.connectionState == .connected else {
                hotspotStatusText = "已加入热点，但连接失败"
                return
            }
            boardStore.upsert(KnownBoard(id: ip, name: ssid, preferredTransport: "hotspot-tcp", lastHost: ip, lastSeen: Date()))
            hotspotStatusText = "已连接到板子（手机热点）"
        } catch {
            hotspotStatusText = nil
            lastErrorMessage = String(describing: error)
        }
    }

    /// Clears the board's stored hotspot credentials and the locally cached
    /// Keychain password.
    public func clearPhoneHotspot(connection: BoardConnection) async {
        do {
            _ = try await connection.command(.wifiClearHotspotCredentials)
            KeychainStore.delete(account: hotspotName.trimmingCharacters(in: .whitespacesAndNewlines))
            hotspotPassword = ""
            hotspotStatusText = nil
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
