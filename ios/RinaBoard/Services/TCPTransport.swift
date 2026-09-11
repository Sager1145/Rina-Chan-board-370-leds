import Foundation
import Network
import RinaCore

/// Network.framework TCP transport, used for both home-Wi-Fi (Bonjour /
/// manual host) and hotspot ("direct") connections. Plain TCP, no slicing
/// (`RINALINK_PROTOCOL_V1.md` §1.2).
public final class TCPTransport: RinaTransport, @unchecked Sendable {
    public let kind: TransportKind

    private let host: String
    private let port: UInt16
    private let endpoint: NWEndpoint?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.rinachan.board.tcp")

    // A4: `connection`/the continuation dictionaries are written from both
    // the caller's context (`connect()`/`send()`/`disconnect()`) and from
    // `NWConnection`'s own callback queue (`queue`) — guard every access with
    // this lock instead of relying on both sides happening to agree on a
    // queue.
    private let stateLock = NSLock()
    private var stateContinuations: [UUID: AsyncStream<TransportState>.Continuation] = [:]
    private var incomingContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    public var preferredChunkBytes: Int { RinaLinkConstants.blobChunkMaxTCP }

    public init(host: String, port: UInt16 = RinaLinkConstants.tcpPort, kind: TransportKind? = nil) {
        self.host = host
        self.port = port
        self.endpoint = nil
        self.kind = kind ?? .wifi(host: host, port: port)
    }

    /// Connects directly via a resolved `NWEndpoint` (e.g. from `BonjourBrowser`),
    /// avoiding a manual resolve step (H4).
    public init(endpoint: NWEndpoint, kind: TransportKind) {
        self.endpoint = endpoint
        self.host = ""
        self.port = 0
        self.kind = kind
    }

    public func stateStream() -> AsyncStream<TransportState> {
        let id = UUID()
        return AsyncStream { continuation in
            self.stateLock.withLock { self.stateContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.stateLock.withLock { self?.stateContinuations.removeValue(forKey: id) }
            }
        }
    }

    public func incomingStream() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { continuation in
            self.stateLock.withLock { self.incomingContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.stateLock.withLock { self?.incomingContinuations.removeValue(forKey: id) }
            }
        }
    }

    private func emitState(_ state: TransportState) {
        let continuations = stateLock.withLock { Array(stateContinuations.values) }
        for continuation in continuations { continuation.yield(state) }
    }

    private func emitIncoming(_ data: Data) {
        let continuations = stateLock.withLock { Array(incomingContinuations.values) }
        for continuation in continuations { continuation.yield(data) }
    }

    public func connect() async throws {
        // H6: cancel any previous connection before reassigning. Clear its
        // stateUpdateHandler first so a stale callback can't fire after this
        // connection has already been superseded.
        let previous = stateLock.withLock { () -> NWConnection? in
            let existing = self.connection
            self.connection = nil
            return existing
        }
        previous?.stateUpdateHandler = nil
        previous?.cancel()

        emitState(.connecting)
        let params = NWParameters.tcp
        let resolvedEndpoint = endpoint ?? .hostPort(host: .init(host), port: .init(rawValue: port)!)
        let connection = NWConnection(to: resolvedEndpoint, using: params)
        stateLock.withLock { self.connection = connection }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.emitState(.connected)
                    self.receiveLoop()
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                case .failed(let error):
                    self.emitState(.failed(error.localizedDescription))
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: RinaTransportError.underlying(error.localizedDescription))
                    }
                case .cancelled:
                    self.emitState(.disconnected)
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: RinaTransportError.cancelled)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func disconnect() {
        let previous = stateLock.withLock { () -> NWConnection? in
            let existing = self.connection
            self.connection = nil
            return existing
        }
        previous?.stateUpdateHandler = nil
        previous?.cancel()
        emitState(.disconnected)
    }

    private var currentConnection: NWConnection? { stateLock.withLock { connection } }

    public func send(_ data: Data) async throws {
        guard let connection = currentConnection else { throw RinaTransportError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RinaTransportError.underlying(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveLoop() {
        currentConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.emitIncoming(data)
            }
            if let error {
                self.emitState(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.emitState(.disconnected)
                return
            }
            self.receiveLoop()
        }
    }
}
