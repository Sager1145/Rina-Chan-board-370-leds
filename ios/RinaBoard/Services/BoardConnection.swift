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

/// Per-connection callbacks for a group's control primary. `BoardConnection`
/// invokes them inside `command` / `setFrame` and does not await them, and
/// does not decide which commands or frames are mirrored.
@MainActor
public final class BoardOutboundHook {
    public let willSendCommand: (RinaCommand, Bool) -> Void
    public let didApplyFace: (CommandReply, RinaCommand) -> Void
    public let willSendFrame: (PackedFrame, Playback, String) -> Void

    public init(
        willSendCommand: @escaping (RinaCommand, Bool) -> Void,
        didApplyFace: @escaping (CommandReply, RinaCommand) -> Void,
        willSendFrame: @escaping (PackedFrame, Playback, String) -> Void
    ) {
        self.willSendCommand = willSendCommand
        self.didApplyFace = didApplyFace
        self.willSendFrame = willSendFrame
    }
}

/// A locally reachable carrier for the same physical board. The handshake
/// must report `expectedBoardIdentity` before this carrier can become ready.
public struct BoardReconnectCandidate {
    public let transport: any RinaTransport
    public let expectedBoardIdentity: String?

    public init(transport: any RinaTransport, expectedBoardIdentity: String?) {
        self.transport = transport
        self.expectedBoardIdentity = expectedBoardIdentity
    }
}

/// Fields from a setup `get_info` reply that decoded. Valid only for `generation`.
struct HandshakeDeviceInfo: Equatable {
    let generation: UUID
    let name: String?
    let defaultName: String?
    let customName: Bool?
    let fw: String?
    let build: String?
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
    /// Installed on a group's control primary only. `command(_:)` and
    /// `setFrame(_:playback:reason:outputSession:)` call it inside their pumps
    /// and do not await it. Nil on every sink. Not called from
    /// `requestReliable`, `send`, or `sendUnqueued`.
    @ObservationIgnored public weak var outboundHook: BoardOutboundHook?
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
    /// The board's MAC-derived id (`wifi.boardId`, or the suffix of
    /// `get_info.defaultName`), fixed when the handshake completes. Unlike a
    /// name or an address it is the same over every transport and unique per
    /// board. Nil for firmware that reports neither.
    public private(set) var boardIdentity: String? {
        didSet {
            if let boardIdentity { lastKnownBoardIdentity = boardIdentity }
        }
    }
    /// The last non-nil `boardIdentity` this connection object has ever
    /// reported, surviving `clearBoardSnapshot()`/`disconnect()` (unlike
    /// `boardIdentity` itself). Group-member resolution
    /// (`BoardGroupCoordinator.session(for:)` and the control fan-out) must
    /// match against this, not `boardIdentity`, so a just-disconnected
    /// primary/sink doesn't momentarily look like a different board.
    public private(set) var lastKnownBoardIdentity: String?
    private var setupDefaultName: String?
    /// Setup `get_info` fields, kept only when that reply decoded. `generation`
    /// is the connection generation of the handshake that produced them.
    private(set) var handshakeDeviceInfo: HandshakeDeviceInfo?
    /// Remembers, per transport fallback key (the `ble:<uuid>` / `wifi:<host>`
    /// key `boardKey` would fall back to without an identity), the last
    /// `board:<id>`-worthy identity this connection object obtained on that
    /// same fallback key. A same-board reconnect whose handshake reads
    /// (`wifi.boardId` / `get_info.defaultName`) both time out reuses it
    /// instead of falling back to the transport-derived key, which would look
    /// like a different board to `ControlViewModel.boardDidChange(to:)` and
    /// discard the in-progress face draft. Never consulted across a different
    /// fallback key (a genuinely different board over the same transport kind).
    private var rememberedIdentityByFallbackKey: [String: String] = [:]
    /// Set true this `establish()` attempt when `GET_STATUS` itself failed to
    /// reply (or didn't decode) — as opposed to replying without a `wifi`/
    /// `boardId` field, which is a legitimate "this board has no id" answer
    /// and must never trigger reuse (fix for board-identity-flip §a).
    private var setupStatusReadFailed = false
    /// Same as `setupStatusReadFailed`, for the `get_info` round trip that
    /// reads `defaultName`.
    private var setupGetInfoReadFailed = false
    /// RinaLink protocol version reported by `CMD get_info` for this connection.
    public private(set) var protocolVersion: Int?
    /// This board's `get_info.bootId` (BOARD_GROUP_SPEC §1.1): 8 lowercase hex
    /// chars, changes on every boot/deep-sleep wake. `nil` before the first
    /// `get_info` round trip completes, or on firmware that predates it.
    public private(set) var bootId: String?
    /// This board's `get_info.caps` (BOARD_GROUP_SPEC §1.1). Empty (never
    /// nil) before the first `get_info` round trip, or on firmware that
    /// predates it — `supports(_:)` is `false` either way.
    public private(set) var deviceInfoCaps: [String] = []

    /// `true` iff the last `get_info` reported `cap` (BOARD_GROUP_SPEC §1.1/§2).
    /// Callers must check this before using any board-group command and never
    /// silently fall back while claiming "synchronized".
    public func supports(_ cap: BoardCapability) -> Bool {
        deviceInfoCaps.contains(cap.rawValue)
    }

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
    /// The SoftAP SSID this session expects to be talking to over a `.hotspot`
    /// transport, set by the connect path (`ConnectionViewModel.connectHotspot`
    /// / `connectSavedBoard`). Every board's SoftAP shares one IP, so after
    /// each hotspot connect/reconnect this is checked against the board's own
    /// reported identity (`BoardIdentity.matches`) — a mismatch means the
    /// phone's Wi-Fi silently moved to a *different* board's hotspot. `nil`
    /// (unset, or cleared on a non-hotspot connect) skips the check.
    public var expectedHotspotSSID: String?

    /// `true` once a `disconnect(userInitiated: true)` call has torn this
    /// connection down and no successful `connect(using:)` has happened
    /// since. `GroupAutoConnector` checks this before auto-redialing a group
    /// member: a person tapping "断开" must not be immediately re-dialed in
    /// the background. Cleared by the next `connect(using:)` call (a manual
    /// reconnect, from the saved-board list or the per-member "连接" button)
    /// — never by this object's own internal retry loop, which never calls
    /// the public `connect(using:)` entry point.
    public private(set) var wasUserDisconnected = false
    public private(set) var isAutomaticReconnectEnabled = true
    public var canRetry: Bool {
        connectionState != .connected && (transport != nil || originalReconnectTransport != nil)
    }
    /// Identity pinned for this connection attempt or proven by its handshake.
    /// A past session's `lastKnownBoardIdentity` is deliberately excluded:
    /// an explicit switch to an unidentified board must not borrow its peers.
    var reconnectCandidateIdentity: String? {
        originalReconnectIdentity ?? expectedBoardIdentity ?? boardIdentity
    }

    /// Read the last live snapshot before a dropped carrier clears it. The
    /// provider supplies local same-board alternatives without changing the
    /// user's saved transport preference or the active board selection.
    @ObservationIgnored public var reconnectCandidatesProvider:
        (@MainActor (TransportKind?, WifiStatus?) -> [BoardReconnectCandidate])?

    /// Explicit hook for `GroupAutoConnector`/UI code that wants to clear the
    /// user-disconnect block without an intervening successful connect, e.g.
    /// re-targeting the group at this board again.
    public func resetUserDisconnected() {
        wasUserDisconnected = false
    }

    // MARK: Private

    private var eventContinuations: [UUID: AsyncStream<BoardEvent>.Continuation] = [:]
    private var transport: RinaTransport?
    private let decoder = RinaLinkDecoder()
    private let broker = RinaRequestBroker()
    /// Test-only hook (PR-15 measurement): when non-nil, `handleIncoming`
    /// calls it once per incoming chunk with `(overall, dispatchOnly, bytes)`,
    /// timed over exactly the same regions as the `BoardIncomingDecode`/
    /// `BoardIncomingDispatch` signposts below — `overall` covers
    /// `decoder.feed` + the route loop, `dispatchOnly` covers just the route
    /// loop. `nil` in production; costs one nil check per chunk when unset,
    /// no clock reads. Statics on an `@MainActor` type are themselves
    /// `@MainActor`-isolated, so this needs no extra synchronization.
    static var incomingDecodeProbe: ((Duration, Duration, Int) -> Void)?
    private static let incomingDecodeClock = ContinuousClock()
    /// Test/diagnostic view of how many retired sequence numbers are still quarantined.
    var quarantinedSequenceCount: Int { broker.quarantinedSequenceCount }
    /// Cumulative number of times a seq was quarantined (tests/diagnostics).
    var quarantineEventCount: Int { broker.quarantineEventCount }
    private var incomingTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectCandidates: [BoardReconnectCandidate] = []
    private var reconnectCandidateIndex = 0
    private var manualRetryEpoch = UUID()
    private var isManualRetryInProgress = false
    private var originalReconnectTransport: (any RinaTransport)?
    private var originalReconnectIdentity: String?
    private var originalHotspotSSID: String?
    private var isReconnectAttempt = false
    private var currentReconnectIsOriginal = false
    private var connectionReadyHandler: (@MainActor () -> Void)?
    private var expectedBoardIdentity: String?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var transportSessionID = UUID()
    private var isEstablishing = false
    private var establishmentError: String?
    private var reconnectDelay: (Int) -> TimeInterval = { min(30, pow(2, Double($0))) }
    private var handshakeTimeout: TimeInterval = 5
    private static let eventBufferLimit = 256
    private static let maxFacesDocumentBytes = 256 * 1024

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

    public init() {
        installBrokerHooks()
    }

    init(reconnectDelay: @escaping (Int) -> TimeInterval, handshakeTimeout: TimeInterval = 5) {
        self.reconnectDelay = reconnectDelay
        self.handshakeTimeout = handshakeTimeout
        installBrokerHooks()
    }

    /// Wires the broker's quarantine-overflow signal to this connection's own
    /// reconnect logic. Called once from both initializers so `broker` has a
    /// hook installed for the object's entire life.
    private func installBrokerHooks() {
        broker.onQuarantineOverflow = { [weak self] in
            guard let self else { return }
            let session = self.transportSessionID
            // Leave the current continuation cleanup before resetting the
            // carrier. The session check coalesces concurrent cancellations
            // into one reconnect.
            Task { @MainActor [weak self] in
                guard let self, self.transportSessionID == session,
                      self.connectionState == .connected,
                      self.broker.isQuarantineOverThreshold else { return }
                self.connectionFailed(RinaTransportError.sequenceSpaceExhausted.localizedDescription)
            }
        }
    }

    // MARK: Connection lifecycle

    /// Swaps in `transport` as the active transport and connects it. Returns
    /// `true` after the handshake and initial snapshot reads, `false` on failure.
    /// `onReady` runs once after setup succeeds, including when an internal
    /// retry is the successful attempt, and before `.connected` is published.
    /// Kept `@discardableResult` so call sites that only poll `connectionState`
    /// afterwards keep working unmodified.
    @discardableResult
    public func connect(
        using transport: RinaTransport,
        expectedBoardIdentity: String? = nil,
        onReady: (@MainActor () -> Void)? = nil
    ) async -> Bool {
        disconnect()
        // An explicit connection starts a new carrier epoch. Callbacks from the
        // old incoming stream are session-gated, so its retired IDs can go.
        broker.resetQuarantine()
        output.invalidate()
        connectionGeneration = UUID()
        clearBoardSnapshot()
        lastError = nil
        reconnectAttempts = 0
        reconnectCandidates.removeAll()
        reconnectCandidateIndex = 0
        isAutomaticReconnectEnabled = true
        self.transport = transport
        originalReconnectTransport = transport
        originalHotspotSSID = transport.kind == .hotspot ? expectedHotspotSSID : nil
        self.expectedBoardIdentity = expectedBoardIdentity?.uppercased()
        originalReconnectIdentity = self.expectedBoardIdentity
        transportKind = transport.kind
        wasUserDisconnected = false
        if transport.kind != .hotspot {
            // A saved-board reconnect over a different transport (or a
            // manual host/BLE connect) is not a hotspot identity claim.
            expectedHotspotSSID = nil
        }
        connectionReadyHandler = onReady
        return await establish(transport)
    }

    /// Each attempt gets fresh streams and a token, including attempts that
    /// reuse the same BLETransport object. Queued callbacks from older streams
    /// cannot change the new connection's state or feed its decoder.
    private func establish(_ transport: RinaTransport) async -> Bool {
        let session = UUID()
        transportSessionID = session
        // A fresh carrier has a fresh board-side parser/reply queue. Sequence
        // IDs poisoned by uncertain requests on the old carrier can be reused;
        // nextSeq itself intentionally keeps advancing to avoid immediate reuse.
        broker.resetQuarantine()
        isEstablishing = true
        establishmentError = nil
        setupStatusReadFailed = false
        setupGetInfoReadFailed = false
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
            await refreshDeviceNameDuringSetup(for: transport, generation: connectionGeneration,
                                               session: session)
            try Task.checkCancellation()
            guard transportSessionID == session else { return false }
            if let establishmentError { throw RinaTransportError.underlying(establishmentError) }
            if transport.kind == .hotspot, let expected = expectedHotspotSSID,
               BoardIdentity.boardID(fromAPSSID: expected) != nil, wifi == nil {
                // A unique expected identity but no `wifi` snapshot at all means
                // GET_STATUS itself failed/timed out here — unlike old firmware
                // that legitimately reports no identity, this is a setup
                // failure we can't clear by "allowing" and should retry, not a
                // confirmed different-board mismatch.
                throw RinaTransportError.underlying(
                    NSLocalizedString("无法读取璃奈板的 Wi-Fi 状态", comment: "hotspot setup failed to read wifi status")
                )
            }
            let fallbackKey = Self.boardKey(identity: nil, transportKind: transport.kind,
                                            peripheralID: (transport as? BLETransport)?.connectedPeripheralID)
            // Only a `ble:` fallback key is safe to remember/reuse across a
            // connect: a peripheral UUID is per physical device. A `wifi:`
            // (or hotspot) key can be the same literal address/SSID for two
            // different boards in sequence (SoftAP's shared IP, DHCP reuse,
            // the same host a person retyped for a different board), so
            // reusing a remembered identity there would attach one board's
            // saved-face/draft identity to a different board that happens to
            // share the address.
            let reuseEligibleKey = fallbackKey?.hasPrefix("ble:") == true ? fallbackKey : nil
            let freshIdentity = Self.normalizedBoardIdentity(wifiBoardID: wifi?.boardId,
                                                             defaultName: setupDefaultName)
            let candidateIdentity = freshIdentity
                ?? (setupStatusReadFailed && setupGetInfoReadFailed
                    ? reuseEligibleKey.flatMap { rememberedIdentityByFallbackKey[$0] } : nil)
            if let expectedBoardIdentity, candidateIdentity != expectedBoardIdentity {
                // Carrier handshakes prove reachability, not physical identity.
                // A reused DHCP address must not replace this session's board,
                // including its remembered identity, before readiness is published.
                let message = candidateIdentity == nil
                    ? NSLocalizedString("无法确认正在连接的璃奈板身份", comment: "carrier switch board identity unavailable")
                    : NSLocalizedString("连接地址对应另一块璃奈板，已停止连接", comment: "carrier switch board identity mismatch")
                if isReconnectAttempt && !currentReconnectIsOriginal {
                    connectionFailed(message)
                } else {
                    stopCarrier()
                    self.transport = nil
                    connectionReadyHandler = nil
                    reconnectTask?.cancel()
                    reconnectTask = nil
                    lastError = message
                    connectionState = .failed(message)
                }
                return false
            }
            if let freshIdentity {
                boardIdentity = freshIdentity
                if let reuseEligibleKey { rememberedIdentityByFallbackKey[reuseEligibleKey] = freshIdentity }
            } else if setupStatusReadFailed, setupGetInfoReadFailed {
                // Reuse only when both identity reads actually failed to come
                // back (timeout/decode failure) — never when the board
                // positively answered without an id, which is a legitimate
                // "this board has no id" reply.
                boardIdentity = reuseEligibleKey.flatMap { rememberedIdentityByFallbackKey[$0] }
            } else {
                boardIdentity = nil
            }
            if let mismatch = hotspotIdentityMismatchMessage(transport) {
                if isReconnectAttempt && !currentReconnectIsOriginal {
                    connectionFailed(mismatch)
                } else {
                    stopCarrier()
                    self.transport = nil
                    connectionReadyHandler = nil
                    reconnectTask?.cancel()
                    reconnectTask = nil
                    lastError = mismatch
                    connectionState = .failed(mismatch)
                }
                return false
            }
            isEstablishing = false
            reconnectAttempts = 0
            reconnectCandidates.removeAll()
            reconnectCandidateIndex = 0
            isReconnectAttempt = false
            currentReconnectIsOriginal = false
            originalReconnectTransport = transport
            originalReconnectIdentity = boardIdentity ?? originalReconnectIdentity
            originalHotspotSSID = transport.kind == .hotspot ? expectedHotspotSSID : nil
            lastError = nil
            let readyHandler = connectionReadyHandler
            connectionReadyHandler = nil
            readyHandler?()
            connectionState = .connected
            startPingLoopIfNeeded()
            return true
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

    /// Non-nil (a ready-to-show zh-Hans message) exactly when this is a
    /// `.hotspot` connect/reconnect with a known `expectedHotspotSSID` and the
    /// board's freshly-refreshed `wifi` snapshot positively disagrees with it.
    /// `nil` from `BoardIdentity.matches` (unknown — old firmware, or no
    /// expectation set) always allows the connection through.
    private func hotspotIdentityMismatchMessage(_ transport: RinaTransport) -> String? {
        guard transport.kind == .hotspot, let expected = expectedHotspotSSID else { return nil }
        guard BoardIdentity.matches(expectedHotspotSSID: expected, reported: wifi) == false else { return nil }
        let reportedName = wifi?.apSsid ?? NSLocalizedString("另一块璃奈板", comment: "unknown board identity in hotspot mismatch message")
        return String(
            format: NSLocalizedString("已连接到另一块璃奈板（%@），而不是 %@", comment: "hotspot session connected to the wrong board"),
            reportedName, expected
        )
    }

    private func stopCarrier() {
        transportSessionID = UUID()
        isEstablishing = false
        clearBoardSnapshot()
        stateTask?.cancel()
        incomingTask?.cancel()
        pingTask?.cancel()
        decoder.reset()
        broker.failAll(RinaTransportError.notConnected)
        transport?.disconnect()
    }

    /// `userInitiated: true` marks this as a person tapping a "断开" button
    /// (see `wasUserDisconnected`) rather than an internal teardown (forget
    /// board, transport switch, session removal, etc.) — those must keep the
    /// default `false` so they don't block `GroupAutoConnector` from ever
    /// redialing this board.
    public func disconnect(userInitiated: Bool = false) {
        manualRetryEpoch = UUID()
        isManualRetryInProgress = false
        if userInitiated { wasUserDisconnected = true }
        reconnectTask?.cancel()
        reconnectTask = nil
        stopCarrier()
        transport = nil
        originalReconnectTransport = nil
        originalReconnectIdentity = nil
        originalHotspotSSID = nil
        reconnectCandidates.removeAll()
        reconnectCandidateIndex = 0
        isReconnectAttempt = false
        currentReconnectIsOriginal = false
        connectionReadyHandler = nil
        expectedBoardIdentity = nil
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
                broker.failAll(RinaTransportError.notConnected)
            } else {
                connectionFailed(RinaTransportError.notConnected.localizedDescription)
            }
        case .failed(let message):
            if isEstablishing {
                establishmentError = message
                broker.failAll(RinaTransportError.underlying(message))
            } else {
                connectionFailed(message)
            }
        }
    }

    private func connectionFailed(_ message: String) {
        if reconnectAttempts == 0, isAutomaticReconnectEnabled, !isManualRetryInProgress {
            let expected = originalReconnectIdentity
            reconnectCandidates = (reconnectCandidatesProvider?(transportKind, wifi) ?? []).filter {
                let candidateID = $0.expectedBoardIdentity?.uppercased()
                return candidateID != nil && (expected == nil || candidateID == expected)
            }
            reconnectCandidateIndex = 0
        }
        stopCarrier()
        deviceName = nil
        lastError = message
        connectionState = .failed(message)
        if !isManualRetryInProgress { attemptReconnect() }
    }

    private func attemptReconnect() {
        guard isAutomaticReconnectEnabled, !wasUserDisconnected,
              let original = originalReconnectTransport else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            connectionReadyHandler = nil
            connectionState = .failed("重连失败，已达到最大尝试次数：" + (lastError ?? ""))
            return
        }
        reconnectTask?.cancel()
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        let candidate: BoardReconnectCandidate
        if reconnectCandidateIndex < reconnectCandidates.count {
            candidate = reconnectCandidates[reconnectCandidateIndex]
            reconnectCandidateIndex += 1
            currentReconnectIsOriginal = false
        } else {
            candidate = BoardReconnectCandidate(transport: original,
                                                expectedBoardIdentity: originalReconnectIdentity)
            currentReconnectIsOriginal = true
        }
        connectionState = .reconnecting(attempt: attempt)
        let session = transportSessionID
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(self.reconnectDelay(attempt))) }
            catch { return }
            guard !Task.isCancelled, self.transportSessionID == session else { return }
            self.reconnectTask = nil
            self.transport = candidate.transport
            self.transportKind = candidate.transport.kind
            self.expectedBoardIdentity = candidate.expectedBoardIdentity?.uppercased()
            self.expectedHotspotSSID = candidate.transport.kind == .hotspot ? self.originalHotspotSSID : nil
            self.isReconnectAttempt = true
            _ = await self.establish(candidate.transport)
        }
    }

    /// Stops pending and future automatic attempts while retaining the last
    /// carrier so the user can issue a bounded manual retry. It also blocks group
    /// auto-connect from silently redialing this session.
    public func stopAutomaticReconnect() {
        manualRetryEpoch = UUID()
        isManualRetryInProgress = false
        isAutomaticReconnectEnabled = false
        wasUserDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        if connectionState != .connected {
            stopCarrier()
            connectionReadyHandler = nil
            isReconnectAttempt = false
            currentReconnectIsOriginal = false
            connectionState = .disconnected
        }
    }

    /// Tries the last proven carrier, then each same-board local alternate
    /// once. A previous stop remains in force; only explicit `connect(using:)`
    /// reenables background automatic retries.
    @discardableResult
    public func retryNow() async -> Bool {
        if connectionState == .connected { return true }
        guard let original = originalReconnectTransport ?? transport else { return false }
        let identity = reconnectCandidateIdentity
        // Carrier teardown clears the status snapshot. Retain alternatives
        // learned before the drop (notably a station IP reported over BLE).
        let available = (reconnectCandidatesProvider?(original.kind, wifi) ?? []) + reconnectCandidates
        var seen = Set<ObjectIdentifier>()
        var seenWiFiEndpoints: [TransportKind] = []
        if case .wifi = original.kind { seenWiFiEndpoints.append(original.kind) }
        var alternatives: [BoardReconnectCandidate] = []
        for candidate in available {
            if alternatives.count == maxReconnectAttempts - 1 { break }
            guard let identity, let candidateID = candidate.expectedBoardIdentity?.uppercased() else { continue }
            guard candidateID == identity, candidate.transport !== original,
                  seen.insert(ObjectIdentifier(candidate.transport)).inserted else { continue }
            // Providers may create a fresh TCP object for an already learned
            // endpoint. Spend the bounded retry budget on distinct addresses.
            if case .wifi = candidate.transport.kind {
                guard !seenWiFiEndpoints.contains(candidate.transport.kind) else { continue }
                seenWiFiEndpoints.append(candidate.transport.kind)
            }
            alternatives.append(candidate)
        }
        let candidates = [BoardReconnectCandidate(transport: original, expectedBoardIdentity: identity)] + alternatives
        let epoch = UUID()
        manualRetryEpoch = epoch
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        reconnectCandidateIndex = 0
        isManualRetryInProgress = true
        defer {
            if manualRetryEpoch == epoch { isManualRetryInProgress = false }
        }
        stopCarrier()
        for candidate in candidates {
            guard manualRetryEpoch == epoch, !Task.isCancelled else { return false }
            self.transport = candidate.transport
            self.transportKind = candidate.transport.kind
            self.expectedBoardIdentity = candidate.expectedBoardIdentity?.uppercased()
            self.expectedHotspotSSID = candidate.transport.kind == .hotspot ? originalHotspotSSID : nil
            isReconnectAttempt = true
            currentReconnectIsOriginal = false
            if await establish(candidate.transport) { return true }
        }
        guard manualRetryEpoch == epoch, !Task.isCancelled else { return false }
        if isAutomaticReconnectEnabled { attemptReconnect() }
        return false
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
        eventContinuations.removeValue(forKey: id)?.finish()
    }

    /// Like `events()`, but also returns the subscription id so a caller that
    /// might never actually iterate the stream (e.g. `wifiScan()`'s
    /// synchronous-reply fast path) can unsubscribe explicitly (A6) instead of
    /// leaking the continuation in `eventContinuations` forever.
    private func subscribeEvents() -> (id: UUID, stream: AsyncStream<BoardEvent>) {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: BoardEvent.self,
            bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)
        )
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.eventContinuations.removeValue(forKey: id)
            }
        }
        return (id, pair.stream)
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
        protocolVersion = nil
        boardIdentity = nil
        setupDefaultName = nil
        handshakeDeviceInfo = nil
        bootId = nil
        deviceInfoCaps = []
        // A generation only means anything within the carrier that reported it:
        // another client may have mutated the document while we were away.
        facesGen = nil
    }

    /// Read a snapshot even when the firmware has no new events to publish.
    /// Each read is independent so an unsupported preview does not hide status.
    private func refreshBoardSnapshot(session: UUID) async {
        for type: RinaLinkMessageType in [.getStatus, .getFrame, .getPreviewSync] {
            guard !Task.isCancelled, transportSessionID == session else { return }
            guard let frame = try? await sendUnqueued(type: type, payload: Data(),
                                                      timeout: handshakeTimeout, aggregateMore: true,
                                                      duringSetup: true) else {
                if type == .getStatus { setupStatusReadFailed = true }
                continue
            }
            guard !Task.isCancelled, transportSessionID == session else { return }
            switch type {
            case .getStatus:
                if let decoded = try? JSONDecoder().decode(DeviceStatus.self, from: frame.payload) {
                    applyStatus(decoded)
                } else {
                    setupStatusReadFailed = true
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
        let merged = DeviceStatus(
            ok: decoded.ok ?? status?.ok,
            v: decoded.v ?? status?.v,
            version: decoded.version ?? status?.version,
            device: decoded.device ?? status?.device,
            uptimeMs: decoded.uptimeMs ?? status?.uptimeMs,
            // Prefer the live property over the stale `status` snapshot: a
            // lite status / EV_STATUS that omits wifi/power must not roll
            // these back to whatever the handshake-era `status` last held.
            wifi: decoded.wifi ?? wifi ?? status?.wifi,
            power: decoded.power ?? power ?? status?.power,
            renderer: decoded.renderer ?? status?.renderer,
            matrix: decoded.matrix ?? status?.matrix,
            stats: decoded.stats ?? status?.stats
        )
        status = merged
        // Only assign when this status actually carried the field, otherwise
        // the published property would be reassigned its own current value
        // pointlessly (and would mask a future fallback source change).
        if let value = decoded.power { power = value }
        if let value = decoded.wifi { wifi = value }
        emit(.status(merged))
        checkHotspotIdentityWhileConnected()
    }

    /// Re-runs the `.hotspot` identity check (see `hotspotIdentityMismatchMessage`)
    /// against a freshly received `wifi` snapshot while already `.connected` —
    /// e.g. the phone's Wi-Fi silently roamed to a different board's SoftAP
    /// mid-session. A positive mismatch tears the carrier down without
    /// scheduling a reconnect, same as a mismatch caught during `establish()`.
    private func checkHotspotIdentityWhileConnected() {
        guard connectionState == .connected, let transport,
              let mismatch = hotspotIdentityMismatchMessage(transport) else { return }
        stopCarrier()
        self.transport = nil
        connectionReadyHandler = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        lastError = mismatch
        connectionState = .failed(mismatch)
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
        let probe = Self.incomingDecodeProbe
        var overallStart: ContinuousClock.Instant?
        var dispatchStart: ContinuousClock.Instant?
        if probe != nil { overallStart = Self.incomingDecodeClock.now }
        let decodeState = RinaPerf.signposter.beginInterval("BoardIncomingDecode")
        let frames = decoder.feed(data)
        // `route` is the separable dispatch portion (per-frame JSON decode +
        // fan-out to published state/event consumers), measured on its own
        // signpost nested inside the overall per-chunk interval above.
        if probe != nil { dispatchStart = Self.incomingDecodeClock.now }
        let dispatchState = RinaPerf.signposter.beginInterval("BoardIncomingDispatch")
        for frame in frames {
            route(frame)
        }
        RinaPerf.signposter.endInterval("BoardIncomingDispatch", dispatchState)
        RinaPerf.signposter.endInterval("BoardIncomingDecode", decodeState)
        // The probe callback runs after both signposts have already ended, so
        // a slow probe implementation (e.g. appending to a test array) never
        // inflates the measured Instruments intervals.
        if let probe, let overallStart, let dispatchStart {
            let now = Self.incomingDecodeClock.now
            probe(overallStart.duration(to: now), dispatchStart.duration(to: now), data.count)
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
                    checkHotspotIdentityWhileConnected()
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

        broker.deliver(frame)
    }

    // MARK: Low-level request/response

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
        let sendSession = transportSessionID
        let reply = try await broker.request(
            replyType: type.replyType,
            aggregateMore: aggregateMore,
            timeout: timeout,
            encode: { seq in try RinaLinkEncoder.encode(type: type, seq: seq, payload: payload) },
            write: { data in try await transport.send(data) },
            onWriteFailure: { [weak self] error in
                guard let self, !(error is CancellationError), self.transportSessionID == sendSession,
                      self.connectionState == .connected || self.isEstablishing else { return }
                // The transport API cannot report whether an error was
                // raised before or after a partial write. Reset the
                // carrier so a truncated frame cannot poison the next
                // request on the board's streaming decoder.
                self.connectionFailed(error.localizedDescription)
            }
        )
        try Task.checkCancellation()
        return reply
    }

    // MARK: Typed helpers

    /// Encode or accept a payload, transmit, then decode. A nil `transmit`
    /// is `send(type:payload:timeout:)` with `aggregateMore` left at its
    /// default; it adds no output lease and no submission check. Callers
    /// that need those pass a closure and keep the checks themselves.
    func transact<Reply: Decodable & Sendable>(
        _ cmd: RinaCommand,
        type: RinaLinkMessageType = .cmd,
        timeout: TimeInterval = 5,
        transmit: ((Data) async throws -> RinaLinkFrame)? = nil
    ) async throws -> Reply {
        try await transact(payload: try cmd.encode(), type: type, timeout: timeout, transmit: transmit)
    }

    func transact<Reply: Decodable & Sendable>(
        payload: Data,
        type: RinaLinkMessageType = .cmd,
        timeout: TimeInterval = 5,
        transmit: ((Data) async throws -> RinaLinkFrame)? = nil
    ) async throws -> Reply {
        let frame: RinaLinkFrame
        if let transmit {
            frame = try await transmit(payload)
        } else {
            frame = try await send(type: type, payload: payload, timeout: timeout)
        }
        return try JSONDecoder().decode(Reply.self, from: frame.payload)
    }

    func transactPayload(
        _ payload: Data = Data(),
        type: RinaLinkMessageType,
        timeout: TimeInterval = 5
    ) async throws -> Data {
        let frame = try await send(type: type, payload: payload, timeout: timeout)
        return frame.payload
    }

    @discardableResult
    public func command(_ cmd: RinaCommand) async throws -> CommandReply {
        let token = BoardOutputContext.session
        let generation = connectionGeneration
        let carrier = transportSessionID
        return try await commandPump.run { @MainActor in
            try self.checkSubmission(generation: generation, carrier: carrier)
            if let token { try self.output.check(token) }
            // Primary-only mirror hook. Not awaited. Which commands mirror,
            // and the face-apply lease, are the hook's decision. A face lease
            // waits until `reply.ok` (`didApplyFace` below) so a rejected
            // apply does not hand the sinks over.
            self.outboundHook?.willSendCommand(cmd, token != nil)
            guard let activeTransport = self.transport else {
                throw RinaTransportError.notConnected
            }
            let reply: CommandReply = try await self.transact(cmd) { payload in
                let frame = try await BoardOutputContext.$session.withValue(token) {
                    try await self.send(type: .cmd, payload: payload)
                }
                try self.checkSubmission(generation: generation, carrier: carrier)
                if let token { try self.output.check(token) }
                return frame
            }
            guard reply.ok else {
                let detail = reply.error.flatMap { $0.isEmpty ? nil : "：\($0)" } ?? ""
                throw RinaTransportError.underlying("面板拒绝指令：\(cmd.name)\(detail)")
            }
            self.updateDeviceName(from: reply, for: cmd, transport: activeTransport, generation: generation)
            self.outboundHook?.didApplyFace(reply, cmd)
            return reply
        }
    }

    /// Like `command(_:)`, but bypasses `commandPump` (BOARD_GROUP_SPEC §3):
    /// the drop-oldest depth-4 command queue would silently discard
    /// `clock_sample`/`identify`/`group_start` calls sent in a tight burst
    /// (e.g. 8 clock samples in a row), which board-group scheduling cannot
    /// tolerate. Still goes through the normal seq/pending/output-lease/
    /// generation machinery in `send`/`sendUnqueued`, and still throws if the
    /// connection's generation changes while the request is in flight.
    @discardableResult
    public func requestReliable(_ cmd: RinaCommand, timeout: TimeInterval = 5) async throws -> CommandReply {
        let reply: CommandReply = try await requestReliableDecoding(cmd, timeout: timeout)
        guard reply.ok else {
            let detail = reply.error.flatMap { $0.isEmpty ? nil : "：\($0)" } ?? ""
            throw RinaTransportError.underlying(String(localized: "面板拒绝指令：\(cmd.name)") + detail)
        }
        return reply
    }

    /// Typed-decoding variant of `requestReliable(_:timeout:)`, for replies
    /// that carry fields `CommandReply` doesn't model (`IdentifyReply`,
    /// `ClockSampleReply`, `GroupStartReply`). Does not check an `ok` field
    /// itself (callers decode whichever reply type they asked for and inspect
    /// its own `ok`).
    public func requestReliableDecoding<Reply: Decodable & Sendable>(
        _ cmd: RinaCommand, timeout: TimeInterval = 5
    ) async throws -> Reply {
        let token = BoardOutputContext.session
        if let token { try output.check(token) }
        let generation = connectionGeneration
        guard transport != nil else { throw RinaTransportError.notConnected }
        return try await transact(cmd, timeout: timeout) { payload in
            let frame = try await BoardOutputContext.$session.withValue(token) {
                try await self.send(type: .cmd, payload: payload, timeout: timeout)
            }
            guard generation == self.connectionGeneration else { throw CancellationError() }
            if let token { try self.output.check(token) }
            return frame
        }
    }

    private func refreshDeviceNameDuringSetup(
        for transport: RinaTransport,
        generation: UUID,
        session: UUID
    ) async {
        guard self.transport === transport,
              connectionGeneration == generation,
              transportSessionID == session,
              isEstablishing else { return }
        guard let payload = try? RinaCommand.getInfo.encode(),
              let frame = try? await sendUnqueued(type: .cmd, payload: payload, timeout: 5,
                                                  aggregateMore: true, duringSetup: true),
              let reply = try? JSONDecoder().decode(CommandReply.self, from: frame.payload) else {
            // The round trip itself never came back (or didn't decode) — as
            // opposed to a board that answered without a `defaultName`, which
            // is a legitimate "no id" reply and must not set this.
            setupGetInfoReadFailed = true
            return
        }
        guard reply.ok,
              self.transport === transport,
              connectionGeneration == generation,
              transportSessionID == session else { return }
        updateDeviceName(from: reply, for: .getInfo, transport: transport, generation: generation)
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
            // A rename or a later get_info supersedes the setup snapshot.
            if !isEstablishing { handshakeDeviceInfo = nil }
            if case .getInfo = command {
                protocolVersion = reply.proto
                bootId = reply.bootId
                deviceInfoCaps = reply.caps ?? []
                if isEstablishing {
                    setupDefaultName = reply.defaultName
                    handshakeDeviceInfo = HandshakeDeviceInfo(
                        generation: generation,
                        name: reply.name,
                        defaultName: reply.defaultName,
                        customName: reply.customName,
                        fw: reply.fw,
                        build: reply.build
                    )
                }
            }
        default:
            return
        }
    }

    /// Which physical board this link reaches, for tying local drafts to a
    /// board. Prefers the board's own id; without one, falls back to the link
    /// itself, where the same board over another transport looks different.
    public var boardKey: String? {
        Self.boardKey(identity: boardIdentity, transportKind: transportKind,
                      peripheralID: (transport as? BLETransport)?.connectedPeripheralID)
    }

    nonisolated static func boardKey(identity: String?, transportKind: TransportKind?,
                                     peripheralID: UUID?) -> String? {
        if let identity { return "board:\(identity)" }
        switch transportKind {
        case .bluetooth: return peripheralID.map { "ble:\($0.uuidString)" }
        case .wifi(let host, _): return "wifi:\(host)"
        // Every board's SoftAP shares one address; nothing else tells them apart.
        case .hotspot, nil: return nil
        }
    }

    /// `wifi.boardId` is the bare id; `defaultName` is "RinaBoard-<id>".
    nonisolated static func normalizedBoardIdentity(wifiBoardID: String?, defaultName: String?) -> String? {
        if let id = wifiBoardID?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            return id.uppercased()
        }
        guard let name = defaultName, let dash = name.lastIndex(of: "-") else { return nil }
        let id = name[name.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id.uppercased()
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
            // Primary-only mirror hook. Not awaited. The hook skips debug
            // output and a board whose output is already group text.
            self.outboundHook?.willSendFrame(packed, playback, reason)
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

    private func checkSubmission(generation: UUID, carrier: UUID) throws {
        try Task.checkCancellation()
        guard connectionGeneration == generation, transportSessionID == carrier else {
            throw CancellationError()
        }
        guard connectionState == .connected else { throw RinaTransportError.notConnected }
    }

    /// `GET_FACES`: the reply payload is `[gen: UInt32 LE][file bytes from
    /// offset]`. The board may require several request/reply round-trips
    /// (one `send()` each) to deliver the whole file — the terminal frame of
    /// each round-trip carries `FLAG_MORE` while more remain, at which point
    /// the next request must include `{"offset":n,"gen":g}` so the board can
    /// detect a concurrent mutation (HTTP 409-equivalent error) and restart.
    public func getFaces() async throws -> Data {
        let generation = connectionGeneration
        let carrier = transportSessionID
        var result = Data()
        var offset = 0
        var gen: UInt32?
        var didRestart = false
        while true {
            try checkSubmission(generation: generation, carrier: carrier)
            var payloadDict: [String: Any] = ["offset": offset]
            if let gen { payloadDict["gen"] = gen }
            let payload = try JSONSerialization.data(withJSONObject: payloadDict)
            do {
                // A1: each GET_FACES request/reply is its own one-frame
                // round-trip; FLAG_MORE on the terminal frame means "call
                // again with a higher offset", not "more frames on this seq".
                let frame = try await send(type: .getFaces, payload: payload, aggregateMore: false)
                try checkSubmission(generation: generation, carrier: carrier)
                guard frame.payload.count >= 4 else { throw RinaTransportError.invalidResponse }
                let genBytes = [UInt8](frame.payload.prefix(4))
                let frameGen = UInt32(genBytes[0])
                    | (UInt32(genBytes[1]) << 8)
                    | (UInt32(genBytes[2]) << 16)
                    | (UInt32(genBytes[3]) << 24)
                if gen == nil { gen = frameGen }
                guard frameGen == gen else { throw RinaTransportError.invalidResponse }
                let page = frame.payload.suffix(from: frame.payload.index(frame.payload.startIndex, offsetBy: 4))
                guard page.count <= Self.maxFacesDocumentBytes - result.count else {
                    throw RinaTransportError.invalidResponse
                }
                guard !frame.isMore || !page.isEmpty else {
                    throw RinaTransportError.invalidResponse
                }
                result.append(page)
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
        // Record the generation this document was read at, so the next face op
        // has something real to compare its reply against. Without this the
        // expectation stayed `nil` after every reload and the first mutation
        // was declared in sync unconditionally.
        try checkSubmission(generation: generation, carrier: carrier)
        if let gen { facesGen = Int(gen) }
        return result
    }

    public enum BlobKind: String { case scroll, faces, scrollBitmap = "scroll_bitmap" }

    public func uploadBlob(
        kind: BlobKind,
        meta: [String: Any],
        data: Data,
        endStart: Bool = true,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> Data {
        if kind == .scroll, data.count % PackedFrame.byteCount != 0 {
            throw RinaTransportError.invalidResponse
        }
        var beginMeta = meta
        beginMeta["kind"] = kind.rawValue
        beginMeta["totalBytes"] = data.count
        let beginPayload = try JSONSerialization.data(withJSONObject: beginMeta)
        // Fail local validation before entering the transfer/abort cleanup path:
        // no board-side blob owner exists until BLOB_BEGIN reaches the wire.
        try RinaLinkEncoder.validatePayloadSize(beginPayload.count)
        let token = BoardOutputContext.session
        let generation = connectionGeneration
        let carrier = transportSessionID
        return try await blobPump.run { @MainActor in
            // Stale queued work has not begun a blob and must not abort a new carrier.
            try self.checkSubmission(generation: generation, carrier: carrier)
            if let token { try self.output.check(token) }
            do {
                return try await BoardOutputContext.$session.withValue(token) {
                    try await self.uploadBlobSerial(kind: kind, beginPayload: beginPayload,
                                                    data: data, endStart: endStart, onProgress: onProgress,
                                                    generation: generation, carrier: carrier)
                }
            } catch {
                // Keep the blob slot until cleanup completes. This task must
                // survive the cancelled producer and must not inherit its lease.
                let cleanup = Task { @MainActor in
                    guard generation == self.connectionGeneration,
                          carrier == self.transportSessionID,
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
                        self.connectionFailed(error.localizedDescription)
                    }
                }
                await cleanup.value
                throw error
            }
        }
    }

    private func uploadBlobSerial(
        kind: BlobKind,
        beginPayload: Data,
        data: Data,
        endStart: Bool = true,
        onProgress: ((Double) -> Void)? = nil,
        generation: UUID,
        carrier: UUID
    ) async throws -> Data {
        try checkSubmission(generation: generation, carrier: carrier)
        let beginFrame = try await send(type: .blobBegin, payload: beginPayload)
        try checkSubmission(generation: generation, carrier: carrier)
        let begin = try JSONDecoder().decode(BlobBeginReply.self, from: beginFrame.payload)

        let beginOffset = begin.offset ?? 0
        // A hostile/corrupt peer could report an offset outside the blob;
        // reject it before it ever reaches Data(subdata:).
        guard (0...data.count).contains(beginOffset),
              kind != .scroll || beginOffset % PackedFrame.byteCount == 0 else {
            throw RinaTransportError.invalidResponse
        }
        var offset = beginOffset
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
            try checkSubmission(generation: generation, carrier: carrier)
            let end = min(offset + chunkMax, data.count)
            var chunkPayload = Data()
            var offsetLE = UInt32(offset).littleEndian
            withUnsafeBytes(of: &offsetLE) { chunkPayload.append(contentsOf: $0) }
            chunkPayload.append(data.subdata(in: offset..<end))
            do {
                let chunkFrame = try await send(type: .blobChunk, payload: chunkPayload)
                try checkSubmission(generation: generation, carrier: carrier)
                let chunkReply = try JSONDecoder().decode(BlobChunkReply.self, from: chunkFrame.payload)
                guard let newOffset = chunkReply.offset, newOffset == end else {
                    throw RinaTransportError.invalidResponse
                }
                offset = newOffset
                onProgress?(Double(offset) / Double(max(1, data.count)))
            } catch let error as RinaLinkError {
                if error.code == 400, !didResync, let expected = error.expectedOffset {
                    guard (0...data.count).contains(expected),
                          kind != .scroll || expected % PackedFrame.byteCount == 0 else {
                        throw RinaTransportError.invalidResponse
                    }
                    didResync = true
                    offset = expected
                    continue
                }
                throw error
            }
        }

        try checkSubmission(generation: generation, carrier: carrier)
        let endMeta: [String: Any] = (kind == .scroll || kind == .scrollBitmap) ? ["start": endStart] : [:]
        let endPayload = try JSONSerialization.data(withJSONObject: endMeta)
        let endFrame = try await send(type: .blobEnd, payload: endPayload)
        try checkSubmission(generation: generation, carrier: carrier)
        return endFrame.payload
    }

    /// Firmware reads `sourceText` as optional (`d["sourceText"] | nullptr`).
    /// Include it only when the BLOB_BEGIN document still fits in one frame
    /// after `uploadBlob` appends `kind` and `totalBytes`. A text whose own
    /// UTF-8 is within 4096 bytes can still push that document over
    /// `RinaLinkFrameConstants.maxPayloadBytes`.
    private func scrollBeginMeta(
        _ meta: [String: Any],
        sourceText: String,
        kind: BlobKind,
        totalBytes: Int
    ) throws -> [String: Any] {
        var withText = meta
        withText["sourceText"] = sourceText
        var measured = withText
        measured["kind"] = kind.rawValue
        measured["totalBytes"] = totalBytes
        let count = try JSONSerialization.data(withJSONObject: measured).count
        if count <= RinaLinkFrameConstants.maxPayloadBytes {
            return withText
        }
        return meta
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
        guard !frames.isEmpty, frames.count <= RinaLinkConstants.maxScrollFrames else {
            throw RinaTransportError.invalidResponse
        }
        var data = Data()
        for frame in frames { data.append(frame.data) }
        let fpsInt = max(RinaLinkConstants.scrollFpsMin, min(RinaLinkConstants.scrollFpsMax, Int(fps.rounded())))
        // Firmware keeps its previous interval when a begin carries only `fps`,
        // so the tick rate would silently disagree with the reported fps.
        let meta = try scrollBeginMeta([
            "fps": fpsInt,
            "intervalMs": ScrollRasterizer.intervalMs(forFps: fpsInt),
            "totalFrames": frames.count,
            "timelineId": timelineId,
            "fontId": fontId,
            "generatorVersion": generatorVersion,
        ], sourceText: sourceText, kind: .scroll, totalBytes: data.count)
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
        guard timeline.frameCount > 0,
              timeline.frameCount <= RinaLinkConstants.maxScrollFrames else {
            throw RinaTransportError.invalidResponse
        }
        let bytes = timeline.bitmap.packedBytes()
        var meta: [String: Any] = [
            "width": timeline.bitmapWidth,
            "rows": MatrixGeometry.rows,
            "fps": fps,
            // See `startScrollUpload`: without it the board ticks at its old interval.
            "intervalMs": ScrollRasterizer.intervalMs(forFps: fps),
            "timelineId": timeline.timelineId,
            "fontId": ScrollRasterizer.fontId,
            "generatorVersion": ScrollRasterizer.generatorVersion,
        ]
        meta = try scrollBeginMeta(meta, sourceText: sourceText, kind: .scrollBitmap, totalBytes: bytes.count)
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

    /// `BLOB kind:"scroll_bitmap"` with the group-viewport BEGIN meta fields
    /// (BOARD_GROUP_SPEC §1.4/§3): `bitmap` is the whole stitched
    /// `[V dark][text][V dark]` canvas (`GroupScrollBitmap.build`), unlike
    /// `startScrollBitmapUpload` every member board uploads the *same* bytes
    /// and only `viewportX` differs. `start: false` lets the caller upload to
    /// every member before any of them starts scrolling locally (§3's
    /// `play(text:fps:loop:)` sends the real start via `group_start` once
    /// every board has been re-anchored). `packedBytes` is the bitmap
    /// already encoded by the caller so a group upload does not pack the
    /// same canvas once per member. Viewport fields stay per board.
    public func uploadGroupScrollBitmap(
        bitmap: ScrollBitmap,
        packedBytes: Data,
        viewportX: Int,
        virtualWidth: Int,
        fps: Int,
        intervalMs: Int,
        timelineId: String,
        sourceText: String,
        start: Bool,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> ScrollUploadReply {
        var meta: [String: Any] = [
            "width": bitmap.width,
            "rows": MatrixGeometry.rows,
            "fps": fps,
            // See `startScrollUpload`: without it the board ticks at its old interval.
            "intervalMs": intervalMs,
            "timelineId": timelineId,
            "fontId": ScrollRasterizer.fontId,
            "generatorVersion": ScrollRasterizer.generatorVersion,
            "virtualWidth": virtualWidth,
            "viewportX": viewportX,
        ]
        meta = try scrollBeginMeta(meta, sourceText: sourceText, kind: .scrollBitmap, totalBytes: packedBytes.count)
        let replyData = try await uploadBlob(kind: .scrollBitmap, meta: meta, data: packedBytes,
                                             endStart: start, onProgress: onProgress)
        return try JSONDecoder().decode(ScrollUploadReply.self, from: replyData)
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
        let generation = connectionGeneration
        let carrier = transportSessionID
        let reply: FaceOpReply = try await commandPump.run { @MainActor in
            try self.checkSubmission(generation: generation, carrier: carrier)
            return try await self.transact(payload: payload) { payload in
                let frame = try await self.send(type: .cmd, payload: payload)
                try self.checkSubmission(generation: generation, carrier: carrier)
                return frame
            }
        }
        try checkSubmission(generation: generation, carrier: carrier)
        // The reply's generation is the only evidence that nobody else mutated
        // `saved_faces.json` between our read and this write. Without it — no
        // `gen` field at all, or none observed for this carrier — there is no
        // basis for that claim, so callers must reload rather than apply an
        // optimistic in-place mutation. Firmware that does not report `gen`
        // therefore always takes the reload path, by design: a silently stale
        // library is worse than a redundant fetch.
        if let gen = reply.gen {
            lastFaceOpGenMatchedExpectation = facesGen.map { gen == $0 + 1 } ?? false
            facesGen = gen
        } else {
            lastFaceOpGenMatchedExpectation = false
        }
        return reply
    }

    // MARK: Wi-Fi helpers (§4)

    /// `wifi_scan`: returns the scan results directly (the generic `command()`
    /// helper only decodes `CommandReply`, which drops the `networks` field).
    /// The firmware may reply synchronously with `{ok,networks:[...]}` (legacy
    /// behavior) or immediately with `{ok,scanning:true}` and push the real
    /// results a moment later as an `EV_WIFI_SCAN` (0x95) event — in that case
    /// this waits (up to 65s, covering the firmware's 60s scan deadline) for
    /// the next `.wifiScan` event, then queries
    /// `wifi_scan_result` if the completion event was missed. An unfinished
    /// scan throws a timeout rather than presenting an empty network list.
    /// The event stream
    /// is subscribed to *before* the command is sent so a fast reply can't
    /// race the subscription.
    @discardableResult
    public func wifiScan() async throws -> WifiScanReply {
        try await wifiScan(eventTimeout: .seconds(65))
    }

    func wifiScan(eventTimeout: Duration) async throws -> WifiScanReply {
        let generation = connectionGeneration
        let carrier = transportSessionID
        let (subID, stream) = subscribeEvents()
        // A6: guarantee the subscription is torn down on every exit path
        // (synchronous reply, timeout, or an EV_WIFI_SCAN match) — otherwise
        // the synchronous-reply fast path below would leak the continuation
        // in `eventContinuations` forever (it's never iterated in that case).
        defer { eventContinuations.removeValue(forKey: subID) }
        let decoded: WifiScanReply = try await commandPump.run { @MainActor in
            try self.checkSubmission(generation: generation, carrier: carrier)
            return try await self.transact(RinaCommand.wifiScan)
        }
        try checkSubmission(generation: generation, carrier: carrier)
        if decoded.scanning != true, decoded.networks != nil {
            lastWifiScan = decoded
            return decoded
        }
        let result: WifiScanReply? = await withTaskGroup(of: WifiScanReply?.self) { group in
            group.addTask {
                for await event in stream {
                    if case .wifiScan(let reply) = event,
                       reply.scanning != true, reply.networks != nil { return reply }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: eventTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        try checkSubmission(generation: generation, carrier: carrier)
        if let result {
            lastWifiScan = result
            return result
        }
        // The scan may have completed even when its event did not arrive.
        // Firmware retains the result for this explicit query. While still
        // scanning it can return the previous list, which is not completion.
        let fallback: WifiScanReply = try await commandPump.run { @MainActor in
            try self.checkSubmission(generation: generation, carrier: carrier)
            return try await self.transact(RinaCommand.wifiScanResult)
        }
        try checkSubmission(generation: generation, carrier: carrier)
        guard fallback.scanning != true, fallback.networks != nil else {
            throw RinaTransportError.timeout
        }
        lastWifiScan = fallback
        return fallback
    }

    /// `wifi_status`: refreshes `wifi` immediately instead of waiting for the
    /// next `EV_WIFI` push.
    @discardableResult
    public func refreshWifiStatus() async throws -> WifiStatus {
        let generation = connectionGeneration
        let carrier = transportSessionID
        let decoded: WifiStatus = try await commandPump.run { @MainActor in
            try self.checkSubmission(generation: generation, carrier: carrier)
            return try await self.transact(RinaCommand.wifiStatus)
        }
        try checkSubmission(generation: generation, carrier: carrier)
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
    // A monotonic clock (uptime, not wall clock) so a backward NTP/user
    // clock step can never stall the pump for the size of the step.
    private let now: @Sendable () -> UInt64
    private var lastStart: UInt64 = 0
    private var hasStarted = false
    private var queue: [QueueEntry] = []
    private var isDraining = false
    private var isBusy = false

    private struct QueueEntry {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    init(minInterval: TimeInterval, depth: Int, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.minInterval = minInterval
        self.depth = depth
        self.now = now
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
            let minIntervalNanos = UInt64(max(0, minInterval) * 1_000_000_000)
            let elapsedNanos = hasStarted ? now() &- lastStart : minIntervalNanos
            if elapsedNanos < minIntervalNanos {
                try? await Task.sleep(nanoseconds: minIntervalNanos - elapsedNanos)
                continue
            }
            let next = queue.removeFirst()
            isBusy = true
            lastStart = now()
            hasStarted = true
            next.continuation.resume()
        }
        isDraining = false
    }
}
