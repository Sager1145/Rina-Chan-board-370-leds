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
        let data = try Data(contentsOf: fileURL)
        // `FaceDocument`'s lenient decoder silently drops unparseable entries
        // and treats a missing/malformed top-level "faces" as an empty array.
        // A later save would then persist that partial (or empty) library
        // over the original file. Pre-check the raw JSON shape and, if any
        // faces had to be skipped, surface it instead of returning a document
        // that looks like a complete, healthy read.
        let topLevel: Any
        do {
            topLevel = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LocalFaceStoreError.malformed(error.localizedDescription)
        }
        guard let object = topLevel as? [String: Any] else {
            throw LocalFaceStoreError.malformed(
                NSLocalizedString("顶层结构不是 JSON 对象", comment: "local face store malformed: not an object")
            )
        }
        guard let facesValue = object["faces"] else {
            throw LocalFaceStoreError.malformed(
                NSLocalizedString("缺少 faces 字段", comment: "local face store malformed: missing faces field")
            )
        }
        guard facesValue is [Any] else {
            throw LocalFaceStoreError.malformed(
                NSLocalizedString("faces 字段不是数组", comment: "local face store malformed: faces not an array")
            )
        }
        let (document, skippedCount) = try FaceDocument.decodedForImport(jsonData: data)
        if skippedCount > 0 {
            throw LocalFaceStoreError.partiallyUnreadable(document: document, skippedCount: skippedCount)
        }
        return document
    }

    func save(_ document: FaceDocument) async throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try document.encoded().write(to: fileURL, options: .atomic)
    }
}

/// Failure modes specific to reading `local_faces.json` from disk, as
/// opposed to `FaceDocument`'s own lenient in-memory decode: a store read is
/// the one place a partial or malformed parse must not be treated as "loaded
/// successfully" (see `load()`), because a later save would overwrite the
/// original bytes with whatever partial result was accepted.
enum LocalFaceStoreError: LocalizedError {
    /// The top-level JSON isn't shaped like a face document at all (not an
    /// object, or "faces" present but not an array).
    case malformed(String)
    /// The document parsed, but one or more entries in "faces" could not be
    /// decoded and were skipped. `document` is the partial result so callers
    /// can still show what did parse.
    case partiallyUnreadable(document: FaceDocument, skippedCount: Int)

    var errorDescription: String? {
        switch self {
        case .malformed(let reason):
            return String(
                format: NSLocalizedString("无法读取本机表情库：%@", comment: "local face library load failed"),
                reason
            )
        case .partiallyUnreadable(_, let skippedCount):
            return String(
                format: NSLocalizedString("本机表情库中有 %lld 个表情无法解析", comment: "local face library partially unreadable"),
                Int64(skippedCount)
            )
        }
    }
}
