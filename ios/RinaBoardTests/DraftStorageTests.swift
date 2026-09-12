import Foundation
import XCTest
@testable import RinaBoard

final class DraftStorageTests: XCTestCase {
    func testMissingDraftReturnsNilAndAtomicWriteCanBeReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinaBoard-DraftStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = DraftStorage(directory: directory)

        let missing = try await storage.read("control")
        XCTAssertNil(missing)

        let first = Data("first draft".utf8)
        try await storage.write(first, name: "control")
        let firstRead = try await storage.read("control")
        XCTAssertEqual(firstRead, first)

        let replacement = Data("replacement draft".utf8)
        try await storage.write(replacement, name: "control")
        let replacementRead = try await storage.read("control")
        XCTAssertEqual(replacementRead, replacement)

        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), ["control.json"])
    }
}
