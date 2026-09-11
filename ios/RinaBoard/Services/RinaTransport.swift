import Foundation

public enum TransportKind: Equatable, Sendable {
    case bluetooth
    case wifi(host: String, port: UInt16)
    case hotspot
}

public enum TransportState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)
}

/// Abstraction over the three RinaLink carriers (BLE / TCP-LAN / TCP-hotspot).
/// `BoardConnection` owns exactly one active transport at a time and drives
/// its `RinaLinkDecoder` from `incomingStream()`.
///
/// `stateStream()`/`incomingStream()` are multi-consumer factories (like
/// `BoardConnection.events()`): each call returns a fresh `AsyncStream`
/// backed by its own continuation, so a transport can be reused across
/// multiple `connect()`s without a previous consumer's cancellation
/// permanently finishing the stream for the next one.
public protocol RinaTransport: AnyObject, Sendable {
    var kind: TransportKind { get }
    func stateStream() -> AsyncStream<TransportState>
    func incomingStream() -> AsyncStream<Data>
    /// Preferred max bytes per outgoing chunk (MTU-3 for BLE, a large value for TCP).
    var preferredChunkBytes: Int { get }

    func connect() async throws
    func disconnect()
    func send(_ data: Data) async throws
}
