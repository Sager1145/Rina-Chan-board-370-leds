import Foundation
import Network
import RinaCore

public struct DiscoveredBoard: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public var host: String?
    public var port: UInt16?
    public var endpoint: NWEndpoint?
    public var serviceIdentity: BonjourServiceIdentity?

    public init(id: String, name: String, host: String? = nil, port: UInt16? = nil,
                endpoint: NWEndpoint? = nil, serviceIdentity: BonjourServiceIdentity? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.endpoint = endpoint
        self.serviceIdentity = serviceIdentity
    }

    /// Whether this entry has a usable connection target yet. `name` is a
    /// Bonjour service name, not a hostname, and must never be used as a TCP
    /// host — until this is `true` the row should be disabled.
    public var isResolved: Bool { endpoint != nil || host != nil }
}

/// Browses `_rinalink._tcp` on the local network (home Wi-Fi discovery, §E3).
///
/// H4: all mutations of `boards` happen on the main actor (browse results
/// arrive on `queue`, resolve completions on the same queue); browse updates
/// merge by service identity so a resolved host/port from an earlier pass is
/// preserved instead of being discarded by the next `browseResultsChangedHandler`
/// callback.
@Observable
@MainActor
public final class BonjourBrowser {
    public private(set) var boards: [DiscoveredBoard] = []

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.rinachan.board.bonjour")
    private var resolveConnections: [String: NWConnection] = [:]

    public init() {}

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: RinaLinkConstants.bonjourType, domain: nil), using: params)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let entries: [(BonjourServiceIdentity, NWEndpoint)] = results.compactMap { result in
                guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                return (BonjourServiceIdentity(name: name, type: type, domain: domain), result.endpoint)
            }
            Task { @MainActor [weak self] in
                self?.merge(entries)
            }
        }
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for (_, connection) in resolveConnections { connection.cancel() }
        resolveConnections.removeAll()
    }

    private func merge(_ entries: [(BonjourServiceIdentity, NWEndpoint)]) {
        let identities = Set(entries.map { $0.0.storageID })
        boards.removeAll { !identities.contains($0.id) }
        for (identity, endpoint) in entries {
            let id = identity.storageID
            if let index = boards.firstIndex(where: { $0.id == id }) {
                boards[index].endpoint = endpoint
            } else {
                boards.append(DiscoveredBoard(id: id, name: identity.name, endpoint: endpoint,
                                              serviceIdentity: identity))
                resolve(id: id, endpoint: endpoint)
            }
        }
    }

    /// Recreates the service endpoint persisted with a known board. Connecting
    /// to it performs a fresh Bonjour resolve, including after its IP changes.
    public func endpoint(for identity: BonjourServiceIdentity) -> NWEndpoint {
        .service(name: identity.name, type: identity.type, domain: identity.domain, interface: nil)
    }

    private func resolve(id: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolveConnections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let path = connection.currentPath, let remote = path.remoteEndpoint,
                   case let .hostPort(host, port) = remote {
                    Task { @MainActor [weak self] in
                        guard let self, let index = self.boards.firstIndex(where: { $0.id == id }) else { return }
                        self.boards[index].host = "\(host)"
                        self.boards[index].port = port.rawValue
                    }
                }
                connection.cancel()
                Task { @MainActor [weak self] in self?.resolveConnections.removeValue(forKey: id) }
            case .failed, .cancelled:
                connection.cancel()
                Task { @MainActor [weak self] in self?.resolveConnections.removeValue(forKey: id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}
