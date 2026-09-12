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
    private let writeQueue = TCPWriteQueue()
    private let stateLock = NSLock()
    private var stateContinuations: [UUID: AsyncStream<TransportState>.Continuation] = [:]
    private var incomingContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var connectWaiter: (connection: NWConnection, continuation: CheckedContinuation<Void, Error>)?

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
                self?.stateLock.withLock { _ = self?.stateContinuations.removeValue(forKey: id) }
            }
        }
    }

    public func incomingStream() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { continuation in
            self.stateLock.withLock { self.incomingContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.stateLock.withLock { _ = self?.incomingContinuations.removeValue(forKey: id) }
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
        let displaced = stateLock.withLock { () -> (NWConnection?, CheckedContinuation<Void, Error>?) in
            let existing = self.connection
            let continuation = self.connectWaiter?.continuation
            self.connection = nil
            self.connectWaiter = nil
            return (existing, continuation)
        }
        displaced.0?.stateUpdateHandler = nil
        displaced.0?.cancel()
        displaced.1?.resume(throwing: RinaTransportError.cancelled)

        emitState(.connecting)
        let params = NWParameters.tcp
        let resolvedEndpoint = endpoint ?? .hostPort(host: .init(host), port: .init(rawValue: port)!)
        let connection = NWConnection(to: resolvedEndpoint, using: params)
        stateLock.withLock { self.connection = connection }

        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.expireConnect(on: connection)
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let installed = stateLock.withLock { () -> Bool in
                    guard self.connection === connection, !Task.isCancelled else { return false }
                    self.connectWaiter = (connection, continuation)
                    return true
                }
                guard installed else {
                    continuation.resume(throwing: RinaTransportError.cancelled)
                    return
                }
                connection.stateUpdateHandler = { [weak self] newState in
                    guard let self, self.isCurrent(connection) else { return }
                    switch newState {
                    case .ready:
                        self.emitState(.connected)
                        self.receiveLoop(on: connection)
                        self.finishConnect(on: connection, result: .success(()))
                    case .failed(let error):
                        self.emitState(.failed(error.localizedDescription))
                        self.finishConnect(on: connection,
                                           result: .failure(RinaTransportError.underlying(error.localizedDescription)))
                    case .cancelled:
                        self.emitState(.disconnected)
                        self.finishConnect(on: connection, result: .failure(RinaTransportError.cancelled))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            self.finishConnect(on: connection, result: .failure(CancellationError()))
            connection.cancel()
        }
    }

    private func expireConnect(on connection: NWConnection) {
        let waiter = stateLock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard let waiter = connectWaiter, waiter.connection === connection else { return nil }
            connectWaiter = nil
            if self.connection === connection { self.connection = nil }
            return waiter.continuation
        }
        guard let waiter else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        emitState(.failed("TCP connection timed out"))
        waiter.resume(throwing: RinaTransportError.timeout)
    }

    private func closeTimedOutWrite(on connection: NWConnection) {
        let wasCurrent = stateLock.withLock { () -> Bool in
            guard self.connection === connection else { return false }
            self.connection = nil
            return true
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        if wasCurrent { emitState(.failed("TCP write timed out")) }
    }

    private func isCurrent(_ connection: NWConnection) -> Bool {
        stateLock.withLock { self.connection === connection }
    }

    private func finishConnect(on connection: NWConnection, result: Result<Void, Error>) {
        let continuation = stateLock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard let waiter = connectWaiter, waiter.connection === connection else { return nil }
            connectWaiter = nil
            return waiter.continuation
        }
        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    public func disconnect() {
        let detached = stateLock.withLock { () -> (NWConnection?, CheckedContinuation<Void, Error>?) in
            let existing = self.connection
            let continuation = self.connectWaiter?.continuation
            self.connection = nil
            self.connectWaiter = nil
            return (existing, continuation)
        }
        detached.0?.stateUpdateHandler = nil
        detached.0?.cancel()
        detached.1?.resume(throwing: RinaTransportError.cancelled)
        emitState(.disconnected)
    }

    private var currentConnection: NWConnection? { stateLock.withLock { connection } }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let connection = currentConnection else { throw RinaTransportError.notConnected }
        try await writeQueue.send(timeout: 5, onTimeout: {
            self.closeTimedOutWrite(on: connection)
        }) { completion in
            guard self.isCurrent(connection) else {
                completion(.failure(RinaTransportError.notConnected))
                return
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    completion(.failure(RinaTransportError.underlying(error.localizedDescription)))
                } else {
                    completion(.success(()))
                }
            })
        }
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.isCurrent(connection) else { return }
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
            self.receiveLoop(on: connection)
        }
    }
}

/// Network callbacks and task cancellation can race on different executors.
/// The lock protects every field, and continuations are resumed outside it.
final class TCPSendCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        let finished = lock.withLock { () -> Result<Void, Error>? in
            if isFinished, let result { return result }
            self.continuation = continuation
            return nil
        }
        if let finished {
            continuation.resume(with: finished)
            return false
        }
        return true
    }

    func finish(_ result: Result<Void, Error>, beforeResume: () -> Void = {}) {
        let claimed = lock.withLock { () -> Bool in
            guard self.result == nil else { return false }
            self.result = result
            return true
        }
        guard claimed else { return }
        beforeResume()
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            isFinished = true
            let waiter = continuation
            continuation = nil
            return waiter
        }
        waiter?.resume(with: result)
    }
}

/// One submitted frame owns the permit until Network.framework completes it.
/// Cancellation removes waiting writes, but cannot retract a submitted frame;
/// its deadline closes that original connection before releasing the permit.
final class TCPWriteQueue: Sendable {
    private let pump = RatePump(minInterval: 0, depth: 32)

    func send(timeout: TimeInterval,
              onTimeout: @escaping @Sendable () -> Void,
              submit: @escaping @Sendable (@escaping @Sendable (Result<Void, Error>) -> Void) -> Void) async throws {
        try await pump.run {
            let completion = TCPSendCompletion()
            let deadline = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                completion.finish(.failure(RinaTransportError.timeout), beforeResume: onTimeout)
            }
            defer { deadline.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard completion.install(continuation) else { return }
                guard !Task.isCancelled else {
                    completion.finish(.failure(CancellationError()))
                    return
                }
                submit { result in completion.finish(result) }
            }
            try Task.checkCancellation()
        }
    }
}
