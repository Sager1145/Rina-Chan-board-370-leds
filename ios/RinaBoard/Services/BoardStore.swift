import Foundation
import RinaCore

/// The stable part of a Bonjour result. Rebuilding an `NWEndpoint.service`
/// from these fields asks Network.framework to resolve the service again, so
/// a saved board does not depend on the DHCP address observed last time.
public struct BonjourServiceIdentity: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var domain: String

    public init(name: String, type: String = RinaLinkConstants.bonjourType, domain: String = "local.") {
        self.name = name
        self.type = type
        self.domain = domain
    }

    public var storageID: String {
        "bonjour:\(name).\(type).\(domain)"
    }
}

public struct KnownBoard: Codable, Equatable, Identifiable, Sendable {
    public var id: String // BLE UUID, TCP host, or stable Bonjour storage id
    public var name: String
    public var preferredTransport: String // "bluetooth" | "wifi" | "hotspot"
    public var lastHost: String?
    /// Present for boards saved from Bonjour discovery. Optional so records
    /// written by older app versions continue to decode and reconnect by host.
    public var bonjourService: BonjourServiceIdentity?
    public var lastSeen: Date?

    public init(id: String, name: String, preferredTransport: String = "bluetooth",
                lastHost: String? = nil, bonjourService: BonjourServiceIdentity? = nil,
                lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.preferredTransport = preferredTransport
        self.lastHost = lastHost
        self.bonjourService = bonjourService
        self.lastSeen = lastSeen
    }
}

public enum SavedBoardConnectionTarget: Equatable, Sendable {
    case bluetooth(UUID)
    case bonjour(BonjourServiceIdentity)
    case host(String, isBoardHotspot: Bool)
}

public extension KnownBoard {
    /// Resolves a saved record into one connection plan shared by manual
    /// reconnect and launch-time reconnect.
    var connectionTarget: SavedBoardConnectionTarget? {
        switch preferredTransport {
        case "bluetooth":
            guard let identifier = UUID(uuidString: id) else { return nil }
            return .bluetooth(identifier)
        case "wifi":
            if let bonjourService {
                return .bonjour(bonjourService)
            }
            if let lastHost, !lastHost.isEmpty {
                return .host(lastHost, isBoardHotspot: false)
            }
            // Older versions saved an endpoint-only Bonjour result with the
            // service instance name in `id` and no host. Upgrade that shape
            // in memory so it can resolve again on the current network.
            guard !id.isEmpty else { return nil }
            return .bonjour(BonjourServiceIdentity(name: id))
        case "hotspot":
            guard let lastHost, !lastHost.isEmpty else { return nil }
            return .host(lastHost, isBoardHotspot: true)
        case "hotspot-tcp":
            guard let lastHost, !lastHost.isEmpty else { return nil }
            return .host(lastHost, isBoardHotspot: false)
        default:
            return nil
        }
    }
}

/// Persists known boards + per-board preferred transport to `UserDefaults` as JSON (D8).
@Observable
@MainActor
public final class BoardStore {
    private static let defaultsKey = "com.rinachan.board.knownBoards"

    public private(set) var boards: [KnownBoard] = []

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        // Keep the existing in-memory list (and the persisted key) untouched
        // on decode failure instead of silently wiping known boards.
        guard let decoded = try? JSONDecoder().decode([KnownBoard].self, from: data) else { return }
        boards = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(boards) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func upsert(_ board: KnownBoard) {
        if let index = boards.firstIndex(where: { existing in
            if existing.id == board.id { return true }
            guard let service = board.bonjourService else { return false }
            if existing.bonjourService == service { return true }
            // Adopt the stable service identity when replacing a record made
            // by an older version, which stored either the service name or
            // the address resolved during that discovery pass as its id.
            guard existing.bonjourService == nil else { return false }
            return existing.id == service.name
                || (board.lastHost != nil && existing.lastHost == board.lastHost)
        }) {
            boards[index] = board
        } else {
            boards.append(board)
        }
        persist()
    }


    public func remove(id: String) {
        boards.removeAll { $0.id == id }
        persist()
    }
}
