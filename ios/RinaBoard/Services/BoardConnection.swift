import Foundation
import RinaCore

public enum BoardConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
}

/// Unsolicited/observed board events, fanned out to all `events()` consumers.
public enum BoardEvent: Sendable {
    case log(RinaLogEvent)
    case previewSync(PreviewSync)
    case status(DeviceStatus)
    case power(PowerStatus)
    case wifi(WifiStatus)
    case wifiScan(WifiScanReply)
}

/// Owns the single active `RinaTransport`, decodes/encodes RinaLink frames,
/// matches replies to requests by `seq`, aggregates `MORE`-flagged chunked
/// replies, fans out unsolicited events to published properties, and applies
/// the WebUI's rate limits (D6) to outgoing frames/commands.
///
/// This is the only type feature code should talk to; it is transport-agnostic.
@Observable
@MainActor
public final class BoardConnection {
    // MARK: Published state

    public let output = BoardPlaybackCoordinator()
    public private(set) var connectionGeneration = UUID()
    public private(set) var connectionState: BoardConnectionState = .disconnected {
        didSet {
            if connectionState != .connected && oldValue == .connected {
                output.invalidate()
                connectionGeneration = UUID()
            }
        }
    }
    public private(set) var transportKind: TransportKind?
    /// The active board's effective advertised name, read from `get_info`.
    /// It is deliberately scoped to the current connection generation.
    public private(set) var deviceName: String?

    public private(set) var status: DeviceStatus?
    public private(set) var preview: PreviewSync?
    public private(set) var power: PowerStatus?
    public private(set) var wifi: WifiStatus?
    public private(set) var currentFrame: PackedFrame = PackedFrame() {
        didSet { hasCurrentFrame = true }
    }
    public private(set) var hasCurrentFrame = false
    public private(set) var lastError: String?
    public private(set) var lastLog: RinaLogEvent?
    public private(set) var lastWifiScan: WifiScanReply?

    // MARK: Private

    private var eventContinuations: [UUID: AsyncStream<BoardEvent>.Continuation] = [:]
    private var transport: RinaTransport?
    private let decoder = RinaLinkDecoder()
    private var nextSeq: UInt8 = 1
    private var pending: [UInt8: PendingRequest] = [:]
    /// Seqs that just timed out, kept out of circulation for 2s so a reply
    /// that finally arrives after the timeout can't be delivered to a
    /// different (reused) request that happens to land on the same seq.
    private var quarantinedSeqs: Set<UInt8> = []
    private var incomingTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var transportSessionID = UUID()
    private var isEstablishing = false
    private var establishmentError: String?
    private var reconnectDelay: (Int) -> TimeInterval = { min(30, pow(2, Double($0))) }
    private var handshakeTimeout: TimeInterval = 5

    // Rate limiting (FEATURE_INVENTORY D6): frames >=20ms apart depth 6 drop-oldest,
    // commands >=120ms apart depth 4 drop-oldest.
    private let framePump = RatePump(minInterval: 0.020, depth: 6)
    private let commandPump = RatePump(minInterval: 0.120, depth: 4)
    private let blobPump = RatePump(minInterval: 0, depth: 4)
    private let outputPump = RatePump(minInterval: 0, depth: 64)

    public func withOutput<T: Sendable>(
        _ session: UUID,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try output.check(session)
        let task = Task { @MainActor in
            try await BoardOutputContext.$session.withValue(session) {
                try await operation()
            }
        }
        guard let operationID = output.registerOperation(for: session, cancel: task.cancel) else {
            return try await task.value
        }
        defer { output.unregisterOperation(operationID, for: session) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try output.check(session)
            return result
        } onCancel: {
            task.cancel()
        }
    }

    private struct PendingRequest {
        let id: UUID
        let replyType: UInt8
        /// When false (GET_FACES), a terminal frame resolves the request
        /// immediately regardless of `FLAG_MORE` — for that message `MORE`
        /// means "call again with a higher offset", not "more chunks of this
        /// same reply are coming on this seq" (A1).
        let aggregateMore: Bool
        var accumulated = Data()
        let continuation: CheckedContinuation<RinaLinkFrame, Error>
        let timeoutTask: Task<Void, Never>
        var sendTask: Task<Void, Never>?
    }

    public init() {}

    init(reconnectDelay: @escaping (Int) -> TimeInterval, handshakeTimeout: TimeInterval = 5) {
        self.reconnectDelay = reconnectDelay
        self.handshakeTimeout = handshakeTimeout
    }

    // MARK: Connection lifecycle

    /// Swaps in `transport` as the active transport and connects it. Returns
    /// `true` after the handshake and initial snapshot reads, `false` on failure — kept
    /// `@discardableResult` so existing call sites that only poll
    /// `connectionState` afterwards keep working unmodified.
    @discardableResult
    public func connect(using transport: RinaTransport) async -> Bool {
        disconnect()
        output.invalidate()
        connectionGeneration = UUID()
        clearBoardSnapshot()
        lastError = nil
        reconnectAttempts = 0
        self.transport = transport
        transportKind = transport.kind
        return await establish(transport)
    }

    /// Each attempt gets fresh streams and a token, including attempts that
    /// reuse the same BLETransport object. Queued callbacks from older streams
    /// cannot change the new connection's state or feed its decoder.
    private func establish(_ transport: RinaTransport) async -> Bool {
        let session = UUID()
        transportSessionID = session
        isEstablishing = true
        establishmentError = nil
        connectionState = .connecting
        decoder.reset()
        let states = transport.stateStream()
        let incoming = transport.incomingStream()
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self, !Task.isCancelled, self.transportSessionID == session else { return }
                self.handleTransportState(state)
            }
        }
        incomingTask = Task { [weak self] in
            for await data in incoming {
                guard let self, !Task.isCancelled, self.transportSessionID == session else { return }
                await self.handleIncoming(data)
            }
        }
        do {
            try await transport.connect()
            try Task.checkCancellation()
            guard transportSessionID == session else { return false }
            if let establishmentError { throw RinaTransportError.underlying(establishmentError) }
            // A carrier connection alone does not prove notifications and the
            // framed protocol work. Keep the UI connecting until PING replies.
            _ = try await sendUnqueued(type: .ping, payload: Data(), timeout: handshakeTimeout,
                                       aggregateMore: true, duringSetup: true)
            try Task.checkCancellation()
            guard transportSessionID == session else { return false }
            _ = await subscribeToDefaultEvents(duringSetup: true)
            guard transportSessionID == session else { return false }
            await refreshBoardSnapshot(session: session)
            try Task.checkCancellation()
            guard transportSessionID == session else { return false }
            if let establishmentError { throw RinaTransportError.underlying(establishmentError) }
            isEstablishing = false
            reconnectAttempts = 0
            lastError = nil
            connectionState = .connected
            let generation = connectionGeneration
            startPingLoopIfNeeded()
            await refreshDeviceName(for: transport, generation: generation)
            try Task.checkCancellation()
            return transportSessionID == session && connectionState == .connected
        } catch {
            guard transportSessionID == session else { return false }
            if Task.isCancelled || error is CancellationError {
                disconnect()
            } else {
                connectionFailed(error.localizedDescription)
            }
            return false
        }
    }

    private func stopCarrier() {
        transportSessionID = UUID()
        isEstablishing = false
        clearBoardSnapshot()
        stateTask?.cancel()
        incomingTask?.cancel()
        pingTask?.cancel()
        decoder.reset()
        failAllPending(RinaTransportError.notConnected)
        transport?.disconnect()
    }

    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        stopCarrier()
        transport = nil
        lastError = nil
        deviceName = nil
        connectionState = .disconnected
    }

    private func handleTransportState(_ state: TransportState) {
        switch state {
        case .idle, .connecting, .connected:
            // establish() owns readiness; transport callbacks only report the
            // carrier, before the protocol handshake is complete.
            break
        case .disconnected:
            if isEstablishing {
                establishmentError = RinaTransportError.notConnected.localizedDescription
                failAllPending(RinaTransportError.notConnected)
            } else {
                connectionFailed(RinaTransportError.notConnected.localizedDescription)
            }
        case .failed(let message):
            if isEstablishing {
                establishmentError = message
                failAllPending(RinaTransportError.underlying(message))
            } else {
                connectionFailed(message)
            }
        }
    }

    private func connectionFailed(_ message: String) {
        stopCarrier()
        deviceName = nil
        lastError = message
        connectionState = .failed(message)
        attemptReconnect()
    }

    private func attemptReconnect() {
        guard let transport else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            connectionState = .failed("重连失败，已达到最大尝试次数：" + (lastError ?? ""))
            return
        }
        reconnectTask?.cancel()
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        connectionState = .reconnecting(attempt: attempt)
        let session = transportSessionID
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(self.reconnectDelay(attempt))) }
            catch { return }
            guard !Task.isCancelled, self.transportSessionID == session else { return }
            self.reconnectTask = nil
            _ = await self.establish(transport)
        }
    }

    private func startPingLoopIfNeeded() {
        // H2: keep-alive applies to any non-Bluetooth (TCP) transport, i.e.
        // both home Wi-Fi and hotspot, not just `.wifi`.
        switch transportKind {
        case .wifi, .hotspot:
            break
        default:
            return
        }
        pingTask?.cancel()
        let activeTransport = transport
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Exit if the connection's active transport has changed since
                // this loop was started, rather than pinging a stale one.
                guard self.transport === activeTransport else { return }
                guard self.connectionState == .connected else { continue }
                let session = self.transportSessionID
                do {
                    _ = try await self.send(type: .ping, payload: Data(), timeout: 5)
                } catch {
                    guard !Task.isCancelled, self.transportSessionID == session else { return }
                    self.connectionFailed(error.localizedDescription)
                    return
                }
            }
        }
    }

    // MARK: Event stream

    /// Multi-consumer stream of unsolicited board events (log lines, pushed
    /// status/preview/power/wifi, and Wi-Fi scan results). Each call returns
    /// an independent stream; the underlying continuation is removed when
    /// that stream's consumer stops iterating.
    public func events() -> AsyncStream<BoardEvent> {
        subscribeEvents().stream
    }

    /// Like `events()`, but also returns the subscription id (see
    /// `subscribeEvents()`) so a caller that subscribes *before* sending a
    /// command (to avoid racing a fast reply/event) can explicitly
    /// `unsubscribe(_:)` once done, instead of relying on stream iteration
    /// termination to clean up.
    public func subscribeToEvents() -> (id: UUID, stream: AsyncStream<BoardEvent>) {
        subscribeEvents()
    }

    /// Explicitly tears down a subscription created by `subscribeToEvents()`.
    public func unsubscribe(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    /// Like `events()`, but also returns the subscription id so a caller that
    /// might never actually iterate the stream (e.g. `wifiScan()`'s
    /// synchronous-reply fast path) can unsubscribe explicitly (A6) instead of
    /// leaking the continuation in `eventContinuations` forever.
    private func subscribeEvents() -> (id: UUID, stream: AsyncStream<BoardEvent>) {
        let id = UUID()
        let stream = AsyncStream<BoardEvent> { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
        return (id, stream)
    }

    private func emit(_ event: BoardEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func clearBoardSnapshot() {
        status = nil
        preview = nil
        power = nil
        wifi = nil
        currentFrame = PackedFrame()
        hasCurrentFrame = false
        deviceName = nil
    }

    /// Read a snapshot even when the firmware has no new events to publish.
    /// Each read is independent so an unsupported preview does not hide status.
    private func refreshBoardSnapshot(session: UUID) async {
        for type: RinaLinkMessageType in [.getStatus, .getFrame, .getPreviewSync] {
            guard !Task.isCancelled, transportSessionID == session else { return }
            guard let frame = try? await sendUnqueued(type: type, payload: Data(),
                                                      timeout: handshakeTimeout, aggregateMore: true,
                                                      duringSetup: true) else { continue }
            guard !Task.isCancelled, transportSessionID == session else { return }
            switch type {
            case .getStatus:
                if let decoded = try? JSONDecoder().decode(DeviceStatus.self, from: frame.payload) {
                    applyStatus(decoded)
                }
            case .getFrame:
                if let packed = PackedFrame(data: frame.payload) { currentFrame = packed }
            case .getPreviewSync:
                if let decoded = try? JSONDecoder().decode(PreviewSync.self, from: frame.payload) {
                    preview = decoded
                    emit(.previewSync(decoded))
                }
            default: break
            }
        }
    }

    private func applyStatus(_ decoded: DeviceStatus) {
        status = decoded
        if let value = decoded.power { power = value }
        if let value = decoded.wifi { wifi = value }
        emit(.status(decoded))
    }

    private func subscribeToDefaultEvents(duringSetup: Bool = false) async -> Bool {
        do {
            let payload = try RinaCommand.subscribe(preview: true, status: true, power: true, log: false).encode()
            let frame = try await sendUnqueued(type: .cmd, payload: payload, timeout: handshakeTimeout,
                                              aggregateMore: true, duringSetup: duringSetup)
            return try JSONDecoder().decode(CommandReply.self, from: frame.payload).ok
        } catch {
            return false
        }
    }

    // MARK: Incoming

    private func handleIncoming(_ data: Data) async {
        let frames = decoder.feed(data)
        for frame in frames {
            route(frame)
        }
    }

    private func route(_ frame: RinaLinkFrame) {
        // Events (seq == 0, unsolicited).
        if let eventType = RinaLinkMessageType(rawValue: frame.type), frame.seq == 0 {
            switch eventType {
            case .evPreviewSync:
                if let decoded = try? JSONDecoder().decode(PreviewSync.self, from: frame.payload) {
                    preview = decoded
                    emit(.previewSync(decoded))
                }
                return
            case .evStatus:
                if let decoded = try? JSONDecoder().decode(DeviceStatus.self, from: frame.payload) {
                    applyStatus(decoded)
                }
                return
            case .evPower:
                if let decoded = try? JSONDecoder().decode(PowerStatus.self, from: frame.payload) {
                    power = decoded
                    emit(.power(decoded))
                }
                return
            case .evWifi:
                if let decoded = try? JSONDecoder().decode(WifiStatus.self, from: frame.payload) {
                    wifi = decoded
                    emit(.wifi(decoded))
                }
                return
            case .evLog:
                if let decoded = try? JSONDecoder().decode(RinaLogEvent.self, from: frame.payload) {
                    lastLog = decoded
                    emit(.log(decoded))
                }
                return
            case .evWifiScan:
                if let decoded = try? JSONDecoder().decode(WifiScanReply.self, from: frame.payload) {
                    lastWifiScan = decoded
                    emit(.wifiScan(decoded))
                }
                return
            default:
                break
            }
        }

        // A1/quarantine: a reply for a seq we already gave up on (timed out)
        // must not be delivered to a different, newer request that happens to
        // have been assigned the same (reused) seq.
        guard !quarantinedSeqs.contains(frame.seq) else { return }

        // Reply matching by seq, aggregating MORE-flagged chunks only for
        // requests that opted into aggregation (`aggregateMore == true`).
        guard var request = pending[frame.seq], frame.type == request.replyType || frame.isError else {
            return
        }
        request.accumulated.append(frame.payload)
        if request.aggregateMore, frame.isMore {
            pending[frame.seq] = request
            return
        }
        pending.removeValue(forKey: frame.seq)
        request.timeoutTask.cancel()
        if frame.isError {
            let err = (try? JSONDecoder().decode(RinaLinkError.self, from: request.accumulated))
                ?? RinaLinkError(error: "unknown error")
            request.continuation.resume(throwing: err)
        } else {
            // H1: propagate the terminal frame's flags (e.g. MORE meaning "call
            // again with a higher offset") instead of hardcoding 0.
            request.continuation.resume(returning: RinaLinkFrame(type: frame.type, seq: frame.seq, flags: frame.flags, payload: request.accumulated))
        }
    }

    private func failAllPending(_ error: Error) {
        for (_, request) in pending {
            request.timeoutTask.cancel()
            request.sendTask?.cancel()
            request.continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    // MARK: Low-level request/response

    private func nextSequenceNumber() -> UInt8 {
        // Skip seq values still awaiting a reply, or still quarantined from a
        // recent timeout, so a wraparound can't collide with an in-flight (or
        // still-possibly-replying) request.
        var candidate = nextSeq
        var attempts = 0
        while pending[candidate] != nil || quarantinedSeqs.contains(candidate), attempts < 255 {
            candidate = candidate == 255 ? 1 : candidate + 1
            attempts += 1
        }
        nextSeq = candidate == 255 ? 1 : candidate + 1
        return candidate
    }

    private func quarantine(_ seq: UInt8) {
        quarantinedSeqs.insert(seq)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.quarantinedSeqs.remove(seq)
        }
    }

    /// Sends one framed request and awaits its reply. `aggregateMore: true`
    /// (the default) treats `FLAG_MORE` on the terminal frame as "more chunks
    /// of this same reply follow on this seq" and keeps waiting; pass `false`
    /// for messages (e.g. `GET_FACES`) where `FLAG_MORE` instead means "call
    /// again with an updated offset" — the request resolves on the first
    /// frame either way (A1).
    public func send(type: RinaLinkMessageType, payload: Data, timeout: TimeInterval = 5, aggregateMore: Bool = true) async throws -> RinaLinkFrame {
        if let token = BoardOutputContext.session {
            let generation = connectionGeneration
            // Register at the shared wire boundary, including direct setFrame
            // and blob callers that only supply a task-local output lease.
            return try await withOutput(token) {
                try await self.outputPump.run { @MainActor in
                    try self.output.check(token)
                    guard generation == self.connectionGeneration else { throw CancellationError() }
                    let reply = try await self.sendUnqueued(type: type, payload: payload, timeout: timeout, aggregateMore: aggregateMore)
                    try self.output.check(token)
                    return reply
                }
            }
        }
        return try await sendUnqueued(type: type, payload: payload, timeout: timeout, aggregateMore: aggregateMore)
    }

    private func sendUnqueued(type: RinaLinkMessageType, payload: Data, timeout: TimeInterval, aggregateMore: Bool, duringSetup: Bool = false) async throws -> RinaLinkFrame {
        try Task.checkCancellation()
        guard connectionState == .connected || (duringSetup && isEstablishing), let transport else { throw RinaTransportError.notConnected }
        let seq = nextSequenceNumber()
        let requestID = UUID()
        let data = RinaLinkEncoder.encode(type: type, seq: seq, payload: payload)

        let reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RinaLinkFrame, Error>) in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    if let request = self.removePending(seq: seq, requestID: requestID) {
                        self.quarantine(seq)
                        request.sendTask?.cancel()
                        request.continuation.resume(throwing: RinaTransportError.timeout)
                    }
                }
                pending[seq] = PendingRequest(id: requestID,
                                              replyType: type.replyType,
                                              aggregateMore: aggregateMore,
                                              continuation: continuation,
                                              timeoutTask: timeoutTask,
                                              sendTask: nil)
                let sendTask = Task {
                    do {
                        try await transport.send(data)
                    } catch {
                        if let request = self.removePending(seq: seq, requestID: requestID) {
                            request.timeoutTask.cancel()
                            request.continuation.resume(throwing: error)
                        }
                    }
                }
                // This closure is synchronous on MainActor, so cancellation
                // cannot remove `pending[seq]` between registration and storing
                // the task handle. A cancelled queued transport write is now
                // removed before BLE back-pressure clears.
                pending[seq]?.sendTask = sendTask
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPending(seq: seq, requestID: requestID)
            }
        }
        try Task.checkCancellation()
        return reply
    }

    private func removePending(seq: UInt8, requestID: UUID) -> PendingRequest? {
        guard pending[seq]?.id == requestID else { return nil }
        return pending.removeValue(forKey: seq)
    }

    private func cancelPending(seq: UInt8, requestID: UUID) {
        guard let request = removePending(seq: seq, requestID: requestID) else { return }
        request.timeoutTask.cancel()
        request.sendTask?.cancel()
        quarantine(seq)
        request.continuation.resume(throwing: CancellationError())
    }

    // MARK: Typed helpers

    @discardableResult
    public func command(_ cmd: RinaCommand) async throws -> CommandReply {
        let token = BoardOutputContext.session
        return try await commandPump.run { @MainActor in
            if let token { try self.output.check(token) }
            let generation = self.connectionGeneration
            guard let activeTransport = self.transport else {
                throw RinaTransportError.notConnected
            }
            let payload = try cmd.encode()
            let frame = try await BoardOutputContext.$session.withValue(token) {
                try await self.send(type: .cmd, payload: payload)
            }
            let reply = try JSONDecoder().decode(CommandReply.self, from: frame.payload)
            guard reply.ok else { throw RinaTransportError.underlying("面板拒绝指令：\(cmd.name)") }
            self.updateDeviceName(from: reply, for: cmd, transport: activeTransport, generation: generation)
            return reply
        }
    }

    private func refreshDeviceName(for transport: RinaTransport, generation: UUID) async {
        guard self.transport === transport,
              connectionGeneration == generation,
              connectionState == .connected else { return }
        _ = try? await command(.getInfo)
    }

    private func updateDeviceName(
        from reply: CommandReply,
        for command: RinaCommand,
        transport: RinaTransport,
        generation: UUID
    ) {
        switch command {
        case .getInfo, .setDeviceName:
            guard self.transport === transport,
                  connectionGeneration == generation else { return }
            deviceName = reply.name
        default:
            return
        }
    }

    public func getStatus(lite: Bool = false) async throws -> DeviceStatus {
        let session = transportSessionID
        let payload = try JSONSerialization.data(withJSONObject: lite ? ["lite": true] : [:])
        let frame = try await send(type: .getStatus, payload: payload)
        let decoded = try JSONDecoder().decode(DeviceStatus.self, from: frame.payload)
        guard !Task.isCancelled, session == transportSessionID else { throw CancellationError() }
        applyStatus(decoded)
        return decoded
    }

    public func getFrame() async throws -> PackedFrame {
        let generation = connectionGeneration
        let session = output.session
        let frame = try await send(type: .getFrame, payload: Data())
        guard let packed = PackedFrame(data: frame.payload) else {
            throw RinaTransportError.invalidResponse
        }
        guard generation == connectionGeneration, session == output.session else { throw CancellationError() }
        currentFrame = packed
        return packed
    }

    @discardableResult
    public func setFrame(_ packed: PackedFrame, playback: Playback, reason: String, outputSession: UUID? = nil) async throws -> CommandReply {
        let token = outputSession ?? BoardOutputContext.session ?? output.claim(.manual)
        let reply = try await framePump.run { @MainActor in
            try self.output.check(token)
            var payload = Data()
            payload.append(playback.rawValue)
            let reasonBytes = Array(reason.utf8.prefix(255))
            payload.append(UInt8(reasonBytes.count))
            payload.append(contentsOf: reasonBytes)
            payload.append(packed.data)
            let frame = try await BoardOutputContext.$session.withValue(token) {
                try await self.send(type: .setFrame, payload: payload)
            }
            let reply = try JSONDecoder().decode(CommandReply.self, from: frame.payload)
            guard reply.ok else { throw RinaTransportError.underlying("面板拒绝表情") }
            return reply
        }
        try output.check(token)
        currentFrame = packed
        return reply
    }

    public func getPreviewSync() async throws -> PreviewSync {
        let session = transportSessionID
        let frame = try await send(type: .getPreviewSync, payload: Data())
        let decoded = try JSONDecoder().decode(PreviewSync.self, from: frame.payload)
        guard !Task.isCancelled, session == transportSessionID else { throw CancellationError() }
        preview = decoded
        emit(.previewSync(decoded))
        return decoded
    }

    public func getScrollMeta() async throws -> ScrollMeta {
        let frame = try await send(type: .getScrollMeta, payload: Data())
        return try JSONDecoder().decode(ScrollMeta.self, from: frame.payload)
    }

    /// `GET_FACES`: the reply payload is `[gen: UInt32 LE][file bytes from
    /// offset]`. The board may require several request/reply round-trips
    /// (one `send()` each) to deliver the whole file — the terminal frame of
    /// each round-trip carries `FLAG_MORE` while more remain, at which point
    /// the next request must include `{"offset":n,"gen":g}` so the board can
    /// detect a concurrent mutation (HTTP 409-equivalent error) and restart.
    public func getFaces() async throws -> Data {
        var result = Data()
        var offset = 0
        var gen: UInt32?
        var didRestart = false
        while true {
            var payloadDict: [String: Any] = ["offset": offset]
            if let gen { payloadDict["gen"] = gen }
            let payload = try JSONSerialization.data(withJSONObject: payloadDict)
            do {
                // A1: each GET_FACES request/reply is its own one-frame
                // round-trip; FLAG_MORE on the terminal frame means "call
                // again with a higher offset", not "more frames on this seq".
                let frame = try await send(type: .getFaces, payload: payload, aggregateMore: false)
                guard frame.payload.count >= 4 else { break }
                let genBytes = [UInt8](frame.payload.prefix(4))
                let frameGen = UInt32(genBytes[0])
                    | (UInt32(genBytes[1]) << 8)
                    | (UInt32(genBytes[2]) << 16)
                    | (UInt32(genBytes[3]) << 24)
                if gen == nil { gen = frameGen }
                result.append(frame.payload.suffix(from: frame.payload.index(frame.payload.startIndex, offsetBy: 4)))
                offset = result.count
                if !frame.isMore { break }
            } catch let error as RinaLinkError {
                if error.code == 409, !didRestart {
                    didRestart = true
                    result = Data()
                    offset = 0
                    gen = nil
                    continue
                }
                throw error
            }
        }
        return result
    }

    public enum BlobKind: String { case scroll, faces, scrollBitmap = "scroll_bitmap" }

    public func uploadBlob(
        kind: BlobKind,
        meta: [String: Any],
        data: Data,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> Data {
        let token = BoardOutputContext.session
        return try await blobPump.run { @MainActor in
            if let token { try self.output.check(token) }
            let generation = self.connectionGeneration
            do {
                return try await BoardOutputContext.$session.withValue(token) {
                    try await self.uploadBlobSerial(kind: kind, meta: meta, data: data, onProgress: onProgress)
                }
            } catch {
                // Keep the blob slot until cleanup completes. This task must
                // survive the cancelled producer and must not inherit its lease.
                let cleanup = Task { @MainActor in
                    guard generation == self.connectionGeneration,
                          self.connectionState == .connected else { return }
                    do {
                        _ = try await BoardOutputContext.$session.withValue(nil) {
                            try await self.send(type: .blobAbort, payload: Data(), timeout: 2)
                        }
                    } catch {
                        guard generation == self.connectionGeneration else { return }
                        // An unacknowledged abort leaves ownership unknown.
                        // Close this carrier so firmware releases its owner;
                        // the normal transport-state handler reconnects it.
                        self.connectionState = .disconnected
                        self.failAllPending(RinaTransportError.notConnected)
                        self.transport?.disconnect()
                    }
                }
                await cleanup.value
                throw error
            }
        }
    }

    private func uploadBlobSerial(
        kind: BlobKind,
        meta: [String: Any],
        data: Data,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> Data {
        var beginMeta = meta
        beginMeta["kind"] = kind.rawValue
        beginMeta["totalBytes"] = data.count
        let beginPayload = try JSONSerialization.data(withJSONObject: beginMeta)
        let beginFrame = try await send(type: .blobBegin, payload: beginPayload)
        let begin = try JSONDecoder().decode(BlobBeginReply.self, from: beginFrame.payload)

        var offset = begin.offset ?? 0
        var rawChunkMax = (begin.chunkMax ?? 0) > 0 ? (begin.chunkMax ?? 0) : RinaLinkConstants.blobChunkMaxTCP
        // Use the transport's own preferred chunk size (MTU-derived for BLE)
        // when it's smaller than what the board offered.
        if let preferred = transport?.preferredChunkBytes, preferred > 0 {
            rawChunkMax = min(rawChunkMax, preferred)
        }
        // Leave room for the 4-byte offset header prepended to each chunk payload.
        var chunkMax = min(rawChunkMax, RinaLinkConstants.maxPayloadBytes - 4)
        if kind == .scroll {
            // A2: raw-frame scroll chunks must land on PackedFrame boundaries
            // so the firmware never sees a partial 47-byte frame.
            let aligned = (chunkMax / PackedFrame.byteCount) * PackedFrame.byteCount
            chunkMax = aligned > 0 ? aligned : PackedFrame.byteCount
        }
        var didResync = false
        while offset < data.count {
            let end = min(offset + chunkMax, data.count)
            var chunkPayload = Data()
            var offsetLE = UInt32(offset).littleEndian
            withUnsafeBytes(of: &offsetLE) { chunkPayload.append(contentsOf: $0) }
            chunkPayload.append(data.subdata(in: offset..<end))
            do {
                let chunkFrame = try await send(type: .blobChunk, payload: chunkPayload)
                let chunkReply = try JSONDecoder().decode(BlobChunkReply.self, from: chunkFrame.payload)
                let newOffset = chunkReply.offset ?? end
                guard newOffset > offset else {
                    throw RinaTransportError.invalidResponse
                }
                offset = newOffset
                onProgress?(Double(offset) / Double(max(1, data.count)))
            } catch let error as RinaLinkError {
                if error.code == 400, !didResync, let expected = error.expectedOffset {
                    didResync = true
                    offset = expected
                    continue
                }
                throw error
            }
        }

        let endMeta: [String: Any] = (kind == .scroll || kind == .scrollBitmap) ? ["start": true] : [:]
        let endPayload = try JSONSerialization.data(withJSONObject: endMeta)
        let endFrame = try await send(type: .blobEnd, payload: endPayload)
        return endFrame.payload
    }

    public func startScrollUpload(
        frames: [PackedFrame],
        fps: Double,
        timelineId: String,
        fontId: String,
        generatorVersion: String,
        sourceText: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> ScrollUploadReply {
        var data = Data()
        for frame in frames { data.append(frame.data) }
        let meta: [String: Any] = [
            "fps": fps,
            "totalFrames": frames.count,
            "timelineId": timelineId,
            "fontId": fontId,
            "generatorVersion": generatorVersion,
            "sourceText": sourceText,
        ]
        let replyData = try await uploadBlob(kind: .scroll, meta: meta, data: data, onProgress: onProgress)
        return try JSONDecoder().decode(ScrollUploadReply.self, from: replyData)
    }

    /// `BLOB kind:"scroll_bitmap"` (RINALINK_PROTOCOL_V1 §7.1): uploads the
    /// rasterised bitmap instead of every expanded frame — the firmware
    /// expands offsets into packed frames itself. Verifies the reply's
    /// `rotation`/`frames` against the timeline the client rasterised so a
    /// firmware/client rasterisation mismatch is caught before it desyncs the
    /// local preview; callers should fall back to `startScrollUpload` on
    /// `ScrollUploadError.timelineMismatch` for older firmware.
    public func startScrollBitmapUpload(
        timeline: ScrollTimeline,
        fps: Int,
        sourceText: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> ScrollUploadReply {
        let bytes = timeline.bitmap.packedBytes()
        var meta: [String: Any] = [
            "width": timeline.bitmapWidth,
            "rows": MatrixGeometry.rows,
            "fps": fps,
            "timelineId": timeline.timelineId,
            "fontId": ScrollRasterizer.fontId,
            "generatorVersion": ScrollRasterizer.generatorVersion,
        ]
        if sourceText.utf8.count <= 4096 {
            meta["sourceText"] = sourceText
        }
        let replyData = try await uploadBlob(kind: .scrollBitmap, meta: meta, data: bytes, onProgress: onProgress)
        let reply = try JSONDecoder().decode(ScrollUploadReply.self, from: replyData)
        guard reply.rotation == timeline.rotation, reply.frames == timeline.frameCount else {
            throw ScrollUploadError.timelineMismatch(
                expected: (frames: timeline.frameCount, rotation: timeline.rotation),
                got: (frames: reply.frames ?? -1, rotation: reply.rotation ?? -1)
            )
        }
        return reply
    }

    public func saveFaces(document: FaceDocument) async throws {
        let data = try document.encoded()
        _ = try await uploadBlob(kind: .faces, meta: [:], data: data)
    }

    // MARK: Incremental saved-face commands (§7.2)

    /// Set after every face-op reply: whether the reply's `gen` matched the
    /// caller's locally tracked "expected next gen" (no other client mutated
    /// `saved_faces.json` concurrently), so callers can apply their optimistic
    /// local mutation instead of re-fetching the whole document via `getFaces()`.
    public private(set) var lastFaceOpGenMatchedExpectation = true
    private var facesGen: Int?

    @discardableResult
    public func faceRename(id: String, name: String) async throws -> FaceOpReply {
        try await sendFaceOp(.faceRename(id: id, name: name))
    }

    @discardableResult
    public func faceReorder(ids: [String]) async throws -> FaceOpReply {
        try await sendFaceOp(.faceReorder(ids: ids))
    }

    @discardableResult
    public func faceDelete(id: String) async throws -> FaceOpReply {
        try await sendFaceOp(.faceDelete(id: id))
    }

    @discardableResult
    public func faceUpsert(_ face: FaceUpsertPayload) async throws -> FaceOpReply {
        try await sendFaceOp(.faceUpsert(face: face))
    }

    @discardableResult
    public func facesClearUser() async throws -> FaceOpReply {
        try await sendFaceOp(.facesClearUser)
    }

    private func sendFaceOp(_ cmd: RinaCommand) async throws -> FaceOpReply {
        let payload = try cmd.encode()
        let reply: FaceOpReply = try await commandPump.run { @MainActor in
            let frame = try await self.send(type: .cmd, payload: payload)
            return try JSONDecoder().decode(FaceOpReply.self, from: frame.payload)
        }
        if let gen = reply.gen {
            let expected = facesGen.map { $0 + 1 }
            lastFaceOpGenMatchedExpectation = (expected == nil) || (gen == expected)
            facesGen = gen
        }
        return reply
    }

    // MARK: Wi-Fi helpers (§4)

    /// `wifi_scan`: returns the scan results directly (the generic `command()`
    /// helper only decodes `CommandReply`, which drops the `networks` field).
    /// The firmware may reply synchronously with `{ok,networks:[...]}` (legacy
    /// behavior) or immediately with `{ok,scanning:true}` and push the real
    /// results a moment later as an `EV_WIFI_SCAN` (0x95) event — in that case
    /// this waits (up to 8s) for the next `.wifiScan` event. The event stream
    /// is subscribed to *before* the command is sent so a fast reply can't
    /// race the subscription.
    @discardableResult
    public func wifiScan() async throws -> WifiScanReply {
        let (subID, stream) = subscribeEvents()
        // A6: guarantee the subscription is torn down on every exit path
        // (synchronous reply, timeout, or an EV_WIFI_SCAN match) — otherwise
        // the synchronous-reply fast path below would leak the continuation
        // in `eventContinuations` forever (it's never iterated in that case).
        defer { eventContinuations.removeValue(forKey: subID) }
        let decoded = try await commandPump.run { @MainActor in
            let payload = try RinaCommand.wifiScan.encode()
            let frame = try await self.send(type: .cmd, payload: payload)
            return try JSONDecoder().decode(WifiScanReply.self, from: frame.payload)
        }
        if decoded.networks != nil {
            lastWifiScan = decoded
            return decoded
        }
        let result: WifiScanReply? = await withTaskGroup(of: WifiScanReply?.self) { group in
            group.addTask {
                for await event in stream {
                    if case .wifiScan(let reply) = event { return reply }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return result ?? decoded
    }

    /// `wifi_status`: refreshes `wifi` immediately instead of waiting for the
    /// next `EV_WIFI` push.
    @discardableResult
    public func refreshWifiStatus() async throws -> WifiStatus {
        let decoded = try await commandPump.run { @MainActor in
            let payload = try RinaCommand.wifiStatus.encode()
            let frame = try await self.send(type: .cmd, payload: payload)
            return try JSONDecoder().decode(WifiStatus.self, from: frame.payload)
        }
        wifi = decoded
        return decoded
    }
}

/// Errors specific to `startScrollBitmapUpload`.
public enum ScrollUploadError: Error, Sendable, Equatable {
    /// The firmware's `BLOB_END` reply for `kind:"scroll_bitmap"` disagreed
    /// with the client's own rasterisation (`frames`/`rotation`) — treated
    /// like a timeline identity mismatch. Callers should fall back to
    /// `startScrollUpload` (raw frames) for firmware that predates §7.1.
    case timelineMismatch(expected: (frames: Int, rotation: Int), got: (frames: Int, rotation: Int))

    public static func == (lhs: ScrollUploadError, rhs: ScrollUploadError) -> Bool {
        switch (lhs, rhs) {
        case (.timelineMismatch(let le, let lg), .timelineMismatch(let re, let rg)):
            return le.frames == re.frames && le.rotation == re.rotation
                && lg.frames == rg.frames && lg.rotation == rg.rotation
        }
    }
}

/// Errors specific to the rate-limiting pump.
public enum RatePumpError: Error, Sendable {
    /// The operation was evicted from the FIFO queue (drop-oldest) before it
    /// got a chance to run.
    case dropped
}

/// A depth-`N` FIFO rate limiter shared by frame sends and commands (D6):
/// enqueued operations run one at a time (never concurrently) on a single
/// serial worker, spaced at least `minInterval` apart at the start of each
/// operation. When the queue is full, the *oldest not-yet-started* operation
/// is evicted and its awaiting caller is thrown `RatePumpError.dropped` — the
/// newest caller is never the one dropped, and an operation that has already
/// started running can never be evicted.
actor RatePump {
    private let minInterval: TimeInterval
    private let depth: Int
    private var lastStart: Date = .distantPast
    private var queue: [QueueEntry] = []
    private var isDraining = false
    private var isBusy = false

    private struct QueueEntry {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    init(minInterval: TimeInterval, depth: Int) {
        self.minInterval = minInterval
        self.depth = depth
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await waitForTurn()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            finishTurn()
            return result
        } catch {
            finishTurn()
            throw error
        }
    }

    /// Honours cancellation of the calling `Task` while an operation is still
    /// queued (not yet started): the entry is pulled from the queue and its
    /// continuation resumed with `CancellationError` instead of eventually
    /// running the (now-pointless) operation.
    private func waitForTurn() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.append(QueueEntry(id: id, continuation: continuation))
                while queue.count > depth {
                    let dropped = queue.removeFirst()
                    dropped.continuation.resume(throwing: RatePumpError.dropped)
                }
                drainIfNeeded()
            }
        } onCancel: {
            Task { await self.cancelQueued(id) }
        }
    }

    private func cancelQueued(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let entry = queue.remove(at: index)
        entry.continuation.resume(throwing: CancellationError())
    }

    private func finishTurn() {
        isBusy = false
        drainIfNeeded()
    }

    private func drainIfNeeded() {
        guard !isDraining, !isBusy, !queue.isEmpty else { return }
        isDraining = true
        Task { await self.drainLoop() }
    }

    private func drainLoop() async {
        while !queue.isEmpty, !isBusy {
            let elapsed = Date().timeIntervalSince(lastStart)
            if elapsed < minInterval {
                let waitNanos = UInt64((minInterval - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNanos)
                continue
            }
            let next = queue.removeFirst()
            isBusy = true
            lastStart = Date()
            next.continuation.resume()
        }
        isDraining = false
    }
}
