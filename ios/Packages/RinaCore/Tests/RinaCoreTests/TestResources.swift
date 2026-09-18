import Foundation

/// Reads fixtures from the app's committed `ios/RinaBoard/Resources`.
///
/// Every file read through here is tracked in git, so it exists on every
/// checkout. If one is missing, the file was moved or renamed, or a path walker
/// broke, and the test must fail. These reads used to go
/// `try? Data(contentsOf:)` → `nil` → `throw XCTSkip`. That turned a broken
/// fixture into a skip that looked green, so a fully passing `swift test` could
/// be all skips (audit A49).
///
/// Opt-in gates (`RINA_PERF_GATE`, `RINA_REGENERATE_LIPSYNC_PROFILES`) are a
/// different case and still skip on purpose.
enum TestResources {
    struct Missing: Error, CustomStringConvertible {
        let url: URL
        var description: String {
            "required test resource is missing: \(url.path). It is tracked in git, so it moved or the path is wrong"
        }
    }

    static func requireFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Missing(url: url) }
    }

    static func data(at url: URL) throws -> Data {
        try requireFile(url)
        return try Data(contentsOf: url)
    }
}
