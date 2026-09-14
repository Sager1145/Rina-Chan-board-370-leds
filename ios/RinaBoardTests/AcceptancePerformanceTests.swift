import Foundation
import XCTest
@testable import RinaBoard

@MainActor
final class AcceptancePerformanceTests: XCTestCase {
    func testInvalidScriptImportKeepsThePreviouslyCommittedCustomScript() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let validURL = try context.writeImport(named: "working.rinalive", data: validScriptData)

        await model.importScript(from: validURL)
        let previousReference = try XCTUnwrap(context.defaults.string(forKey: "presetLiveScriptFile"))
        let previousScript = try XCTUnwrap(model.script)
        let previousFrames = model.composedFrames.map(\.hex94)
        let previousStoredFiles = try context.storedFileNames()

        let invalidURL = try context.writeImport(
            named: "broken.rinalive",
            data: Data("0!unknown,201,301,400\n".utf8)
        )
        await model.importScript(from: invalidURL)

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

    func testInvalidAudioImportKeepsThePreviouslyCommittedCustomAudio() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let validURL = try context.writeImport(named: "working.wav", data: syntheticWAV())

        await model.importCustomAudio(from: validURL)
        let previousReference = try XCTUnwrap(context.defaults.string(forKey: "presetLiveAudioFile"))
        let previousDuration = model.durationMs
        let previousStoredFiles = try context.storedFileNames()

        let invalidURL = try context.writeImport(
            named: "broken.wav",
            data: Data("not an audio file".utf8)
        )
        await model.importCustomAudio(from: invalidURL)

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

    func testImportedAudioRemainsAssociatedWithItsOwnBuiltInPerformance() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let songA = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-a" })
        let songB = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-b" })

        XCTAssertTrue(model.selectBuiltIn(songA))
        await model.importAudio(
            from: try context.writeImport(named: "song-a.wav", data: syntheticWAV(sample: 400)),
            forBuiltIn: songA.id
        )
        XCTAssertTrue(model.hasAudioAvailable(for: songA))
        XCTAssertFalse(model.hasAudioAvailable(for: songB))

        XCTAssertTrue(model.selectBuiltIn(songB))
        await model.importAudio(
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

    func testInvalidBuiltInAudioReplacementKeepsTheOldPerSongAssociation() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let song = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-a" })
        XCTAssertTrue(model.selectBuiltIn(song))
        let validURL = try context.writeImport(named: "original.wav", data: syntheticWAV())
        await model.importAudio(from: validURL, forBuiltIn: song.id)
        let previousReference = try XCTUnwrap(
            context.defaults.string(forKey: "performanceAudio.song-a")
        )
        let previousStoredFiles = try context.storedFileNames()

        let invalidURL = try context.writeImport(
            named: "replacement.wav",
            data: Data("truncated RIFF".utf8)
        )
        await model.importAudio(from: invalidURL, forBuiltIn: song.id)

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

    func testCustomScriptAndAudioRestoreIntoANewModelInstance() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let firstModel = context.makeModel()

        await firstModel.importScript(from: try context.writeImport(
            named: "restorable.rinalive",
            data: validScriptData
        ))
        await firstModel.importCustomAudio(from: try context.writeImport(
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

    func testPassiveMaterialRestoreDoesNotStartOrCreateAPlaybackStream() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        await model.importScript(from: try context.writeImport(
            named: "passive.rinalive",
            data: validScriptData
        ))
        await model.importCustomAudio(from: try context.writeImport(
            named: "passive.wav",
            data: syntheticWAV()
        ))

        let restored = context.makeModel()
        restored.restoreLastImportIfNeeded()

        XCTAssertTrue(restored.canPlay)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertNil(context.defaults.string(forKey: "presetLivePlaybackStreamID"))
    }

    func testBoardRestoreWithoutOriginalStreamDoesNotPlayImportedMaterial() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        await model.importScript(from: try context.writeImport(
            named: "unrelated.rinalive",
            data: validScriptData
        ))
        await model.importCustomAudio(from: try context.writeImport(
            named: "unrelated.wav",
            data: syntheticWAV()
        ))
        let scriptFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveScriptFile"))
        let audioFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveAudioFile"))
        context.defaults.set("custom|\(scriptFile)|\(audioFile)", forKey: "presetLivePlaybackMaterial")
        context.defaults.set(UUID().uuidString, forKey: "presetLivePlaybackStreamID")
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { connection.disconnect() }

        await model.restorePlaybackFromBoard(
            connection: connection,
            streamID: UUID().uuidString
        )

        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(connection.output.source)
        XCTAssertNotNil(model.errorMessage)
    }

    func testBoardRestoreUsesMatchingStreamMaterialAndBoardPosition() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        await model.importScript(from: try context.writeImport(
            named: "original.rinalive",
            data: validScriptData
        ))
        await model.importCustomAudio(from: try context.writeImport(
            named: "original.wav",
            data: syntheticWAV(sampleCount: 80_000)
        ))
        let scriptFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveScriptFile"))
        let audioFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveAudioFile"))
        let streamID = UUID().uuidString
        context.defaults.set("custom|\(scriptFile)|\(audioFile)", forKey: "presetLivePlaybackMaterial")
        context.defaults.set(streamID, forKey: "presetLivePlaybackStreamID")
        context.defaults.set(250, forKey: "presetLivePlaybackPositionMs")
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { model.stop(); connection.disconnect() }

        await model.restorePlaybackFromBoard(
            connection: connection,
            streamID: streamID,
            positionMs: 1_250
        )

        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(connection.output.source, .performance)
        XCTAssertGreaterThanOrEqual(model.positionMs, 1_250)
        XCTAssertEqual(context.defaults.string(forKey: "presetLivePlaybackStreamID"), streamID)
        XCTAssertEqual(context.defaults.string(forKey: "presetLivePlaybackMaterial"),
                       "custom|\(scriptFile)|\(audioFile)")
    }

    func testPlayingPerformanceResumesBoardOutputAfterReconnect() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        await model.importScript(from: try context.writeImport(
            named: "reconnect.rinalive",
            data: validScriptData
        ))
        await model.importCustomAudio(from: try context.writeImport(
            named: "reconnect.wav",
            data: syntheticWAV(sampleCount: 80_000)
        ))
        let connection = BoardConnection()
        let initiallyConnected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(initiallyConnected)
        defer { model.stop(); connection.disconnect() }

        await model.play(connection: connection).value
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(connection.output.source, .performance)
        let streamID = try XCTUnwrap(
            context.defaults.string(forKey: "presetLivePlaybackStreamID")
        )

        model.suspendBoardOutput()
        connection.disconnect()
        XCTAssertTrue(model.isPlaying, "A carrier loss must not stop local audio")
        XCTAssertTrue(model.needsBoardResume)
        let reconnected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(reconnected)

        await model.restorePlaybackFromBoard(connection: connection, streamID: streamID)

        XCTAssertTrue(model.isPlaying)
        XCTAssertFalse(model.needsBoardResume)
        XCTAssertEqual(connection.output.source, .performance)
    }

    func testBoardRestoreAbortsWhenTakeoverCheckChangesDuringRestore() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        await model.importScript(from: try context.writeImport(
            named: "takeover.rinalive",
            data: validScriptData
        ))
        await model.importCustomAudio(from: try context.writeImport(
            named: "takeover.wav",
            data: syntheticWAV(sampleCount: 80_000)
        ))
        let scriptFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveScriptFile"))
        let audioFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveAudioFile"))
        let streamID = UUID().uuidString
        context.defaults.set("custom|\(scriptFile)|\(audioFile)", forKey: "presetLivePlaybackMaterial")
        context.defaults.set(streamID, forKey: "presetLivePlaybackStreamID")
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { model.stop(); connection.disconnect() }
        var checks = 0

        await model.restorePlaybackFromBoard(
            connection: connection,
            streamID: streamID,
            shouldResume: {
                checks += 1
                return checks < 2
            }
        )

        XCTAssertEqual(checks, 2)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(connection.output.source)
    }

    func testBoardRestoreRejectsMatchingStreamWhenMaterialIdentityChanged() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        await model.importScript(from: try context.writeImport(
            named: "replacement.rinalive",
            data: validScriptData
        ))
        await model.importCustomAudio(from: try context.writeImport(
            named: "replacement.wav",
            data: syntheticWAV()
        ))
        let streamID = UUID().uuidString
        context.defaults.set("custom|missing-script|missing-audio",
                             forKey: "presetLivePlaybackMaterial")
        context.defaults.set(streamID, forKey: "presetLivePlaybackStreamID")
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { connection.disconnect() }

        await model.restorePlaybackFromBoard(connection: connection, streamID: streamID)

        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(connection.output.source)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: PR-8 import concurrency

    /// Two custom-audio imports started back to back, the second before the
    /// first is awaited. `PresetLiveModel` bumps a generation counter
    /// synchronously at the start of each import call, before the detached
    /// staging work is ever reached, so the ordering below is guaranteed by
    /// call order rather than by which staging task happens to finish first:
    /// only the import whose generation is still current at commit time is
    /// allowed to land.
    func testBackToBackCustomAudioImportsCommitOnlyTheSecond() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let firstURL = try context.writeImport(named: "first.wav", data: syntheticWAV(sample: 100))
        let secondURL = try context.writeImport(named: "second.wav", data: syntheticWAV(sample: -100))

        let firstTask = Task { await model.importCustomAudio(from: firstURL) }
        let secondTask = Task { await model.importCustomAudio(from: secondURL) }
        await firstTask.value
        await secondTask.value

        XCTAssertEqual(model.audioTitle, "second.wav")
        XCTAssertTrue(model.hasAudio)
        let storedName = try XCTUnwrap(context.defaults.string(forKey: "presetLiveAudioFile"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.store.storedURL(named: storedName).path
        ))
        XCTAssertEqual(try context.storedFileNames().count, 1)
        XCTAssertNil(model.errorMessage)
    }

    /// A built-in audio import whose selection changes to another built-in
    /// before staging finishes. Changing the selection right after starting
    /// the import `Task`, before awaiting it, is deterministic: the detached
    /// staging (security scope, validation, file copy, second validation)
    /// cannot reach its main-actor commit point before this synchronous test
    /// body yields control of the main actor back to the run loop, so the
    /// selection change below always lands first.
    func testBuiltInAudioImportDiscardedWhenSelectionChangesDuringStaging() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let songA = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-a" })
        let songB = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-b" })
        XCTAssertTrue(model.selectBuiltIn(songA))
        let storedFilesBefore = try context.storedFileNames()
        let url = try context.writeImport(named: "song-a.wav", data: syntheticWAV())

        let task = Task { await model.importAudio(from: url, forBuiltIn: songA.id) }
        XCTAssertTrue(model.selectBuiltIn(songB))
        await task.value

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.selectedBuiltIn, songB.id)
        XCTAssertNil(context.defaults.string(forKey: "performanceAudio.song-a"))
        XCTAssertEqual(try context.storedFileNames(), storedFilesBefore)
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

    private func syntheticWAV(sample: Int16 = 0, sampleCount: Int = 800) -> Data {
        let sampleRate: UInt32 = 8_000
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
