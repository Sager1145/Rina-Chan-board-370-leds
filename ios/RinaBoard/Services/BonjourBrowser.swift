import Foundation
import Network
import RinaCore

public struct DiscoveredBoard: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public var host: String?
    public var port: UInt16?
    public var endpoint: NWEndpoint?

    public init(id: String, name: String, host: String? = nil, port: UInt16? = nil, endpoint: NWEndpoint? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.endpoint = endpoint
    }
}

/// Browses `_rinalink._tcp` on the local network (home Wi-Fi discovery, §E3).
///
/// H4: all mutations of `boards` happen on the main actor (browse results
/// arrive on `queue`, resolve completions on the same queue); browse updates
/// merge by service name so a resolved host/port from an earlier pass is
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
            let entries: [(String, NWEndpoint)] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return (name, result.endpoint)
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

    private func merge(_ entries: [(String, NWEndpoint)]) {
        let names = Set(entries.map(\.0))
        boards.removeAll { !names.contains($0.id) }
        for (name, endpoint) in entries {
            if let index = boards.firstIndex(where: { $0.id == name }) {
                boards[index].endpoint = endpoint
            } else {
                boards.append(DiscoveredBoard(id: name, name: name, endpoint: endpoint))
                resolve(name: name, endpoint: endpoint)
            }
        }
    }

    private func resolve(name: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolveConnections[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let path = connection.currentPath, let remote = path.remoteEndpoint,
                   case let .hostPort(host, port) = remote {
                    Task { @MainActor [weak self] in
                        guard let self, let index = self.boards.firstIndex(where: { $0.id == name }) else { return }
                        self.boards[index].host = "\(host)"
                        self.boards[index].port = port.rawValue
                    }
                }
                connection.cancel()
                Task { @MainActor [weak self] in self?.resolveConnections.removeValue(forKey: name) }
            case .failed, .cancelled:
                connection.cancel()
                Task { @MainActor [weak self] in self?.resolveConnections.removeValue(forKey: name) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}
