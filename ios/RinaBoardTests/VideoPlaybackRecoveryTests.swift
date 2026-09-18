import AVFoundation
import CoreVideo
import Darwin
import XCTest
@testable import RinaBoard

@MainActor
final class VideoPlaybackRecoveryTests: XCTestCase {
    func testMissingOrForeignStreamLeavesBoardOutputUntouched() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let videoURL = try await makeVideo(at: context.root.appendingPathComponent("foreign.mp4"))
        let model = context.makeModel()
        await model.importFile(from: videoURL)
        XCTAssertTrue(model.hasVideo)
        let storedFile = try XCTUnwrap(context.defaults.string(forKey: "videoFile"))
        context.defaults.set(storedFile, forKey: "videoPlaybackFile")
        context.defaults.set(UUID().uuidString, forKey: "videoPlaybackStreamID")

        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        defer { connection.disconnect() }

        await model.restorePlaybackFromBoard(connection: connection, streamID: UUID().uuidString)

        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(connection.output.source)
        XCTAssertNotNil(model.errorMessage)
    }

    func testMatchingSavedVideoResumesBoardPositionWithOriginalStreamID() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let videoURL = try await makeVideo(at: context.root.appendingPathComponent("original.mp4"))
        let imported = context.makeModel()
        await imported.importFile(from: videoURL)
        let storedFile = try XCTUnwrap(context.defaults.string(forKey: "videoFile"))
        let streamID = UUID().uuidString
        context.defaults.set(storedFile, forKey: "videoPlaybackFile")
        context.defaults.set(streamID, forKey: "videoPlaybackStreamID")
        context.defaults.set(100, forKey: "videoPlaybackPositionMs")

        // A fresh model exercises the asynchronous asset reload path used
        // after process termination, rather than reusing the imported player.
        let restored = context.makeModel()
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        defer { restored.stop(); connection.disconnect() }

        await restored.restorePlaybackFromBoard(
            connection: connection,
            streamID: streamID,
            positionMs: 750
        )

        XCTAssertTrue(restored.isPlaying)
        XCTAssertEqual(connection.output.source, .video)
        XCTAssertGreaterThanOrEqual(restored.positionMs, 750)
        XCTAssertEqual(context.defaults.string(forKey: "videoPlaybackFile"), storedFile)
        XCTAssertEqual(context.defaults.string(forKey: "videoPlaybackStreamID"), streamID)
        try await transport.waitForSent(type: .setFrame, count: 1)
    }

    func testClearVideoDeletesStoredCopyAndForgetsIt() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let videoURL = try await makeVideo(at: context.root.appendingPathComponent("clear.mp4"))
        let model = context.makeModel()
        await model.importFile(from: videoURL)
        let storedFile = try XCTUnwrap(context.defaults.string(forKey: "videoFile"))
        let storedURL = context.store.storedURL(named: storedFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))

        model.clearVideo()

        XCTAssertFalse(model.hasVideo)
        XCTAssertNil(model.title)
        XCTAssertEqual(model.durationMs, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
        XCTAssertNil(context.defaults.string(forKey: "videoFile"))
        XCTAssertNil(context.defaults.string(forKey: "videoPlaybackFile"))
    }

    func testFirstRestoreRemovesOrphanedFilesButKeepsSavedVideo() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let videoURL = try await makeVideo(at: context.root.appendingPathComponent("kept.mp4"))
        await context.makeModel().importFile(from: videoURL)
        let storedFile = try XCTUnwrap(context.defaults.string(forKey: "videoFile"))
        let orphan = context.store.directory.appendingPathComponent("orphan.mp4")
        let partial = context.store.directory.appendingPathComponent(".partial.importing")
        try Data([1]).write(to: orphan)
        try Data([1]).write(to: partial)

        context.makeModel().restoreLastVideoIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: context.store.storedURL(named: storedFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    private func makeContext() throws -> VideoTestContext {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinaBoard-VideoRecovery-\(identifier)", isDirectory: true)
        let stored = root.appendingPathComponent("Stored", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "RinaBoard.VideoRecovery.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        // No test audio session is needed; only the video clock and frames
        // participate in these recovery assertions.
        defaults.set(true, forKey: "videoMuted")
        return VideoTestContext(root: root,
                                suiteName: suiteName,
                                defaults: defaults,
                                store: PresetLiveFileStore(directory: stored))
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

private struct VideoTestContext {
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
