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
public final class BLETransport: NSObject, RinaTransport, @unchecked Sendable {
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
                self?.stateContinuations.removeValue(forKey: id)
            }
        }
    }

    public func incomingStream() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { continuation in
            self.incomingContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.incomingContinuations.removeValue(forKey: id)
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

    private func waitForPoweredOn() async throws {
        switch centralManager.state {
        case .poweredOn:
            return
        case .unauthorized, .unsupported:
            throw RinaTransportError.underlying("bluetooth unauthorized or unsupported")
        default:
            break
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.poweredOnContinuation = continuation
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

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            poweredOnContinuation?.resume()
            poweredOnContinuation = nil
        case .unauthorized, .unsupported:
            let message = "bluetooth unauthorized or unsupported"
            poweredOnContinuation?.resume(throwing: RinaTransportError.underlying(message))
            poweredOnContinuation = nil
            lastError = message
            emitState(.failed(message))
        default:
            emitState(.failed("bluetooth unavailable"))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
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

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        targetPeripheral = peripheral
        peripheral.discoverServices([serviceCBUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "connect failed"
        emitState(.failed(message))
        resumeConnect(.failure(RinaTransportError.underlying(message)))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rxCharacteristic = nil
        txCharacteristic = nil
        infoCharacteristic = nil
        emitState(.disconnected)
        resumeConnect(.failure(error.map { RinaTransportError.underlying($0.localizedDescription) } ?? RinaTransportError.notConnected))
        resumeWriteReady()
    }
}

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceCBUUID }) else {
            if let error {
                resumeConnect(.failure(RinaTransportError.underlying(error.localizedDescription)))
            }
            return
        }
        peripheral.discoverCharacteristics([rxCBUUID, txCBUUID, infoCBUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
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

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == txCBUUID else { return }
        if let error {
            resumeConnect(.failure(RinaTransportError.underlying(error.localizedDescription)))
            return
        }
        guard rxCharacteristic != nil else { return }
        resumeConnect(.success(()))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == txCBUUID {
            emitIncoming(value)
        } else if characteristic.uuid == infoCBUUID {
            infoJSON = value
            bleInfo = try? JSONDecoder().decode(BLEInfo.self, from: value)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        resumeWriteReady()
    }
}
