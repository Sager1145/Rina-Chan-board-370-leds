import Foundation
import CoreBluetooth
import OSLog
import RinaCore

@Observable
public final class DiscoveredPeripheral: Identifiable {
    public let id: UUID
    /// The advertised local name, or nil when the board advertises anonymously
    /// (firmware older than the scan-response fix). Kept optional rather than
    /// defaulted so the UI can say "unnamed" instead of inventing a name that
    /// looks real and makes two boards indistinguishable.
    public var advertisedName: String?
    public var rssi: Int
    /// Refreshed on every advertisement so the list can drop boards that have
    /// gone away; BLE has no "disappeared" callback while scanning.
    public var lastSeen: Date

    public var name: String { advertisedName ?? "璃奈板（未命名）" }

    /// Last 4 hex characters of the CoreBluetooth identifier. The only thing
    /// that tells two anonymous boards apart in the list.
    public var shortID: String { String(id.uuidString.suffix(4)) }

    init(id: UUID, advertisedName: String?, rssi: Int, lastSeen: Date = Date()) {
        self.id = id
        self.advertisedName = advertisedName
        self.rssi = rssi
        self.lastSeen = lastSeen
    }
}

/// Parsed contents of the INFO characteristic
/// (`{"proto","device","name","fw","mtu","tcpPort"}`). `name` is the
/// user-settable board name and is absent on firmware predating it.
public struct BLEInfo: Codable, Equatable, Sendable {
    public let proto: Int?
    public let device: String?
    public let name: String?
    public let fw: String?
    public let mtu: Int?
    public let tcpPort: Int?
}

/// CoreBluetooth transport: scans for the RinaLink service UUID, connects,
/// discovers RX (write)/TX (notify)/INFO (read) characteristics, and slices
/// outgoing writes to the negotiated MTU.
@Observable
@MainActor
public final class BLETransport: NSObject, @MainActor RinaTransport, BLEConnecting, @unchecked Sendable {
    public let kind: TransportKind = .bluetooth

    /// Sorted strongest-signal-first, stale entries pruned. Only boards
    /// advertising the RinaLink service UUID ever land here.
    public private(set) var discoveredPeripherals: [DiscoveredPeripheral] = []
    public private(set) var isScanning = false
    /// The peripheral a `connect()` is currently in flight for, so the list can
    /// show progress on the row the user actually tapped.
    public private(set) var connectingPeripheralID: UUID?
    public private(set) var connectedPeripheralID: UUID?
    public private(set) var connectedPeripheralName: String?
    /// Signal strength sampled from the active BLE link. Advertisements stop
    /// after connection, so discovery RSSI cannot keep this value current.
    public private(set) var connectedRSSI: Int?
    public private(set) var infoJSON: Data?
    public private(set) var bleInfo: BLEInfo?
    /// Surfaced instead of silently no-oping when e.g. Bluetooth is off.
    public var lastError: String?

    private var centralManager: CBCentralManager!
    private var discoveredPeripheralObjects: [UUID: CBPeripheral] = [:]
    private var targetPeripheral: CBPeripheral?
    /// True after `didConnect` for the current target. A disconnect arriving
    /// before that point belongs to a cancellation from the previous attempt;
    /// CoreBluetooth reports a failure of the current attempt via
    /// `didFailToConnect` instead.
    private var hasConnectedLink = false
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
    private var connectAttemptID = UUID()
    /// The attempt currently holding `connect()`'s single-flight slot, or nil
    /// when no `connect()` call is in progress. An attempt token (rather than
    /// a bare `Bool`) lets a superseded attempt's own unwind (`defer` in
    /// `connect()`) tell whether it still owns the slot before clearing it,
    /// so it can never clobber a newer attempt that has already claimed it.
    private var inProgressAttempt: UUID?
    private var isConnectInProgress: Bool { inProgressAttempt != nil }
    private let disconnectGate = BLEDisconnectGate()
    /// Retains the `CBPeripheral` for a cancel that is still pending a
    /// terminal CoreBluetooth callback. Without this, callers clear
    /// `targetPeripheral` right after starting the cancel and CoreBluetooth
    /// may never deliver `didDisconnect`/`didFailToConnect` for a peripheral
    /// object nobody holds anymore, leaving the disconnect gate entry stuck.
    private var cancellingPeripherals: [UUID: CBPeripheral] = [:]
    /// Extra time given to a stuck cancel before giving up and reusing the
    /// peripheral anyway.
    private static let forceCancelGraceSeconds: TimeInterval = 2
    /// See `GateRecoveryBookkeeping`.
    private var gateRecovery = GateRecoveryBookkeeping()

    // MARK: write back-pressure (H3)

    private let writePump = RatePump(minInterval: 0, depth: 255)
    private var writeReadyContinuation: CheckedContinuation<Void, Error>?
    private var writeReadyWaitID: UUID?
    private var writeReadyTimeoutTask: Task<Void, Never>?

    // MARK: discovery housekeeping

    /// An advertising board is seen every ~100-1000 ms; 6 s of silence means it
    /// is genuinely gone rather than momentarily missed.
    private static let staleAfterSeconds: TimeInterval = 6
    private var pruneTask: Task<Void, Never>?

    /// Scanning is an action the user starts, not a mode the app sits in:
    /// `allowDuplicates` keeps the radio busy for as long as it runs, so a scan
    /// nobody stops drains the battery and leaves the spinner up forever when
    /// no board is nearby. Stop on our own once a board that is powered on
    /// would certainly have been seen (it advertises every ~100-1000 ms).
    public static let scanTimeoutSeconds: TimeInterval = 30
    private var scanTimeoutTask: Task<Void, Never>?
    private var rssiPollTask: Task<Void, Never>?
    /// True when the last scan ended on `scanTimeoutSeconds` rather than
    /// because the user stopped it or a connect took over, so the UI can say
    /// why the spinner went away.
    public private(set) var scanDidTimeOut = false
    private let logger = Logger(subsystem: "com.rinachan.board", category: "Bluetooth")

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
            lastError = bluetoothUnavailableMessage(centralManager.state)
            logger.error("BLE scan rejected: \(self.lastError ?? "Bluetooth unavailable", privacy: .public)")
            return
        }
        guard !isScanning else { return }
        lastError = nil
        scanDidTimeOut = false
        discoveredPeripherals.removeAll()
        discoveredPeripheralObjects.removeAll()
        isScanning = true
        // allowDuplicates keeps RSSI live and gives `lastSeen` something to
        // advance, which is what makes stale pruning work.
        centralManager.scanForPeripherals(
            withServices: [serviceCBUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        startPruneLoop()
        startScanTimeout()
        logger.info("BLE scan started for RinaLink service \(self.serviceCBUUID.uuidString, privacy: .public)")
    }

    public func stopScan() {
        centralManager.stopScan()
        if isScanning {
            logger.info("BLE scan stopped; \(self.discoveredPeripherals.count) board(s) visible")
        }
        isScanning = false
        pruneTask?.cancel()
        pruneTask = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
    }

    /// Ends a scan the user never stopped. Already-discovered rows stay on
    /// screen: they keep working because a board that answered a scan is still
    /// connectable, and dropping them would punish the user for waiting.
    private func startScanTimeout() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.scanTimeoutSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isScanning else { return }
            self.stopScan()
            self.scanDidTimeOut = true
            self.logger.info("BLE scan auto-stopped after \(Self.scanTimeoutSeconds, privacy: .public) s")
        }
    }

    /// Drops boards that have stopped advertising (powered off, out of range,
    /// or connected to someone else). Without this the list only ever grows and
    /// tapping a dead row costs the user a 15-second connect timeout.
    private func startPruneLoop() {
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pruneStalePeripherals()
            }
        }
    }

    private func pruneStalePeripherals() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfterSeconds)
        let staleIDs = Set(discoveredPeripherals.lazy.filter {
            $0.lastSeen < cutoff && $0.id != self.connectingPeripheralID && $0.id != self.connectedPeripheralID
        }.map(\.id))
        discoveredPeripherals.removeAll {
            // Never prune the board we are connecting to or connected to: it
            // stops advertising the moment the link is up (single-central
            // firmware), which would otherwise make the row vanish mid-tap.
            $0.lastSeen < cutoff && $0.id != connectingPeripheralID && $0.id != connectedPeripheralID
        }
        for id in staleIDs {
            discoveredPeripheralObjects.removeValue(forKey: id)
        }
    }

    private func bluetoothUnavailableMessage(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOff: return "蓝牙已关闭，请在控制中心或设置中打开"
        case .unauthorized: return "未获得蓝牙权限，请在 设置 › 隐私与安全性 › 蓝牙 中允许"
        case .unsupported: return "此设备不支持蓝牙"
        case .resetting: return "蓝牙正在重置，请稍后重试"
        default: return "蓝牙不可用"
        }
    }

    public func connect() async throws {
        guard inProgressAttempt == nil else {
            throw RinaTransportError.cancelled
        }
        let attempt = UUID()
        inProgressAttempt = attempt
        // Only clear the slot if it is still this attempt's: `disconnect()`
        // (e.g. a board switch racing this same unwind) may have already
        // handed the slot to a newer attempt, and this `defer` must not steal
        // it back out from under that newer attempt.
        defer { if inProgressAttempt == attempt { inProgressAttempt = nil } }
        connectAttemptID = attempt
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await connectSelectedPeripheral(attempt: attempt)
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.connectAttemptID == attempt else { return }
                    self.disconnect()
                }
            }
        } catch {
            if connectAttemptID == attempt {
                let peripheral = targetPeripheral
                clearConnectionTarget()
                if let peripheral { cancelLink(peripheral) }
                lastError = error.localizedDescription
            }
            throw error
        }
    }

    private func connectSelectedPeripheral(attempt: UUID) async throws {
        guard connectContinuation == nil else {
            logger.error("BLE connect rejected because another connection attempt is active")
            throw RinaTransportError.cancelled
        }
        guard let identifier = peripheralIdentifier else {
            clearConnectionTarget()
            let message = "未选择要连接的璃奈板"
            lastError = message
            logger.error("BLE connect rejected: no peripheral identifier")
            emitState(.failed(message))
            throw RinaTransportError.notConnected
        }

        try await waitForPoweredOn()
        guard connectAttemptID == attempt, peripheralIdentifier == identifier else {
            logger.notice("BLE connect selection changed while waiting for Bluetooth power")
            throw RinaTransportError.cancelled
        }
        // Never retain the previous target while resolving a new row. If Core
        // Bluetooth cannot retrieve the requested identifier, connecting must
        // fail rather than silently reconnecting to the last board.
        clearConnectionTarget()
        connectingPeripheralID = identifier
        emitState(.connecting)
        let peripheral = try await resolvePeripheral(identifier, attempt: attempt)
        let waitResult = try await disconnectGate.wait(for: peripheral.identifier)
        try Task.checkCancellation()
        // Explicit even though the attempt-ID guard right below would also
        // catch this in practice (disconnect() rotates connectAttemptID
        // before waking): a superseded wait must never be treated as license
        // to continue this attempt.
        if waitResult == .superseded { throw RinaTransportError.cancelled }
        // Bluetooth becoming unavailable is included here (not just attempt/
        // identifier staleness) so a wait that only resolved because
        // `handleBluetoothUnavailable` tore everything down cannot go on to
        // arm the ignore-marker or reuse the peripheral below.
        guard connectAttemptID == attempt, peripheralIdentifier == identifier, centralManager.state == .poweredOn else {
            throw RinaTransportError.cancelled
        }
        if waitResult == .timedOut {
            switch Self.gateTimeoutAction(state: peripheral.state) {
            case .forceCompleteNow:
                // Already disconnected, so there is no cancel left in flight
                // to race with reusing this peripheral.
                disconnectGate.forceComplete(peripheral.identifier)
                gateRecovery.onGraceWaitResult(.timedOut, id: peripheral.identifier)
                cancellingPeripherals.removeValue(forKey: peripheral.identifier)
                logger.notice("BLE force-cleared already-disconnected gate entry for \(peripheral.identifier.uuidString, privacy: .public)")
            case .recancelThenForce:
                // The previous cancel never got a terminal callback (the old
                // peripheral object was likely deallocated before CoreBluetooth
                // could deliver one). Retain this object, try the cancel once
                // more, then give up on waiting and reuse the peripheral rather
                // than getting stuck retrying forever.
                cancellingPeripherals[peripheral.identifier] = peripheral
                centralManager.cancelPeripheralConnection(peripheral)
                let graceResult: GateWaitResult
                do {
                    graceResult = try await disconnectGate.wait(for: peripheral.identifier, timeout: Self.forceCancelGraceSeconds)
                } catch is CancellationError {
                    // The re-cancel is still genuinely in flight; do not
                    // force-complete or drop the retained peripheral out from
                    // under it.
                    throw CancellationError()
                }
                try Task.checkCancellation()
                if graceResult == .superseded { throw RinaTransportError.cancelled }
                guard connectAttemptID == attempt, peripheralIdentifier == identifier, centralManager.state == .poweredOn else {
                    throw RinaTransportError.cancelled
                }
                // Only a genuine timeout arms the ignore-marker/force-completes
                // the gate: `.drained` here means the retained re-cancel got
                // its own terminal callback (which already did this cleanup),
                // so treating it as a stuck entry would swallow a real
                // `didFailToConnect` for the new attempt.
                if gateRecovery.onGraceWaitResult(graceResult, id: peripheral.identifier) {
                    disconnectGate.forceComplete(peripheral.identifier)
                    logger.notice("BLE force-cleared stuck disconnect gate entry for \(peripheral.identifier.uuidString, privacy: .public)")
                }
                cancellingPeripherals.removeValue(forKey: peripheral.identifier)
            }
        }
        guard centralManager.state == .poweredOn else {
            throw RinaTransportError.underlying(bluetoothUnavailableMessage(centralManager.state))
        }
        targetPeripheral = peripheral
        peripheral.delegate = self
        connectingPeripheralID = peripheral.identifier
        lastError = nil
        stopScan()
        emitState(.connecting)
        logger.info("BLE connecting to \(identifier.uuidString, privacy: .public) name=\(self.displayName(for: identifier), privacy: .public)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectContinuation = continuation
            self.connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.cancelLink(peripheral)
                self.resumeConnect(.failure(RinaTransportError.timeout))
            }
            centralManager.connect(peripheral, options: nil)
        }
    }

    /// A new app process has no discovery objects, and CoreBluetooth may no
    /// longer have the saved peripheral cached. Retry by discovering that
    /// exact UUID; never pick a similarly named board or the first result.
    private func resolvePeripheral(_ identifier: UUID, attempt: UUID) async throws -> CBPeripheral {
        if let peripheral = discoveredPeripheralObjects[identifier]
            ?? centralManager.retrievePeripherals(withIdentifiers: [identifier]).first
            ?? centralManager.retrieveConnectedPeripherals(withServices: [serviceCBUUID])
                .first(where: { $0.identifier == identifier }) {
            return peripheral
        }

        logger.info("Saved BLE peripheral is not cached; scanning for \(identifier.uuidString, privacy: .public)")
        let ownsScan = !isScanning
        if ownsScan { startScan() }
        defer { if ownsScan { stopScan() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard connectAttemptID == attempt, peripheralIdentifier == identifier else {
                throw RinaTransportError.cancelled
            }
            guard centralManager.state == .poweredOn else {
                throw RinaTransportError.underlying(bluetoothUnavailableMessage(centralManager.state))
            }
            if let peripheral = discoveredPeripheralObjects[identifier] { return peripheral }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RinaTransportError.underlying("未找到已保存的璃奈板，请确认板子已开机并在附近")
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
            throw RinaTransportError.underlying(bluetoothUnavailableMessage(centralManager.state))
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
            connectingPeripheralID = nil
            connectedPeripheralID = targetPeripheral?.identifier
            connectedPeripheralName = bleInfo?.name ?? targetPeripheral.map { displayName(for: $0.identifier) }
            if let targetPeripheral { startRSSIPolling(targetPeripheral) }
            lastError = nil
            emitState(.connected)
            if let id = connectedPeripheralID {
                logger.info("BLE ready: \(id.uuidString, privacy: .public) name=\(self.connectedPeripheralName ?? "unknown", privacy: .public) writeMTU=\(self.preferredChunkBytes)")
            }
            continuation.resume()
        case .failure(let error):
            // Service/characteristic/CCCD failure still leaves a physical BLE
            // link. Release it so the single-central board advertises again.
            let peripheral = targetPeripheral
            clearConnectionTarget()
            if let peripheral {
                gateRecovery.onAbandon(id: peripheral.identifier)
                cancelLink(peripheral)
            }
            resumeWriteReady(.failure(error))
            lastError = error.localizedDescription
            logger.error("BLE connection failed: \(error.localizedDescription, privacy: .public)")
            continuation.resume(throwing: error)
        }
    }

    private func displayName(for identifier: UUID) -> String {
        discoveredPeripherals.first(where: { $0.id == identifier })?.name
            ?? targetPeripheral?.name
            ?? "璃奈板（\(String(identifier.uuidString.suffix(4))))"
    }

    private func clearConnectionTarget() {
        rssiPollTask?.cancel()
        rssiPollTask = nil
        targetPeripheral?.delegate = nil
        targetPeripheral = nil
        hasConnectedLink = false
        connectingPeripheralID = nil
        connectedPeripheralID = nil
        connectedPeripheralName = nil
        connectedRSSI = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        infoCharacteristic = nil
        infoJSON = nil
        bleInfo = nil
    }

    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        peripheral === targetPeripheral
    }

    private func startRSSIPolling(_ peripheral: CBPeripheral) {
        rssiPollTask?.cancel()
        connectedRSSI = nil
        peripheral.readRSSI()
        rssiPollTask = Task { [weak self, weak peripheral] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard let self, let peripheral, !Task.isCancelled,
                      self.isCurrent(peripheral), peripheral.state == .connected else { return }
                peripheral.readRSSI()
            }
        }
    }

    /// CoreBluetooth uses 127 when an RSSI sample is unavailable.
    static func normalizedRSSI(_ value: NSNumber) -> Int? {
        let rssi = value.intValue
        return rssi == 127 ? nil : rssi
    }

    /// Pure decision for what to do after `BLEDisconnectGate.wait` reports
    /// `.timedOut`, split out of `connectSelectedPeripheral` so it is testable
    /// without a real `CBCentralManager`/`CBPeripheral`.
    static func gateTimeoutAction(state: CBPeripheralState) -> GateTimeoutAction {
        state == .disconnected ? .forceCompleteNow : .recancelThenForce
    }

    /// Keeps the connected label and saved discovery row current after a
    /// successful `set_device_name` command.
    public func updateConnectedPeripheralName(_ name: String) {
        guard let id = connectedPeripheralID else { return }
        connectedPeripheralName = name
        discoveredPeripherals.first(where: { $0.id == id })?.advertisedName = name
        logger.info("BLE connected board renamed to \(name, privacy: .public)")
    }

    private func resumeWriteReady(_ result: Result<Void, Error> = .success(())) {
        writeReadyTimeoutTask?.cancel()
        writeReadyTimeoutTask = nil
        writeReadyWaitID = nil
        guard let continuation = writeReadyContinuation else { return }
        writeReadyContinuation = nil
        continuation.resume(with: result)
    }

    private func cancelLink(_ peripheral: CBPeripheral) {
        guard peripheral.state != .disconnected else { return }
        guard disconnectGate.begin(peripheral.identifier) else { return }
        // A fresh cancel is starting; any stale ignore-marker from a previous
        // force-complete of this identifier no longer applies.
        gateRecovery.onCancelBegin(id: peripheral.identifier)
        cancellingPeripherals[peripheral.identifier] = peripheral
        logger.notice("BLE cancel pending for \(peripheral.identifier.uuidString, privacy: .public)")
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Shared teardown for `.unauthorized`/`.unsupported`/`.poweredOff`/
    /// `.resetting`, and for `.unknown` when it interrupts an in-flight
    /// connect: resume every pending waiter so nothing hangs forever while
    /// the radio is unavailable.
    private func handleBluetoothUnavailable(_ state: CBManagerState) {
        let message = bluetoothUnavailableMessage(state)
        resumePoweredOn(.failure(RinaTransportError.underlying(message)))
        lastError = message
        stopScan()
        if let peripheral = targetPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        clearConnectionTarget()
        disconnectGate.completeAll()
        cancellingPeripherals.removeAll()
        gateRecovery.onReset()
        resumeConnect(.failure(RinaTransportError.underlying(message)))
        logger.error("Bluetooth state became unavailable: \(message, privacy: .public)")
        emitState(.failed(message))
    }

    public func disconnect() {
        connectAttemptID = UUID()
        // Free the single-flight slot immediately so a `connect()` called
        // right after this (e.g. `BoardConnection` switching boards in the
        // same main-actor turn) can start its new attempt without waiting for
        // the superseded attempt's own suspended call stack to unwind. That
        // unwind's `defer` in `connect()` is keyed on its own attempt token,
        // so it cannot clobber the new attempt's claim on this slot.
        inProgressAttempt = nil
        let peripheral = targetPeripheral
        let identifier = peripheral?.identifier
        // Wake a connect attempt that might be parked inside
        // `disconnectGate.wait`, for whichever peripheral it is actually
        // waiting on — which is not necessarily `peripheralIdentifier`: when
        // switching boards, that public property may already have been
        // updated to the *new* board before this `disconnect()` runs, and the
        // wait is also not necessarily for `targetPeripheral` either (that is
        // only assigned after the gate wait/timeout dance completes).
        // `connect()` is single-flight, so waking every parked waiter is
        // always correct. Without this, `disconnect()` rotates
        // `connectAttemptID` but the superseded attempt only re-checks it
        // once the gate's own timeout elapses (up to 5 s, or a further 2 s
        // grace period), keeping `isConnectInProgress` true and rejecting a
        // new `connect()` for that whole window. The pending gate entry
        // itself is left untouched: the underlying cancel may still be
        // genuinely in flight.
        disconnectGate.wakeAllWaiters()
        clearConnectionTarget()
        if let peripheral {
            gateRecovery.onAbandon(id: peripheral.identifier)
            cancelLink(peripheral)
        }
        resumeConnect(.failure(RinaTransportError.cancelled))
        resumePoweredOn(.failure(RinaTransportError.cancelled))
        resumeWriteReady(.failure(RinaTransportError.notConnected))
        emitState(.disconnected)
        if let identifier {
            logger.info("BLE disconnected by app from \(identifier.uuidString, privacy: .public)")
        }
    }

    public func send(_ data: Data) async throws {
        try await writePump.run { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.sendSerial(data)
        }
    }

    private func sendSerial(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let peripheral = targetPeripheral, let rx = rxCharacteristic else {
            throw RinaTransportError.notConnected
        }
        let writeType: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: writeType))
        var offset = 0
        while offset < data.count {
            // Cancellation is safe before the first byte. Once a framed packet
            // has started, finish it so the next packet cannot be parsed as the
            // missing tail of this one.
            if offset == 0 { try Task.checkCancellation() }
            guard peripheral === targetPeripheral, rx === rxCharacteristic else {
                throw RinaTransportError.notConnected
            }
            let end = min(offset + chunkSize, data.count)
            let slice = data.subdata(in: offset..<end)
            if writeType == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
                do {
                    try await waitForWriteReady(cancellable: offset == 0)
                } catch {
                    // A timed-out partial packet poisons the byte stream. Reset
                    // that exact link before allowing a later request to send.
                    if offset > 0, peripheral === targetPeripheral {
                        disconnect()
                    }
                    throw error
                }
                guard peripheral === targetPeripheral, rx === rxCharacteristic else {
                    throw RinaTransportError.notConnected
                }
            }
            peripheral.writeValue(slice, for: rx, type: writeType)
            offset = end
        }
        try Task.checkCancellation()
    }

    private func waitForWriteReady(cancellable: Bool) async throws {
        let waitID = UUID()
        if cancellable {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await suspendUntilWriteReady(waitID: waitID)
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.writeReadyWaitID == waitID else { return }
                    self.resumeWriteReady(.failure(CancellationError()))
                }
            }
        } else {
            try await suspendUntilWriteReady(waitID: waitID)
        }
    }

    private func suspendUntilWriteReady(waitID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.writeReadyWaitID = waitID
            self.writeReadyContinuation = continuation
            self.writeReadyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.writeReadyWaitID == waitID else { return }
                self.resumeWriteReady(.failure(RinaTransportError.timeout))
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
            case .unauthorized, .unsupported, .poweredOff, .resetting:
                // A3: resume any waiter instead of leaving `connect()` hung
                // forever when Bluetooth is off/unauthorized/unsupported, and
                // treat `.resetting` the same way: the radio is about to be
                // torn down and rebuilt, so any pending gate entry will never
                // get a terminal callback either.
                handleBluetoothUnavailable(central.state)
            case .unknown:
                // `.unknown` is a transient startup value that can also appear
                // briefly during a radio reset; only treat it as a failure
                // when it interrupts an in-flight connect (same handling as
                // `.resetting`). When idle, do nothing at all — no
                // `emitState(.failed(...))` either, since that would
                // spuriously fail state before the app has done anything with
                // Bluetooth yet.
                guard isConnectInProgress else { return }
                handleBluetoothUnavailable(central.state)
            @unknown default:
                emitState(.failed("bluetooth unavailable"))
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            // iOS merges the advertisement and the scan response, so the local
            // name arrives here even though the firmware puts it in the scan
            // response. Deliberately NOT defaulted to a made-up "RinaBoard":
            // an unnamed board must look unnamed, not like a named one.
            let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
            let name = advertised?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = (name?.isEmpty == false) ? name : nil
            discoveredPeripheralObjects[peripheral.identifier] = peripheral

            if let existing = discoveredPeripherals.first(where: { $0.id == peripheral.identifier }) {
                existing.rssi = RSSI.intValue
                existing.lastSeen = Date()
                // Keep the last good name: some advertisement packets carry the
                // service UUID only, and blanking the row would make it flicker.
                if let resolved { existing.advertisedName = resolved }
            } else {
                discoveredPeripherals.append(
                    DiscoveredPeripheral(id: peripheral.identifier, advertisedName: resolved, rssi: RSSI.intValue))
                logger.info("Discovered Rina board \(peripheral.identifier.uuidString, privacy: .public) name=\(resolved ?? "unnamed", privacy: .public) RSSI=\(RSSI.intValue)")
            }
            sortDiscovered()

        }
    }

    /// Strongest signal first — the board in the user's hand should be the top
    /// row. Ties break on a stable key so rows never swap while being tapped.
    private func sortDiscovered() {
        discoveredPeripherals.sort {
            $0.rssi == $1.rssi ? $0.id.uuidString < $1.id.uuidString : $0.rssi > $1.rssi
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            if disconnectGate.contains(peripheral.identifier) {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            guard isCurrent(peripheral) else {
                logger.notice("Ignoring stale didConnect for \(peripheral.identifier.uuidString, privacy: .public)")
                central.cancelPeripheralConnection(peripheral)
                return
            }
            // The new link is confirmed live: a terminal callback from here
            // on can only belong to it, not to a previously force-cleared
            // cancel.
            gateRecovery.onDidConnect(id: peripheral.identifier)
            hasConnectedLink = true
            logger.info("BLE link connected; discovering RinaLink service on \(peripheral.identifier.uuidString, privacy: .public)")
            peripheral.discoverServices([serviceCBUUID])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if disconnectGate.complete(peripheral.identifier) {
                cancellingPeripherals.removeValue(forKey: peripheral.identifier)
                logger.notice("BLE cancel confirmed via didFailToConnect for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            if gateRecovery.onTerminal(id: peripheral.identifier) {
                logger.notice("Ignoring late didFailToConnect for previously force-cleared cancel \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            guard isCurrent(peripheral) else {
                logger.notice("Ignoring stale didFailToConnect for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            let message = error?.localizedDescription ?? "connect failed"
            emitState(.failed(message))
            resumeConnect(.failure(RinaTransportError.underlying(message)))
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if disconnectGate.complete(peripheral.identifier) {
                cancellingPeripherals.removeValue(forKey: peripheral.identifier)
                logger.notice("BLE cancel confirmed via didDisconnect for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            if gateRecovery.onTerminal(id: peripheral.identifier) {
                logger.notice("Ignoring late didDisconnect for previously force-cleared cancel \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            guard isCurrent(peripheral) else {
                logger.notice("Ignoring stale didDisconnect for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            let identifier = peripheral.identifier
            let errorDescription = error?.localizedDescription
            clearConnectionTarget()
            if let errorDescription {
                logger.error("BLE disconnected from \(identifier.uuidString, privacy: .public): \(errorDescription, privacy: .public)")
            } else {
                logger.info("BLE disconnected from \(identifier.uuidString, privacy: .public)")
            }
            emitState(.disconnected)
            resumeConnect(.failure(error.map { RinaTransportError.underlying($0.localizedDescription) } ?? RinaTransportError.notConnected))
            resumeWriteReady(.failure(error.map { RinaTransportError.underlying($0.localizedDescription) } ?? RinaTransportError.notConnected))
        }
    }
}

extension BLETransport: CBPeripheralDelegate {
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(peripheral), connectedPeripheralID == peripheral.identifier else { return }
            if let error {
                logger.debug("BLE RSSI read failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let rssi = Self.normalizedRSSI(RSSI) else { return }
            connectedRSSI = rssi
            if let discovered = discoveredPeripherals.first(where: { $0.id == peripheral.identifier }) {
                discovered.rssi = rssi
                discovered.lastSeen = Date()
                sortDiscovered()
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(peripheral) else {
                logger.notice("Ignoring stale service discovery for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            guard hasConnectedLink else {
                logger.notice("Ignoring service discovery before current link confirmation for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            if let error {
                resumeConnect(.failure(RinaTransportError.underlying(error.localizedDescription)))
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == serviceCBUUID }) else {
                resumeConnect(.failure(RinaTransportError.underlying("RinaLink service not found")))
                return
            }
            logger.debug("RinaLink service discovered; requesting characteristics")
            peripheral.discoverCharacteristics([rxCBUUID, txCBUUID, infoCBUUID], for: service)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(peripheral) else {
                logger.notice("Ignoring stale characteristic discovery for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            guard hasConnectedLink else {
                logger.notice("Ignoring characteristic discovery before current link confirmation for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            if let error {
                resumeConnect(.failure(RinaTransportError.underlying(error.localizedDescription)))
                return
            }
            guard let characteristics = service.characteristics else {
                resumeConnect(.failure(RinaTransportError.underlying("RinaLink characteristics not found")))
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
            guard rxCharacteristic != nil, txCharacteristic != nil else {
                resumeConnect(.failure(RinaTransportError.underlying("RinaLink RX/TX characteristics missing")))
                return
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(peripheral), characteristic === txCharacteristic else {
                logger.notice("Ignoring stale notification-state callback for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            if let error {
                resumeConnect(.failure(RinaTransportError.underlying(error.localizedDescription)))
                return
            }
            guard characteristic.isNotifying else {
                resumeConnect(.failure(RinaTransportError.underlying("璃奈板未能启用蓝牙通知，请重新连接")))
                return
            }
            guard rxCharacteristic != nil else { return }
            resumeConnect(.success(()))
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(peripheral) else {
                logger.notice("Ignoring stale value callback for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            if let error {
                logger.error("BLE characteristic read/notify failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let value = characteristic.value else { return }
            if characteristic === txCharacteristic {
                emitIncoming(value)
            } else if characteristic === infoCharacteristic {
                infoJSON = value
                bleInfo = try? JSONDecoder().decode(BLEInfo.self, from: value)
                if let name = bleInfo?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    connectedPeripheralName = name
                }
                logger.info("BLE INFO received name=\(self.bleInfo?.name ?? "missing", privacy: .public) firmware=\(self.bleInfo?.fw ?? "missing", privacy: .public) mtu=\(self.bleInfo?.mtu ?? -1)")
            }
        }
    }

    public nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard isCurrent(peripheral) else { return }
            resumeWriteReady()
        }
    }
}
