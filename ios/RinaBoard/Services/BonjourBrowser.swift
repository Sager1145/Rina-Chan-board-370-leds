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
    private var browseRevision = UUID()
    private var resolverRevisions: [String: UUID] = [:]
    private let queue = DispatchQueue(label: "com.rinachan.board.bonjour")
    private var resolveConnections: [String: NWConnection] = [:]

    public init() {}

    /// Idempotent: a second call while browsing keeps the one browser.
    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: RinaLinkConstants.bonjourType, domain: nil), using: params)
        self.browser = browser
        let revision = UUID()
        browseRevision = revision
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let entries: [(BonjourServiceIdentity, NWEndpoint)] = results.compactMap { result in
                guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                return (BonjourServiceIdentity(name: name, type: type, domain: domain), result.endpoint)
            }
            Task { @MainActor [weak self] in
                guard let self, self.browseRevision == revision, self.browser != nil else { return }
                self.merge(entries)
            }
        }
        browser.start(queue: queue)
    }

    public func stop() {
        browseRevision = UUID()
        resolverRevisions.removeAll()
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        for (_, connection) in resolveConnections { connection.cancel() }
        resolveConnections.removeAll()
        // The next browse starts empty rather than listing boards seen on a
        // previous visit, possibly on another network.
        boards = []
    }

    private func merge(_ entries: [(BonjourServiceIdentity, NWEndpoint)]) {
        let identities = Set(entries.map { $0.0.storageID })
        for id in resolveConnections.keys.filter({ !identities.contains($0) }) {
            resolverRevisions.removeValue(forKey: id)
            resolveConnections.removeValue(forKey: id)?.cancel()
        }
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
        let browseRevision = self.browseRevision
        let revision = UUID()
        resolverRevisions[id] = revision
        resolveConnections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                let remote = connection.currentPath?.remoteEndpoint
                Task { @MainActor [weak self] in
                    guard let self, self.browseRevision == browseRevision,
                          self.resolverRevisions[id] == revision else { return }
                    if case let .hostPort(host, port) = remote,
                       let index = self.boards.firstIndex(where: { $0.id == id }) {
                        self.boards[index].host = "\(host)"
                        self.boards[index].port = port.rawValue
                    }
                    self.finishResolve(id: id, revision: revision)
                }
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.finishResolve(id: id, revision: revision)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func finishResolve(id: String, revision: UUID) {
        guard resolverRevisions[id] == revision else { return }
        resolverRevisions.removeValue(forKey: id)
        let connection = resolveConnections.removeValue(forKey: id)
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }
}
