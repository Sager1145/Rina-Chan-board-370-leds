import Foundation
import RinaCore

protocol LocalFaceStoring: Sendable {
    func load() async throws -> FaceDocument?
    func save(_ document: FaceDocument) async throws
}

/// Persists the device-owned face library independently from whichever board
/// is connected. The URL is injectable so the store can be exercised with a
/// temporary directory without touching Application Support.
actor LocalFaceStore: LocalFaceStoring {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("RinaBoard", isDirectory: true)
                .appendingPathComponent("local_faces.json", isDirectory: false)
        }
    }

    func load() async throws -> FaceDocument? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try FaceDocument(jsonData: Data(contentsOf: fileURL))
    }

    func save(_ document: FaceDocument) async throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try document.encoded().write(to: fileURL, options: .atomic)
    }
}
