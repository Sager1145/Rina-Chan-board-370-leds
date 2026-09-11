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
    case raw(RinaLinkFrame)
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

    public private(set) var connectionState: BoardConnectionState = .disconnected
    public private(set) var transportKind: TransportKind?

    public private(set) var status: DeviceStatus?
    public private(set) var preview: PreviewSync?
    public private(set) var power: PowerStatus?
    public private(set) var wifi: WifiStatus?
    public private(set) var currentFrame: PackedFrame = PackedFrame()
    public private(set) var lastError: String?
    public private(set) var lastLog: RinaLogEvent?
    public private(set) var lastWifiScan: WifiScanReply?

    // MARK: Private

    private var eventContinuations: [UUID: AsyncStream<BoardEvent>.Continuation] = [:]
    private var transport: RinaTransport?
    private let decoder = RinaLinkDecoder()
    private var nextSeq: UInt8 = 1
    private var pending: [UInt8: PendingRequest] = [:]
    private var incomingTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    // Rate limiting (FEATURE_INVENTORY D6): frames >=20ms apart depth 6 drop-oldest,
    // commands >=120ms apart depth 4 drop-oldest.
    private let framePump = RatePump(minInterval: 0.020, depth: 6)
    private let commandPump = RatePump(minInterval: 0.120, depth: 4)

    private struct PendingRequest {
        let replyType: UInt8
        var accumulated = Data()
        let continuation: CheckedContinuation<RinaLinkFrame, Error>
        let timeoutTask: Task<Void, Never>
    }

    public init() {}

    // MARK: Connection lifecycle

    public func connect(using transport: RinaTransport) async {
        reconnectTask?.cancel()
        pingTask?.cancel()
        // H6: tear down any previous transport/tasks before swapping in the new one.
        self.transport?.disconnect()
        stateTask?.cancel()
        incomingTask?.cancel()
        failAllPending(RinaTransportError.cancelled)

        self.transport = transport
        self.transportKind = transport.kind
        connectionState = .connecting
        decoder.reset()

        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in transport.stateStream() {
                await self.handleTransportState(state)
            }
        }

        incomingTask = Task { [weak self] in
            guard let self else { return }
            for await data in transport.incomingStream() {
                await self.handleIncoming(data)
            }
        }

        do {
            try await transport.connect()
            reconnectAttempts = 0
            startPingLoopIfNeeded()
            // Make the default event subscriptions explicit rather than relying
            // on firmware defaults.
            _ = try? await command(.subscribe(preview: true, status: true, power: true, log: false))
        } catch {
            connectionState = .failed(String(describing: error))
        }
    }

    public func disconnect() {
        reconnectTask?.cancel()
        pingTask?.cancel()
        stateTask?.cancel()
        incomingTask?.cancel()
        transport?.disconnect()
        transport = nil
        connectionState = .disconnected
        failAllPending(RinaTransportError.notConnected)
    }

    private func handleTransportState(_ state: TransportState) async {
        switch state {
        case .idle, .connecting:
            connectionState = .connecting
        case .connected:
            connectionState = .connected
            reconnectAttempts = 0
        case .disconnected:
            connectionState = .disconnected
            failAllPending(RinaTransportError.notConnected)
            attemptReconnect()
        case .failed(let message):
            connectionState = .failed(message)
            lastError = message
            failAllPending(RinaTransportError.underlying(message))
            attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard let transport else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            connectionState = .failed("重连失败，已达到最大尝试次数")
            return
        }
        reconnectTask?.cancel()
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        connectionState = .reconnecting(attempt: attempt)
        let delay = min(30.0, pow(2.0, Double(attempt)))
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? await transport.connect()
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
                _ = try? await self.send(type: .ping, payload: Data(), timeout: 5)
            }
        }
    }

    // MARK: Event stream

    /// Multi-consumer stream of unsolicited board events (log lines, pushed
    /// status/preview/power/wifi, and Wi-Fi scan results). Each call returns
    /// an independent stream; the underlying continuation is removed when
    /// that stream's consumer stops iterating.
    public func events() -> AsyncStream<BoardEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func emit(_ event: BoardEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
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
                    status = decoded
                    emit(.status(decoded))
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

        // Reply matching by seq, aggregating MORE-flagged chunks.
        guard var request = pending[frame.seq], frame.type == request.replyType || frame.isError else {
            return
        }
        request.accumulated.append(frame.payload)
        if frame.isMore {
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
            request.continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    // MARK: Low-level request/response

    private func nextSequenceNumber() -> UInt8 {
        // Skip seq values still awaiting a reply so a wraparound can't collide
        // with an in-flight request.
        var candidate = nextSeq
        var attempts = 0
        while pending[candidate] != nil, attempts < 255 {
            candidate = candidate == 255 ? 1 : candidate + 1
            attempts += 1
        }
        nextSeq = candidate == 255 ? 1 : candidate + 1
        return candidate
    }

    /// Sends one framed request and awaits its (possibly chunked) reply.
    public func send(type: RinaLinkMessageType, payload: Data, timeout: TimeInterval = 5) async throws -> RinaLinkFrame {
        guard let transport else { throw RinaTransportError.notConnected }
        let seq = nextSequenceNumber()
        let data = RinaLinkEncoder.encode(type: type, seq: seq, payload: payload)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RinaLinkFrame, Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if let request = self.pending.removeValue(forKey: seq) {
                    request.continuation.resume(throwing: RinaTransportError.timeout)
                }
            }
            pending[seq] = PendingRequest(replyType: type.replyType, continuation: continuation, timeoutTask: timeoutTask)
            Task {
                do {
                    try await transport.send(data)
                } catch {
                    if let request = self.pending.removeValue(forKey: seq) {
                        request.timeoutTask.cancel()
                        request.continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: Typed helpers

    @discardableResult
    public func command(_ cmd: RinaCommand) async throws -> CommandReply {
        try await commandPump.run {
            let payload = try cmd.encode()
            let frame = try await self.send(type: .cmd, payload: payload)
            return try JSONDecoder().decode(CommandReply.self, from: frame.payload)
        }
    }

    public func getStatus(lite: Bool = false) async throws -> DeviceStatus {
        let payload = try JSONSerialization.data(withJSONObject: lite ? ["lite": true] : [:])
        let frame = try await send(type: .getStatus, payload: payload)
        let decoded = try JSONDecoder().decode(DeviceStatus.self, from: frame.payload)
        status = decoded
        return decoded
    }

    public func getFrame() async throws -> PackedFrame {
        let frame = try await send(type: .getFrame, payload: Data())
        guard let packed = PackedFrame(data: frame.payload) else {
            throw RinaTransportError.invalidResponse
        }
        currentFrame = packed
        return packed
    }

    @discardableResult
    public func setFrame(_ packed: PackedFrame, playback: Playback, reason: String) async throws -> CommandReply {
        let reply = try await framePump.run {
            var payload = Data()
            payload.append(playback.rawValue)
            let reasonBytes = Array(reason.utf8.prefix(255))
            payload.append(UInt8(reasonBytes.count))
            payload.append(contentsOf: reasonBytes)
            payload.append(packed.data)
            let frame = try await self.send(type: .setFrame, payload: payload)
            return try JSONDecoder().decode(CommandReply.self, from: frame.payload)
        }
        currentFrame = packed
        return reply
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
                let frame = try await send(type: .getFaces, payload: payload)
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
        chunkFrames: Int? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> Data {
        var beginMeta = meta
        beginMeta["kind"] = kind.rawValue
        beginMeta["totalBytes"] = data.count
        let beginPayload = try JSONSerialization.data(withJSONObject: beginMeta)
        let beginFrame = try await send(type: .blobBegin, payload: beginPayload)
        let begin = try JSONDecoder().decode(BlobBeginReply.self, from: beginFrame.payload)

        var offset = begin.offset ?? 0
        let rawChunkMax = (begin.chunkMax ?? 0) > 0 ? (begin.chunkMax ?? 0) : RinaLinkConstants.blobChunkMaxTCP
        // Leave room for the 4-byte offset header prepended to each chunk payload.
        let chunkMax = min(rawChunkMax, RinaLinkConstants.maxPayloadBytes - 4)
        while offset < data.count {
            let end = min(offset + chunkMax, data.count)
            var chunkPayload = Data()
            var offsetLE = UInt32(offset).littleEndian
            withUnsafeBytes(of: &offsetLE) { chunkPayload.append(contentsOf: $0) }
            chunkPayload.append(data.subdata(in: offset..<end))
            let chunkFrame = try await send(type: .blobChunk, payload: chunkPayload)
            let chunkReply = try JSONDecoder().decode(BlobChunkReply.self, from: chunkFrame.payload)
            offset = chunkReply.offset ?? end
            onProgress?(Double(offset) / Double(max(1, data.count)))
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
        let reply: FaceOpReply = try await commandPump.run {
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
        let stream = events()
        let decoded = try await commandPump.run {
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
        let decoded = try await commandPump.run {
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
private actor RatePump {
    private let minInterval: TimeInterval
    private let depth: Int
    private var lastStart: Date = .distantPast
    private var queue: [QueueEntry] = []
    private var isDraining = false
    private var isBusy = false

    private struct QueueEntry {
        let continuation: CheckedContinuation<Void, Error>
    }

    init(minInterval: TimeInterval, depth: Int) {
        self.minInterval = minInterval
        self.depth = depth
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await waitForTurn()
        do {
            let result = try await operation()
            finishTurn()
            return result
        } catch {
            finishTurn()
            throw error
        }
    }

    private func waitForTurn() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.append(QueueEntry(continuation: continuation))
            while queue.count > depth {
                let dropped = queue.removeFirst()
                dropped.continuation.resume(throwing: RatePumpError.dropped)
            }
            drainIfNeeded()
        }
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
