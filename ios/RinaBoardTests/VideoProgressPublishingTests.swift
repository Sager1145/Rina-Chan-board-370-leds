import AVFoundation
import CoreVideo
import Darwin
import XCTest
@testable import RinaBoard

/// Coverage for perf PR-11 item 1: `positionMs` republishes at ~100 ms
/// granularity instead of every frame-loop tick, while every checkpoint,
/// restore and seek site keeps using the exact position
/// (`VideoPlayerModel.precisePositionMs`, exercised here through the
/// internal `applyExactPosition(_:)` seam extracted from `tick()`).
@MainActor
final class VideoProgressPublishingTests: XCTestCase {

    // MARK: Coarse publishing (no player needed: `applyExactPosition` only
    // touches `precisePositionMs` / `positionMs`)

    func testTicksWithinOneBucketProduceNoObservableChange() {
        let model = VideoProgressPublishingTests.makeBareModel()
        XCTAssertEqual(model.positionMs, 0)

        for ms in [10, 30, 50, 70, 90] {
            model.applyExactPosition(ms)
            XCTAssertEqual(model.positionMs, 0, "tick at \(ms)ms is still inside the first bucket")
        }

        // Crossing the bucket boundary republishes exactly once.
        model.applyExactPosition(105)
        XCTAssertEqual(model.positionMs, 105)
    }

    /// A regression that republishes on every tick (instead of only when the
    /// position has drifted by `positionPublishStepMs`) would report far more
    /// than the two changes this sequence is designed to produce.
    func testTicksCrossingSeveralBucketsProduceExactChangeCount() {
        let model = VideoProgressPublishingTests.makeBareModel()
        let ticks = [10, 30, 50, 70, 90,      // bucket 0 — no change yet
                     105, 110, 120, 140, 160, 190, // one change at 105, then held
                     210, 220, 240, 260, 290,      // one change at 210, then held
                     295, 298]                     // still held: within 100ms of 210

        var changeCount = 0
        var lastPublished = model.positionMs
        var observedChanges: [Int] = []
        for ms in ticks {
            model.applyExactPosition(ms)
            if model.positionMs != lastPublished {
                changeCount += 1
                observedChanges.append(model.positionMs)
                lastPublished = model.positionMs
            }
        }

        XCTAssertEqual(changeCount, 2, "expected exactly two bucket crossings, saw \(observedChanges)")
        XCTAssertEqual(observedChanges, [105, 210])
    }

    func testHasPlaybackProgressTracksPublishedPosition() {
        let model = VideoProgressPublishingTests.makeBareModel()
        XCTAssertFalse(model.hasPlaybackProgress)

        model.applyExactPosition(150)
        XCTAssertTrue(model.hasPlaybackProgress)

        // stop() is a transport transition: it publishes 0 immediately
        // (bypassing the coarse filter), which must clear the flag.
        model.stop()
        XCTAssertEqual(model.positionMs, 0)
        XCTAssertFalse(model.hasPlaybackProgress)
    }

    // MARK: Transport transitions publish immediately, not through the
    // coarse filter

    func testSeekWithinCurrentBucketPublishesImmediately() async throws {
        let context = try VideoProgressPublishingTests.makeContext()
        defer { context.cleanUp() }
        let videoURL = try await VideoProgressPublishingTests.makeVideo(
            at: context.root.appendingPathComponent("seek.mp4"))
        let model = context.makeModel()
        await model.importFile(from: videoURL)
        XCTAssertTrue(model.hasVideo)

        // Simulate a sub-bucket tick: precise position moves, but the coarse
        // observable does not.
        model.applyExactPosition(30)
        XCTAssertEqual(model.positionMs, 0)

        // A user drag to a position inside that same bucket must still show
        // up right away — it must never look "stuck" because the coarse
        // per-tick filter swallowed it.
        model.seek(toMs: 45)
        XCTAssertEqual(model.positionMs, 45)
    }

    // MARK: Checkpoint exactness

    func testCheckpointAtPauseUsesExactPositionNotCoarseValue() async throws {
        let context = try VideoProgressPublishingTests.makeContext()
        defer { context.cleanUp() }
        let videoURL = try await VideoProgressPublishingTests.makeVideo(
            at: context.root.appendingPathComponent("pause.mp4"))
        let model = context.makeModel()
        await model.importFile(from: videoURL)

        // A tick inside the first bucket: precise position is 83ms, but the
        // published, 100ms-coarse `positionMs` is still 0.
        model.applyExactPosition(83)
        XCTAssertEqual(model.positionMs, 0)

        model.pause()

        XCTAssertEqual(model.positionMs, 0, "the observable position stays coarse")
        XCTAssertEqual(context.defaults.integer(forKey: "videoPlaybackPositionMs"), 83,
                       "the persisted checkpoint must be the exact position, not the coarse one")
    }

    func testCheckpointAtDisconnectUsesExactPosition() async throws {
        let context = try VideoProgressPublishingTests.makeContext()
        defer { context.cleanUp() }
        let videoURL = try await VideoProgressPublishingTests.makeVideo(
            at: context.root.appendingPathComponent("disconnect.mp4"))
        let model = context.makeModel()
        await model.importFile(from: videoURL)

        model.applyExactPosition(37)
        XCTAssertEqual(model.positionMs, 0)

        // Mirrors what `BoardSyncCoordinator`/`releaseOutput` calls on a
        // board disconnect: local playback state is untouched, only the
        // board lease and its checkpoint are dropped.
        model.releaseOutput(connected: false)

        XCTAssertEqual(context.defaults.integer(forKey: "videoPlaybackPositionMs"), 37)
    }

    func testCheckpointAtStopIsExactlyZero() async throws {
        let context = try VideoProgressPublishingTests.makeContext()
        defer { context.cleanUp() }
        let videoURL = try await VideoProgressPublishingTests.makeVideo(
            at: context.root.appendingPathComponent("stop.mp4"))
        let model = context.makeModel()
        await model.importFile(from: videoURL)

        model.applyExactPosition(650)
        XCTAssertEqual(model.positionMs, 650)

        model.stop()

        XCTAssertEqual(model.positionMs, 0)
        XCTAssertEqual(context.defaults.integer(forKey: "videoPlaybackPositionMs"), 0)
    }

    /// End-to-end: a short, non-looping video is actually played to
    /// completion, and `playbackReachedEnd()` must checkpoint the exact
    /// duration rather than whatever the coarse observable last happened to
    /// hold.
    func testCheckpointAtEndOfPlaybackIsExactDuration() async throws {
        let context = try VideoProgressPublishingTests.makeContext()
        defer { context.cleanUp() }
        context.defaults.set(false, forKey: "videoLoops")
        let videoURL = try await VideoProgressPublishingTests.makeVideo(
            at: context.root.appendingPathComponent("end.mp4"))
        let model = context.makeModel()
        await model.importFile(from: videoURL)
        let durationMs = model.durationMs
        XCTAssertGreaterThan(durationMs, 0)

        let connection = BoardConnection()
        defer { connection.disconnect() }
        model.play(connection: connection)

        let deadline = Date().addingTimeInterval(10)
        while model.positionMs < durationMs, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            // `AVPlayer.play()` can take a tick or two to actually ramp its
            // rate up in a simulator with no real display/audio pipeline;
            // `tick()`'s stall detector (pre-existing, unrelated to this PR)
            // can catch that as "the system stopped it" and pause. Nudge
            // playback again rather than treat a slow start as a real stall
            // or a real end.
            if !model.isPlaying, model.positionMs < durationMs {
                model.play(connection: connection)
            }
        }

        XCTAssertFalse(model.isPlaying, "playback should have reached the end")
        XCTAssertEqual(model.positionMs, durationMs)
        XCTAssertEqual(context.defaults.integer(forKey: "videoPlaybackPositionMs"), durationMs)
    }

    // MARK: Fixtures

    private static func makeBareModel() -> VideoPlayerModel {
        let identifier = UUID().uuidString
        let suiteName = "RinaBoard.VideoProgress.Bare.\(identifier)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "videoMuted")
        let store = PresetLiveFileStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("RinaBoard-VideoProgress-Bare-\(identifier)", isDirectory: true))
        return VideoPlayerModel(defaults: defaults, store: store)
    }

    private static func makeContext() throws -> VideoProgressTestContext {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinaBoard-VideoProgress-\(identifier)", isDirectory: true)
        let stored = root.appendingPathComponent("Stored", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "RinaBoard.VideoProgress.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        // No test audio session is needed; only the video clock and frames
        // participate in these publishing/checkpoint assertions.
        defaults.set(true, forKey: "videoMuted")
        return VideoProgressTestContext(root: root,
                                        suiteName: suiteName,
                                        defaults: defaults,
                                        store: PresetLiveFileStore(directory: stored))
    }

    /// Short, silent, solid-color video: enough for `AVPlayerItemVideoOutput`
    /// to have a video track and a real duration, without needing anything
    /// about the decoded picture itself.
    private static func makeVideo(at url: URL) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // 60 frames @ 30fps = 2.0s: short enough to actually finish in a test.
        for index in 0..<60 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            XCTAssertEqual(status, kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, index.isMultiple(of: 2) ? 0x10 : 0xE0,
                       CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer,
                                         withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return url
    }
}

private struct VideoProgressTestContext {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let store: PresetLiveFileStore

    @MainActor
    func makeModel() -> VideoPlayerModel {
        VideoPlayerModel(defaults: defaults, store: store)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
