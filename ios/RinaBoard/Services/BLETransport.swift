import Foundation
import CoreBluetooth
import RinaCore

@Observable
public final class DiscoveredPeripheral: Identifiable {
    public let id: UUID
    public var name: String
    public var rssi: Int

    init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

/// Parsed contents of the INFO characteristic (`{"proto","device","fw","mtu","tcpPort"}`).
public struct BLEInfo: Codable, Equatable, Sendable {
    public let proto: Int?
    public let device: String?
    public let fw: String?
    public let mtu: Int?
    public let tcpPort: Int?
}

/// CoreBluetooth transport: scans for the RinaLink service UUID, connects,
/// discovers RX (write)/TX (notify)/INFO (read) characteristics, and slices
/// outgoing writes to the negotiated MTU.
@Observable
@MainActor
public final class BLETransport: NSObject, @MainActor RinaTransport, @unchecked Sendable {
    public let kind: TransportKind = .bluetooth

    public private(set) var discoveredPeripherals: [DiscoveredPeripheral] = []
    public private(set) var infoJSON: Data?
    public private(set) var bleInfo: BLEInfo?
    /// Surfaced instead of silently no-oping when e.g. Bluetooth is off.
    public var lastError: String?

    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var infoCharacteristic: CBCharacteristic?

    private let serviceCBUUID = CBUUID(string: RinaLinkConstants.serviceUUID)
    private let rxCBUUID = CBUUID(string: RinaLinkConstants.rxCharacteristicUUID)
    private let txCBUUID = CBUUID(string: RinaLinkConstants.txCharacteristicUUID)
    private let infoCBUUID = CBUUID(string: RinaLinkConstants.infoCharacteristicUUID)

    // MARK: Fan-out streams (C1)

    private var stateContinuations: [UUID: AsyncStream<TransportState>.Continuation] = [:]
    private var incomingContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    /// A specific peripheral to connect to, set before calling `connect()`.
    public var peripheralIdentifier: UUID?

    public var preferredChunkBytes: Int {
        let mtu = targetPeripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20
        return max(20, mtu)
    }

    // MARK: connect() continuation state (C2)

    private var poweredOnContinuation: CheckedContinuation<Void, Error>?
    private var poweredOnTimeoutTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeoutTask: Task<Void, Never>?

    // MARK: write back-pressure (H3)

    private var writeReadyContinuation: CheckedContinuation<Void, Never>?
    private var writeReadyTimeoutTask: Task<Void, Never>?

    override public init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    public func stateStream() -> AsyncStream<TransportState> {
        let id = UUID()
        return AsyncStream { continuation in
            self.stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func incomingStream() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { continuation in
            self.incomingContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.incomingContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func emitState(_ state: TransportState) {
        for continuation in stateContinuations.values { continuation.yield(state) }
    }

    private func emitIncoming(_ data: Data) {
        for continuation in incomingContinuations.values { continuation.yield(data) }
    }

    public func startScan() {
        guard centralManager.state == .poweredOn else {
            lastError = "蓝牙未开启或不可用"
            return
        }
        lastError = nil
        discoveredPeripherals.removeAll()
        centralManager.scanForPeripherals(withServices: [serviceCBUUID], options: nil)
    }

    public func stopScan() {
        centralManager.stopScan()
    }

    public func connect() async throws {
        emitState(.connecting)
        try await waitForPoweredOn()
        if let identifier = peripheralIdentifier,
           let known = centralManager.retrievePeripherals(withIdentifiers: [identifier]).first {
            targetPeripheral = known
        }
        guard let peripheral = targetPeripheral else {
            throw RinaTransportError.notConnected
        }
        peripheral.delegate = self

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectContinuation = continuation
            self.connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.centralManager.cancelPeripheralConnection(peripheral)
                self.resumeConnect(.failure(RinaTransportError.timeout))
            }
            centralManager.connect(peripheral, options: nil)
        }
    }

    /// A3: never overwrite a still-pending `poweredOnContinuation` — resume
    /// the stale one with `.cancelled` first so it can't be leaked/silently
    /// dropped (e.g. two overlapping `connect()` calls).
    private func resumePoweredOn(_ result: Result<Void, Error>) {
        poweredOnTimeoutTask?.cancel()
        poweredOnTimeoutTask = nil
        guard let continuation = poweredOnContinuation else { return }
        poweredOnContinuation = nil
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func waitForPoweredOn() async throws {
        switch centralManager.state {
        case .poweredOn:
            return
        case .unauthorized, .unsupported, .poweredOff:
            throw RinaTransportError.underlying("bluetooth unauthorized, unsupported, or powered off")
        default:
            break
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if poweredOnContinuation != nil {
                resumePoweredOn(.failure(RinaTransportError.cancelled))
            }
            self.poweredOnContinuation = continuation
            self.poweredOnTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.resumePoweredOn(.failure(RinaTransportError.timeout))
            }
        }
    }

    private func resumeConnect(_ result: Result<Void, Error>) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        switch result {
        case .success:
            emitState(.connected)
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func resumeWriteReady() {
        writeReadyTimeoutTask?.cancel()
        writeReadyTimeoutTask = nil
        writeReadyContinuation?.resume()
        writeReadyContinuation = nil
    }

    public func disconnect() {
        if let peripheral = targetPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        rxCharacteristic = nil
        txCharacteristic = nil
        infoCharacteristic = nil
        resumeConnect(.failure(RinaTransportError.cancelled))
        resumePoweredOn(.failure(RinaTransportError.cancelled))
        resumeWriteReady()
        emitState(.disconnected)
    }

    public func send(_ data: Data) async throws {
        guard let peripheral = targetPeripheral, let rx = rxCharacteristic else {
            throw RinaTransportError.notConnected
        }
        let chunkSize = preferredChunkBytes
        var offset = 0
        let writeType: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let slice = data.subdata(in: offset..<end)
            if writeType == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
                await waitForWriteReady()
            }
            peripheral.writeValue(slice, for: rx, type: writeType)
            offset = end
        }
    }

    private func waitForWriteReady() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.writeReadyContinuation = continuation
            self.writeReadyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.resumeWriteReady()
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate
//
// The class is `@MainActor`, but CoreBluetooth requires these delegate
// methods to be `nonisolated`. Since the central manager is created with
// `queue: .main`, all of these callbacks are already dispatched on the main
// queue/thread, so `MainActor.assumeIsolated` is safe here and preserves
// callback ordering (a `Task { @MainActor in }` hop would not).
extension BLETransport: CBCentralManagerDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                resumePoweredOn(.success(()))
            case .unauthorized, .unsupported, .poweredOff:
                // A3: resume any waiter instead of leaving `connect()` hung
                // forever when Bluetooth is off/unauthorized/unsupported.
                let message = central.state == .poweredOff ? "bluetooth is powered off" : "bluetooth unauthorized or unsupported"
                resumePoweredOn(.failure(RinaTransportError.underlying(message)))
                lastError = message
                emitState(.failed(message))
            default:
                emitState(.failed("bluetooth unavailable"))
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "RinaBoard"
            if let existing = discoveredPeripherals.first(where: { $0.id == peripheral.identifier }) {
                existing.rssi = RSSI.intValue
                existing.name = name
            } else {
                discoveredPeripherals.append(DiscoveredPeripheral(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
            }
            if targetPeripheral == nil, peripheral.identifier == peripheralIdentifier {
                targetPeripheral = peripheral
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            targetPeripheral = peripheral
            peripheral.discoverServices([serviceCBUUID])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let message = error?.localizedDescription ?? "connect failed"
            emitState(.failed(message))
            resumeConnect(.failure(RinaTransportError.underlying(message)))
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            rxCharacteristic = nil
            txCharacteristic = nil
            infoCharacteristic = nil
            emitState(.disconnected)
            resumeConnect(.failure(error.map { RinaTransportError.underlying($0.localizedDescription) } ?? RinaTransportError.notConnected))
            resumeWriteReady()
        }
    }
}

extension BLETransport: CBPeripheralDelegate {
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == serviceCBUUID }) else {
                if let error {
                    resumeConnect(.failure(RinaTransportError.underlying(error.localizedDescription)))
                }
                return
            }
            peripheral.discoverCharacteristics([rxCBUUID, txCBUUID, infoCBUUID], for: service)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let characteristics = service.characteristics else {
                if let error {
                    resumeConnect(.failure(RinaTransportError.underlying(error.localizedDescription)))
                }
                return
            }
            for characteristic in characteristics {
                switch characteristic.uuid {
                case rxCBUUID:
                    rxCharacteristic = characteristic
                case txCBUUID:
                    txCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case infoCBUUID:
                    infoCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == txCBUUID else { return }
            if let error {
                resumeConnect(.failure(RinaTransportError.underlying(error.localizedDescription)))
                return
            }
            guard rxCharacteristic != nil else { return }
            resumeConnect(.success(()))
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let value = characteristic.value else { return }
            if characteristic.uuid == txCBUUID {
                emitIncoming(value)
            } else if characteristic.uuid == infoCBUUID {
                infoJSON = value
                bleInfo = try? JSONDecoder().decode(BLEInfo.self, from: value)
            }
        }
    }

    public nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            resumeWriteReady()
        }
    }
}
