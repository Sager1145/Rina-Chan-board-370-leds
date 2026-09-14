import Foundation

actor DraftStorage {
    static let shared = DraftStorage()
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Drafts", isDirectory: true)) {
        self.directory = directory
    }

    func read(_ name: String) throws -> Data? {
        let url = directory.appendingPathComponent(name).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name).appendingPathExtension("json"), options: .atomic)
    }

    func remove(_ name: String) throws {
        let url = directory.appendingPathComponent(name).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
