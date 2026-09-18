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
/// Deliberately not `Sendable`: `BLETransport` is `@MainActor`-isolated (it
/// drives `CBCentralManager` on the main queue and publishes `@Observable`
/// state to the UI), and a `SendableMetatype`-inheriting protocol cannot take a
/// main-actor-isolated conformance. Every `any RinaTransport` lives on the main
/// actor — `BoardConnection`, its only owner, is `@MainActor` — so nothing here
/// crosses an isolation boundary. Concrete transports that *are* safe to hand
/// around (`TCPTransport`) still declare `Sendable` themselves.
/// The *discovery* half of `BLETransport`, split out from the carrier
/// abstraction above because the two are used by different owners: one shared
/// scanner lives on `BoardSessionStore`, while each `BoardSession` owns its own
/// connecting transport. Scanning is `@MainActor` (it only ever feeds the
/// connection list) rather than following `RinaTransport`'s isolation note.
///
/// The member list is exactly what the connection UI consumes today. Keep it
/// that way: anything a virtual scanner cannot honestly answer does not belong
/// here.
@MainActor
public protocol BoardScanning: AnyObject {
    /// Sorted strongest-signal-first, stale entries pruned.
    var discoveredPeripherals: [DiscoveredPeripheral] { get }
    var isScanning: Bool { get }
    /// True when the last scan ended on its own timeout rather than because the
    /// user stopped it, so the UI can say why the spinner went away.
    var scanDidTimeOut: Bool { get }
    /// Surfaced instead of silently no-oping when e.g. Bluetooth is off.
    var lastError: String? { get }

    func startScan()
    func stopScan()
}

public protocol RinaTransport: AnyObject {
    var kind: TransportKind { get }
    func stateStream() -> AsyncStream<TransportState>
    func incomingStream() -> AsyncStream<Data>
    /// Preferred max bytes per outgoing chunk (MTU-3 for BLE, a large value for TCP).
    var preferredChunkBytes: Int { get }

    func connect() async throws
    func disconnect()
    func send(_ data: Data) async throws
}

/// A BLE carrier: a `RinaTransport` that also carries the peripheral identity
/// and link status the connection UI shows, and that can scan (one
/// `CBCentralManager` does both jobs, so a virtual stand-in must too).
///
/// `BoardSession` holds `any BLEConnecting` rather than `BLETransport` so a
/// session can be given a carrier that never opens CoreBluetooth. Like
/// `BoardScanning`, the member list is exactly what lives outside
/// `BLETransport.swift` today.
@MainActor
public protocol BLEConnecting: RinaTransport, BoardScanning {
    /// The peripheral this transport should connect to, set before `connect()`
    /// and cleared when its board is forgotten.
    var peripheralIdentifier: UUID? { get set }
    /// The peripheral a `connect()` is currently in flight for, so the list can
    /// show progress on the row the user actually tapped.
    var connectingPeripheralID: UUID? { get }
    var connectedPeripheralID: UUID? { get }
    var connectedPeripheralName: String? { get }
    /// Sampled from the active link; discovery RSSI cannot keep this current.
    var connectedRSSI: Int? { get }

    func updateConnectedPeripheralName(_ name: String)
}
