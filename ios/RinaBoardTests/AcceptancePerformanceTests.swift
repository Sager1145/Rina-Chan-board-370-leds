import Foundation
import XCTest
@testable import RinaBoard

@MainActor
final class AcceptancePerformanceTests: XCTestCase {
    func testInvalidScriptImportKeepsThePreviouslyCommittedCustomScript() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let validURL = try context.writeImport(named: "working.rinalive", data: validScriptData)

        model.importScript(from: validURL)
        let previousReference = try XCTUnwrap(context.defaults.string(forKey: "presetLiveScriptFile"))
        let previousScript = try XCTUnwrap(model.script)
        let previousFrames = model.composedFrames.map(\.hex94)
        let previousStoredFiles = try context.storedFileNames()

        let invalidURL = try context.writeImport(
            named: "broken.rinalive",
            data: Data("0!unknown,201,301,400\n".utf8)
        )
        model.importScript(from: invalidURL)

        XCTAssertEqual(model.script, previousScript)
        XCTAssertEqual(model.scriptName, "working.rinalive")
        XCTAssertEqual(model.composedFrames.map(\.hex94), previousFrames)
        XCTAssertEqual(context.defaults.string(forKey: "presetLiveScriptFile"), previousReference)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.store.storedURL(named: previousReference).path
        ))
        XCTAssertEqual(try context.storedFileNames(), previousStoredFiles)
        XCTAssertNotNil(model.errorMessage)
    }

    func testInvalidAudioImportKeepsThePreviouslyCommittedCustomAudio() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let validURL = try context.writeImport(named: "working.wav", data: syntheticWAV())

        model.importCustomAudio(from: validURL)
        let previousReference = try XCTUnwrap(context.defaults.string(forKey: "presetLiveAudioFile"))
        let previousDuration = model.durationMs
        let previousStoredFiles = try context.storedFileNames()

        let invalidURL = try context.writeImport(
            named: "broken.wav",
            data: Data("not an audio file".utf8)
        )
        model.importCustomAudio(from: invalidURL)

        XCTAssertEqual(model.audioTitle, "working.wav")
        XCTAssertTrue(model.hasAudio)
        XCTAssertEqual(model.durationMs, previousDuration)
        XCTAssertEqual(context.defaults.string(forKey: "presetLiveAudioFile"), previousReference)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.store.storedURL(named: previousReference).path
        ))
        XCTAssertEqual(try context.storedFileNames(), previousStoredFiles)
        XCTAssertNotNil(model.errorMessage)
    }

    func testImportedAudioRemainsAssociatedWithItsOwnBuiltInPerformance() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let songA = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-a" })
        let songB = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-b" })

        XCTAssertTrue(model.selectBuiltIn(songA))
        model.importAudio(
            from: try context.writeImport(named: "song-a.wav", data: syntheticWAV(sample: 400)),
            forBuiltIn: songA.id
        )
        XCTAssertTrue(model.hasAudioAvailable(for: songA))
        XCTAssertFalse(model.hasAudioAvailable(for: songB))

        XCTAssertTrue(model.selectBuiltIn(songB))
        model.importAudio(
            from: try context.writeImport(named: "song-b.wav", data: syntheticWAV(sample: -400)),
            forBuiltIn: songB.id
        )

        let songAReference = try XCTUnwrap(context.defaults.string(forKey: "performanceAudio.song-a"))
        let songBReference = try XCTUnwrap(context.defaults.string(forKey: "performanceAudio.song-b"))
        XCTAssertNotEqual(songAReference, songBReference)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.store.storedURL(named: songAReference).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.store.storedURL(named: songBReference).path
        ))
        XCTAssertTrue(model.hasAudioAvailable(for: songA))
        XCTAssertTrue(model.hasAudioAvailable(for: songB))

        XCTAssertTrue(model.selectBuiltIn(songA))
        XCTAssertEqual(model.selectedBuiltIn, songA.id)
        XCTAssertEqual(model.audioTitle, "Song A")
        XCTAssertTrue(model.hasAudio)
    }

    func testInvalidBuiltInAudioReplacementKeepsTheOldPerSongAssociation() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let song = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-a" })
        XCTAssertTrue(model.selectBuiltIn(song))
        let validURL = try context.writeImport(named: "original.wav", data: syntheticWAV())
        model.importAudio(from: validURL, forBuiltIn: song.id)
        let previousReference = try XCTUnwrap(
            context.defaults.string(forKey: "performanceAudio.song-a")
        )
        let previousStoredFiles = try context.storedFileNames()

        let invalidURL = try context.writeImport(
            named: "replacement.wav",
            data: Data("truncated RIFF".utf8)
        )
        model.importAudio(from: invalidURL, forBuiltIn: song.id)

        XCTAssertEqual(context.defaults.string(forKey: "performanceAudio.song-a"), previousReference)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.store.storedURL(named: previousReference).path
        ))
        XCTAssertEqual(try context.storedFileNames(), previousStoredFiles)
        XCTAssertEqual(model.selectedBuiltIn, song.id)
        XCTAssertEqual(model.audioTitle, "Song A")
        XCTAssertTrue(model.hasAudio)
        XCTAssertNotNil(model.errorMessage)
    }

    func testCustomScriptAndAudioRestoreIntoANewModelInstance() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let firstModel = context.makeModel()

        firstModel.importScript(from: try context.writeImport(
            named: "restorable.rinalive",
            data: validScriptData
        ))
        firstModel.importCustomAudio(from: try context.writeImport(
            named: "restorable.wav",
            data: syntheticWAV()
        ))
        XCTAssertTrue(firstModel.canPlay)

        let restoredModel = context.makeModel()
        restoredModel.restoreLastImportIfNeeded()

        XCTAssertTrue(restoredModel.isCustomMode)
        XCTAssertNil(restoredModel.selectedBuiltIn)
        XCTAssertEqual(restoredModel.scriptName, "restorable.rinalive")
        XCTAssertEqual(restoredModel.audioTitle, "restorable.wav")
        XCTAssertEqual(restoredModel.script?.keyframes.count, 2)
        XCTAssertEqual(restoredModel.composedFrames.count, 2)
        XCTAssertTrue(restoredModel.hasAudio)
        XCTAssertTrue(restoredModel.canPlay)
        XCTAssertNil(restoredModel.errorMessage)
    }

    private var validScriptData: Data {
        Data("#fps 10\n#title Acceptance\n0!101,201,301,400\n10!101,201,301,400\n".utf8)
    }

    private func makeContext() throws -> PerformanceTestContext {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinaBoard-AcceptancePerformance-\(identifier)",
                                    isDirectory: true)
        let storage = root.appendingPathComponent("Stored", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Fixtures.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try writeFixtureBundle(at: bundleURL, identifier: identifier)
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let suiteName = "RinaBoard.AcceptancePerformance.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return PerformanceTestContext(root: root,
                                      suiteName: suiteName,
                                      defaults: defaults,
                                      bundle: bundle,
                                      store: PresetLiveFileStore(directory: storage))
    }

    private func writeFixtureBundle(at url: URL, identifier: String) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": "RinaBoard.AcceptancePerformance.Fixtures.\(identifier)",
            "CFBundleName": "AcceptancePerformanceFixtures",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: url.appendingPathComponent("Info.plist"), options: .atomic)
        try minimalPartsLibraryData.write(
            to: url.appendingPathComponent("expression_parts.json"),
            options: .atomic
        )
        try validScriptData.write(
            to: url.appendingPathComponent("song-a.rinalive"),
            options: .atomic
        )
        try validScriptData.write(
            to: url.appendingPathComponent("song-b.rinalive"),
            options: .atomic
        )
        try fixtureCatalogData.write(
            to: url.appendingPathComponent("preset_live_catalog.json"),
            options: .atomic
        )
    }

    private var fixtureCatalogData: Data {
        Data(#"""
        [
          {"file":"song-a","audio":"unbundled-a","audioExtension":"wav","title":"Song A","artist":"Fixture","keyframes":2,"durationMs":1000,"source":"test"},
          {"file":"song-b","audio":"unbundled-b","audioExtension":"wav","title":"Song B","artist":"Fixture","keyframes":2,"durationMs":1000,"source":"test"}
        ]
        """#.utf8)
    }

    private var minimalPartsLibraryData: Data {
        let blankFrame = String(repeating: "0", count: 94)
        return Data(#"""
        {
          "format":"rina_expression_parts","version":1,
          "matrix":{"cols":1,"rows":1,"num_leds":370,"row_lengths":[370],"row_valid_x_ranges":[[0,369]],"serpentine":false,"serpentine_odd_rows_reversed":false},
          "layout":{},
          "call":{"ids":{"leye":["101"],"reye":["201"],"mouth":["301"],"cheek":["400"]},"map":{"leye":{"101":"0"},"reye":{"201":"0"},"mouth":{"301":"0"},"cheek":{"400":"0"}},"default_face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},
          "groups":{"leye":["0"],"reye":["0"],"mouth":["0"],"cheek":["0"]},
          "parts":{"0":{"id":0,"name":"empty","type":"empty","size":[1,1],"row_hex":["00"],"preview":["."],"placement":[],"frame":"\#(blankFrame)","strip_indices":[],"lit_count":0}}
        }
        """#.utf8)
    }

    private func syntheticWAV(sample: Int16 = 0) -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount = 800
        let bytesPerSample: UInt16 = 2
        let audioByteCount = UInt32(sampleCount) * UInt32(bytesPerSample)
        var data = Data()
        data.append(Data("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + audioByteCount)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * UInt32(bytesPerSample))
        data.appendLittleEndian(bytesPerSample)
        data.appendLittleEndian(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLittleEndian(audioByteCount)
        for _ in 0..<sampleCount { data.appendLittleEndian(UInt16(bitPattern: sample)) }
        return data
    }
}

private struct PerformanceTestContext {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let bundle: Bundle
    let store: PresetLiveFileStore

    @MainActor
    func makeModel() -> PresetLiveModel {
        PresetLiveModel(bundle: bundle, defaults: defaults, fileStore: store)
    }

    func writeImport(named name: String, data: Data) throws -> URL {
        let imports = root.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let url = imports.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    func storedFileNames() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: store.directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: store.directory.path))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
