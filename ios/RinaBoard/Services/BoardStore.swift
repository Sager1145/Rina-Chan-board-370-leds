import Foundation
import RinaCore

public struct KnownBoard: Codable, Equatable, Identifiable, Sendable {
    public var id: String // BLE identifier (UUID string) or TCP host
    public var name: String
    public var preferredTransport: String // "bluetooth" | "wifi" | "hotspot"
    public var lastHost: String?
    public var lastSeen: Date?

    public init(id: String, name: String, preferredTransport: String = "bluetooth",
                lastHost: String? = nil, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.preferredTransport = preferredTransport
        self.lastHost = lastHost
        self.lastSeen = lastSeen
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
        boards = (try? JSONDecoder().decode([KnownBoard].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(boards) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func upsert(_ board: KnownBoard) {
        if let index = boards.firstIndex(where: { $0.id == board.id }) {
            boards[index] = board
        } else {
            boards.append(board)
        }
        persist()
    }

    public func setPreferredTransport(_ transport: String, forBoardId id: String) {
        guard let index = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[index].preferredTransport = transport
        persist()
    }

    public func remove(id: String) {
        boards.removeAll { $0.id == id }
        persist()
    }
}
