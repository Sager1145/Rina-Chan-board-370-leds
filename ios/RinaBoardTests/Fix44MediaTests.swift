import AVFoundation
import CoreVideo
import Darwin
import XCTest
@testable import RinaBoard

@MainActor
final class Fix44MediaTests: XCTestCase {
    // MARK: Performance clock: end of track vs. system pause

    func testStoppedPlayerMidSongIsNotTheEndOfTheTrack() {
        // Paused by the system at 1:30 of a 3:00 song, position kept.
        XCTAssertFalse(PresetLiveModel.playerStoppedAtEnd(
            finished: false, lastPlayingMs: 90_000, nowMs: 90_010, durationMs: 180_000))
        // Stopped before the clock ever saw it running.
        XCTAssertFalse(PresetLiveModel.playerStoppedAtEnd(
            finished: false, lastPlayingMs: nil, nowMs: 0, durationMs: 180_000))
    }

    func testStoppedPlayerAtEndIsTheEndOfTheTrack() {
        // The delegate reported the finish.
        XCTAssertTrue(PresetLiveModel.playerStoppedAtEnd(
            finished: true, lastPlayingMs: 90_000, nowMs: 0, durationMs: 180_000))
        // The tick beat the delegate: last running position was at the end.
        XCTAssertTrue(PresetLiveModel.playerStoppedAtEnd(
            finished: false, lastPlayingMs: 179_900, nowMs: 179_990, durationMs: 180_000))
        // The tick beat the delegate after a stall: the player has rewound.
        XCTAssertTrue(PresetLiveModel.playerStoppedAtEnd(
            finished: false, lastPlayingMs: 179_000, nowMs: 0, durationMs: 180_000))
    }

    // MARK: Video recovery with a missing playback file

    func testMissingPlaybackFileKeepsTheLaterImportedVideo() async throws {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinaBoard-Fix44Media-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "RinaBoard.Fix44Media.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "videoMuted")
        let store = PresetLiveFileStore(directory: root.appendingPathComponent("Stored", isDirectory: true))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        // "Play A, import B, never play B": the playback keys still name A,
        // whose file the import of B deleted.
        let videoURL = try await makeVideo(at: root.appendingPathComponent("b.mp4"))
        await VideoPlayerModel(defaults: defaults, store: store).importFile(from: videoURL)
        let storedFile = try XCTUnwrap(defaults.string(forKey: "videoFile"))
        let streamID = UUID().uuidString
        defaults.set("\(UUID().uuidString)-a.mp4", forKey: "videoPlaybackFile")
        defaults.set(streamID, forKey: "videoPlaybackStreamID")
        defaults.set(100, forKey: "videoPlaybackPositionMs")

        let restored = VideoPlayerModel(defaults: defaults, store: store)
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { restored.stop(); connection.disconnect() }

        await restored.restorePlaybackFromBoard(connection: connection, streamID: streamID)

        XCTAssertFalse(restored.isPlaying)
        XCTAssertNil(connection.output.source)
        XCTAssertNotNil(restored.errorMessage)
        // Only the stale playback checkpoint is dropped.
        XCTAssertNil(defaults.string(forKey: "videoPlaybackFile"))
        XCTAssertNil(defaults.string(forKey: "videoPlaybackStreamID"))
        XCTAssertEqual(defaults.string(forKey: "videoFile"), storedFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storedURL(named: storedFile).path))
        // And B is on the page, as the ordinary restore would have left it.
        XCTAssertTrue(restored.hasVideo)
    }

    private func makeVideo(at url: URL) async throws -> URL {
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
