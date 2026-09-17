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
    //
    // Each test below drives `PresetLiveModel.importCommitHookForTesting`
    // through a `PR8ImportGate`, so an import is held at a deterministic
    // point (after staging completes, before any generation/selection check
    // or commit) rather than relying on timing.

    /// A built-in audio import held mid-staging while the selection switches
    /// to another built-in. The staged copy must be discarded, the
    /// selection-changed error shown, and the (already-absent) player and
    /// defaults for song A left untouched.
    func testBuiltInAudioImportDiscardedWhenSelectionChangesDuringStaging() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let songA = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-a" })
        let songB = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-b" })
        XCTAssertTrue(model.selectBuiltIn(songA))
        let storedFilesBefore = try context.storedFileNames()
        let url = try context.writeImport(named: "song-a.wav", data: syntheticWAV())

        let gate = PR8ImportGate()
        await gate.gate("song-a.wav")
        model.importCommitHookForTesting = { url in await gate.hold(url.lastPathComponent) }

        let task = Task { await model.importAudio(from: url, forBuiltIn: songA.id) }
        await gate.waitUntilReached("song-a.wav")
        XCTAssertTrue(model.selectBuiltIn(songB))
        await gate.release("song-a.wav")
        await task.value

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.selectedBuiltIn, songB.id)
        XCTAssertFalse(model.hasAudio)
        XCTAssertNil(context.defaults.string(forKey: "performanceAudio.song-a"))
        XCTAssertEqual(try context.storedFileNames(), storedFilesBefore)
    }

    /// Two custom-audio imports: the first is held mid-staging, the second
    /// runs to completion and commits, then the first is released. The first
    /// import's own generation has been superseded by the time it reaches
    /// its commit check, so it must be dropped silently — no error message,
    /// and only the second file's copy remains on disk.
    func testCustomAudioImportHeldWhileSupersededDropsSilently() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let firstURL = try context.writeImport(named: "first.wav", data: syntheticWAV(sample: 100))
        let secondURL = try context.writeImport(named: "second.wav", data: syntheticWAV(sample: -100))

        let gate = PR8ImportGate()
        await gate.gate("first.wav")
        model.importCommitHookForTesting = { url in await gate.hold(url.lastPathComponent) }

        let firstTask = Task { await model.importCustomAudio(from: firstURL) }
        await gate.waitUntilReached("first.wav")
        await model.importCustomAudio(from: secondURL)
        await gate.release("first.wav")
        await firstTask.value

        XCTAssertEqual(model.audioTitle, "second.wav")
        XCTAssertTrue(model.hasAudio)
        let storedName = try XCTUnwrap(context.defaults.string(forKey: "presetLiveAudioFile"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.store.storedURL(named: storedName).path
        ))
        XCTAssertEqual(try context.storedFileNames().count, 1)
        XCTAssertNil(model.errorMessage)
    }

    /// A broken custom-audio file is held mid-staging (after its validation
    /// has already failed) while a valid replacement commits, then the
    /// broken import is released. Its failure must not overwrite the valid
    /// replacement's success: no error message, and the valid file's
    /// material stays committed.
    func testBrokenCustomAudioHeldWhileValidReplacementCommits() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let brokenURL = try context.writeImport(named: "broken.wav", data: Data("not an audio file".utf8))
        let validURL = try context.writeImport(named: "valid.wav", data: syntheticWAV())

        let gate = PR8ImportGate()
        await gate.gate("broken.wav")
        model.importCommitHookForTesting = { url in await gate.hold(url.lastPathComponent) }

        let brokenTask = Task { await model.importCustomAudio(from: brokenURL) }
        await gate.waitUntilReached("broken.wav")
        await model.importCustomAudio(from: validURL)
        await gate.release("broken.wav")
        await brokenTask.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.audioTitle, "valid.wav")
        XCTAssertTrue(model.hasAudio)
    }

    /// A custom-audio import is held mid-staging while a script import runs
    /// to completion and commits. Audio and script imports track separate
    /// generation counters, so the script import must not cause the audio
    /// import to be discarded as superseded: releasing the audio import
    /// afterwards must still commit it alongside the script.
    func testCustomAudioHeldWhileScriptImportCommitsIndependently() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let audioURL = try context.writeImport(named: "audio.wav", data: syntheticWAV())
        let scriptURL = try context.writeImport(named: "script.rinalive", data: validScriptData)

        let gate = PR8ImportGate()
        await gate.gate("audio.wav")
        model.importCommitHookForTesting = { url in await gate.hold(url.lastPathComponent) }

        let audioTask = Task { await model.importCustomAudio(from: audioURL) }
        await gate.waitUntilReached("audio.wav")
        await model.importScript(from: scriptURL)
        await gate.release("audio.wav")
        await audioTask.value

        XCTAssertTrue(model.hasAudio)
        XCTAssertEqual(model.audioTitle, "audio.wav")
        XCTAssertEqual(model.scriptName, "script.rinalive")
        XCTAssertTrue(model.canPlay)
        XCTAssertNil(model.errorMessage)
    }

    /// A custom-audio import is held mid-staging while the selection
    /// switches to a built-in performance. The staged copy must be
    /// discarded, the selection-changed error shown, and the app must stay
    /// in built-in mode rather than being dragged back into custom mode.
    func testCustomAudioImportDiscardedWhenSelectionSwitchesToBuiltInDuringStaging() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let song = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-a" })
        let url = try context.writeImport(named: "custom.wav", data: syntheticWAV())
        let storedFilesBefore = try context.storedFileNames()

        let gate = PR8ImportGate()
        await gate.gate("custom.wav")
        model.importCommitHookForTesting = { url in await gate.hold(url.lastPathComponent) }

        let task = Task { await model.importCustomAudio(from: url) }
        await gate.waitUntilReached("custom.wav")
        XCTAssertTrue(model.selectBuiltIn(song))
        await gate.release("custom.wav")
        await task.value

        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isCustomMode)
        XCTAssertEqual(model.selectedBuiltIn, song.id)
        XCTAssertFalse(context.defaults.bool(forKey: "performanceCustomMode"))
        XCTAssertEqual(try context.storedFileNames(), storedFilesBefore)
    }

    // MARK: PR-13 importCustomAudio(loadAudio: false) coverage
    //
    // Every pre-existing custom-audio import test either starts in custom
    // mode already (so `enterCustom` never runs) or has no stored
    // `presetLiveAudioFile` (so `restoreCustomMaterial`'s audio branch was a
    // no-op either way). This is the one case where `loadAudio: false`
    // actually skips real work: built-in mode, with a *previously* imported
    // custom script and audio both still on disk from an earlier session.

    /// Importing new custom audio while in built-in mode must still reuse the
    /// stored custom script (needed for the commit that follows) while
    /// skipping the now-discarded old custom audio load. A future change that
    /// also short-circuited the script half (committing a `nil` script)
    /// would fail `canPlay`/`script` here instead of shipping green.
    func testCustomAudioImportInBuiltInModeReusesStoredScriptWithoutLoadingOldAudio() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.makeModel()

        // Establish a previously-imported custom script + audio pair, then
        // switch to built-in mode without clearing that stored material.
        await model.importScript(from: try context.writeImport(
            named: "reuse.rinalive",
            data: validScriptData
        ))
        await model.importCustomAudio(from: try context.writeImport(
            named: "old-custom.wav",
            data: syntheticWAV(sample: 111)
        ))
        let songA = try XCTUnwrap(model.builtInPerformances.first { $0.id == "song-a" })
        XCTAssertTrue(model.selectBuiltIn(songA))
        XCTAssertFalse(model.isCustomMode)

        await model.importCustomAudio(from: try context.writeImport(
            named: "new-custom.wav",
            data: syntheticWAV(sample: -111)
        ))

        XCTAssertTrue(model.isCustomMode)
        XCTAssertEqual(model.audioTitle, "new-custom.wav")
        XCTAssertTrue(model.hasAudio)
        XCTAssertNotNil(model.script)
        XCTAssertEqual(model.scriptName, "reuse.rinalive")
        XCTAssertTrue(model.canPlay)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: PR-13 cold-restore audio-load coverage
    //
    // Each test below builds material with one `PresetLiveModel` and then
    // restores it into a brand-new instance, so the `AVAudioPlayer` really is
    // created during restore (the recovery tests above reuse the same model,
    // whose material is already active and short-circuits the reload).

    /// A fresh model restoring a custom script/audio pair from a board
    /// checkpoint must reload the stored audio (not just the script), land at
    /// the board's reported position, and leave the stream/material
    /// bookkeeping untouched.
    func testFreshModelColdRestoresCustomAudioFromBoardCheckpoint() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let firstModel = context.makeModel()
        await firstModel.importScript(from: try context.writeImport(
            named: "cold-custom.rinalive",
            data: validScriptData
        ))
        await firstModel.importCustomAudio(from: try context.writeImport(
            named: "cold-custom.wav",
            data: syntheticWAV(sampleCount: 80_000)
        ))
        let scriptFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveScriptFile"))
        let audioFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveAudioFile"))
        let streamID = UUID().uuidString
        let material = "custom|\(scriptFile)|\(audioFile)"
        context.defaults.set(material, forKey: "presetLivePlaybackMaterial")
        context.defaults.set(streamID, forKey: "presetLivePlaybackStreamID")
        context.defaults.set(250, forKey: "presetLivePlaybackPositionMs")

        let freshModel = context.makeModel()
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { freshModel.stop(); connection.disconnect() }

        await freshModel.restorePlaybackFromBoard(
            connection: connection,
            streamID: streamID,
            positionMs: 1_250
        )

        XCTAssertTrue(freshModel.isPlaying)
        XCTAssertEqual(connection.output.source, .performance)
        XCTAssertGreaterThanOrEqual(freshModel.positionMs, 1_250)
        XCTAssertEqual(freshModel.durationMs, 10_000)
        XCTAssertEqual(context.defaults.string(forKey: "presetLivePlaybackStreamID"), streamID)
        XCTAssertEqual(context.defaults.string(forKey: "presetLivePlaybackMaterial"), material)
    }

    /// A fresh model restoring a built-in performance's own imported audio
    /// from a board checkpoint must select that performance, load its stored
    /// audio, and leave the passively-remembered built-in selection alone.
    /// Song B is left as the persisted selection so the final assertion can
    /// actually distinguish "restore used `persistSelection: false`" from a
    /// bug that persists song A over it.
    func testFreshModelColdRestoresBuiltInAudioFromBoardCheckpoint() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let setupA = context.makeModel()
        let songA = try XCTUnwrap(setupA.builtInPerformances.first { $0.id == "song-a" })
        XCTAssertTrue(setupA.selectBuiltIn(songA))
        await setupA.importAudio(
            from: try context.writeImport(named: "cold-builtin.wav", data: syntheticWAV(sampleCount: 80_000)),
            forBuiltIn: songA.id
        )
        let storedName = try XCTUnwrap(context.defaults.string(forKey: "performanceAudio.song-a"))

        let setupB = context.makeModel()
        let songB = try XCTUnwrap(setupB.builtInPerformances.first { $0.id == "song-b" })
        XCTAssertTrue(setupB.selectBuiltIn(songB))
        // `selectBuiltIn(songB)` persisted last, so the passively-remembered
        // selection is song B going into the checkpoint restore below.
        XCTAssertEqual(context.defaults.string(forKey: "presetLiveBuiltIn"), "song-b")

        let streamID = UUID().uuidString
        let material = "builtIn|song-a|\(storedName)"
        context.defaults.set(material, forKey: "presetLivePlaybackMaterial")
        context.defaults.set(streamID, forKey: "presetLivePlaybackStreamID")
        context.defaults.set(500, forKey: "presetLivePlaybackPositionMs")

        let freshModel = context.makeModel()
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { freshModel.stop(); connection.disconnect() }

        await freshModel.restorePlaybackFromBoard(connection: connection, streamID: streamID)

        XCTAssertEqual(freshModel.selectedBuiltIn, "song-a")
        XCTAssertTrue(freshModel.isPlaying)
        XCTAssertEqual(context.defaults.string(forKey: "presetLiveBuiltIn"), "song-b")
    }

    /// A fresh model that already has a player loaded for one built-in song
    /// (via passive restore) must still read the board checkpoint saved for a
    /// *different* song's material before switching to it, rather than
    /// carrying over the already-loaded player's own (unset) position.
    func testFreshModelReadsCheckpointBeforeMaterialRestoreSwitchesSong() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let setupA = context.makeModel()
        let songA = try XCTUnwrap(setupA.builtInPerformances.first { $0.id == "song-a" })
        XCTAssertTrue(setupA.selectBuiltIn(songA))
        await setupA.importAudio(
            from: try context.writeImport(named: "order-a.wav", data: syntheticWAV(sampleCount: 80_000)),
            forBuiltIn: songA.id
        )
        let songAStoredName = try XCTUnwrap(context.defaults.string(forKey: "performanceAudio.song-a"))

        let setupB = context.makeModel()
        let songB = try XCTUnwrap(setupB.builtInPerformances.first { $0.id == "song-b" })
        XCTAssertTrue(setupB.selectBuiltIn(songB))
        await setupB.importAudio(
            from: try context.writeImport(named: "order-b.wav", data: syntheticWAV(sampleCount: 80_000)),
            forBuiltIn: songB.id
        )
        // `selectBuiltIn(songB)` persisted last, so passive restore below
        // lands on song B — the "other song" whose player is already loaded
        // when the song-A checkpoint restore runs.
        XCTAssertEqual(context.defaults.string(forKey: "presetLiveBuiltIn"), "song-b")

        let freshModel = context.makeModel()
        freshModel.restoreLastImportIfNeeded()
        XCTAssertEqual(freshModel.selectedBuiltIn, "song-b")
        XCTAssertTrue(freshModel.hasAudio)

        let material = "builtIn|song-a|\(songAStoredName)"
        context.defaults.set(material, forKey: "presetLivePlaybackMaterial")
        context.defaults.set(UUID().uuidString, forKey: "presetLivePlaybackStreamID")
        context.defaults.set(3_000, forKey: "presetLivePlaybackPositionMs")

        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { freshModel.stop(); connection.disconnect() }

        await freshModel.restorePlaybackFromBoard(connection: connection)

        XCTAssertEqual(freshModel.selectedBuiltIn, "song-a")
        XCTAssertGreaterThanOrEqual(freshModel.positionMs, 3_000)
    }

    /// A stored file that was truncated/corrupted on disk after being
    /// recorded as the active material must fail the reload cleanly on cold
    /// restore instead of silently reporting stale playable state.
    func testFreshModelReportsCorruptStoredAudioOnColdRestore() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }

        // Custom material: the stored audio copy is corrupted after import.
        let customSetup = context.makeModel()
        await customSetup.importScript(from: try context.writeImport(
            named: "corrupt-custom.rinalive",
            data: validScriptData
        ))
        await customSetup.importCustomAudio(from: try context.writeImport(
            named: "corrupt-custom.wav",
            data: syntheticWAV()
        ))
        let scriptFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveScriptFile"))
        let audioFile = try XCTUnwrap(context.defaults.string(forKey: "presetLiveAudioFile"))
        try Data("not an audio file".utf8).write(
            to: context.store.storedURL(named: audioFile),
            options: .atomic
        )
        let streamID = UUID().uuidString
        context.defaults.set("custom|\(scriptFile)|\(audioFile)", forKey: "presetLivePlaybackMaterial")
        context.defaults.set(streamID, forKey: "presetLivePlaybackStreamID")

        let freshCustomModel = context.makeModel()
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { freshCustomModel.stop(); connection.disconnect() }

        await freshCustomModel.restorePlaybackFromBoard(connection: connection, streamID: streamID)

        XCTAssertFalse(freshCustomModel.isPlaying)
        XCTAssertNotNil(freshCustomModel.errorMessage)
        XCTAssertNil(connection.output.source)

        // Built-in material: same corruption, surfaced directly through
        // `selectBuiltIn`.
        let builtInSetup = context.makeModel()
        let songA = try XCTUnwrap(builtInSetup.builtInPerformances.first { $0.id == "song-a" })
        XCTAssertTrue(builtInSetup.selectBuiltIn(songA))
        await builtInSetup.importAudio(
            from: try context.writeImport(named: "corrupt-builtin.wav", data: syntheticWAV()),
            forBuiltIn: songA.id
        )
        let storedName = try XCTUnwrap(context.defaults.string(forKey: "performanceAudio.song-a"))
        try Data("not an audio file".utf8).write(
            to: context.store.storedURL(named: storedName),
            options: .atomic
        )

        let freshBuiltInModel = context.makeModel()
        XCTAssertFalse(freshBuiltInModel.selectBuiltIn(songA))
        XCTAssertNotNil(freshBuiltInModel.errorMessage)
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

/// Deterministically gates a `PresetLiveModel` import at the point its
/// `importCommitHookForTesting` hook runs, keyed by the picked file's
/// `lastPathComponent`. Only keys registered with `gate(_:)` actually
/// suspend; any other key passes straight through, so a single hook
/// closure can gate one import while letting a sibling import run to
/// completion. No sleeps: `waitUntilReached` and `release` are backed by
/// `CheckedContinuation`, resumed exactly once per key.
private actor PR8ImportGate {
    private var gatedKeys: Set<String> = []
    private var reached: Set<String> = []
    private var released: Set<String> = []
    private var reachedContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var releaseContinuations: [String: CheckedContinuation<Void, Never>] = [:]

    func gate(_ key: String) {
        gatedKeys.insert(key)
    }

    /// Called from the model's import hook. Returns immediately for a
    /// non-gated key; otherwise suspends until `release(_:)` is called.
    func hold(_ key: String) async {
        guard gatedKeys.contains(key) else { return }
        reached.insert(key)
        if let continuation = reachedContinuations.removeValue(forKey: key) {
            continuation.resume()
        }
        if released.contains(key) { return }
        await withCheckedContinuation { continuation in
            releaseContinuations[key] = continuation
        }
    }

    /// Suspends until a gated import's `hold(_:)` call has been reached.
    func waitUntilReached(_ key: String) async {
        if reached.contains(key) { return }
        await withCheckedContinuation { continuation in
            reachedContinuations[key] = continuation
        }
    }

    /// Lets a held `hold(_:)` call return.
    func release(_ key: String) {
        released.insert(key)
        if let continuation = releaseContinuations.removeValue(forKey: key) {
            continuation.resume()
        }
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
