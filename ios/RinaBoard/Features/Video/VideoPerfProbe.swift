#if DEBUG || RINA_PERF_LOG
import AVFoundation
import CoreVideo
import Foundation
import os

/// PR-11 item 2 measurement bootstrap (`-videoPerfProbe`): generates a short,
/// representative-resolution clip with `AVAssetWriter` (adapted from
/// `VideoProgressPublishingTests.makeVideo` on perf/pr11-video-progress),
/// imports it into `VideoFileStore` exactly the way a real Photos/file import
/// does, and starts playback so `VideoPlayerModel.tick()` runs its full
/// decode → luma → quantize path every frame — the pipeline the
/// `VideoFrameTiming` summary in `RinaPerf.swift` measures. There is
/// otherwise no way to get a clip playing without a manual tap.
///
/// Gated `DEBUG || RINA_PERF_LOG`, matching `VideoFrameTiming`, rather than
/// `DEBUG` alone: the Release+`RINA_PERF_LOG` build is exactly the one this
/// measurement needs to run in, so a plain `DEBUG` gate would make the
/// bootstrap unavailable in the build the numbers have to come from.
enum VideoPerfProbe {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: "VideoPerfProbe")

    /// 1280×720: a plausible resolution for a video a user actually imports
    /// (a common phone/download export size), landscape to match the
    /// board's wide aspect. Note this mostly exercises realistic H.264
    /// decode cost: `VideoPlayerModel.install` configures the
    /// `AVPlayerItemVideoOutput` to already downsample to ~160px on the long
    /// edge (`samplingSize`), so the luma loop's pixel count is bounded the
    /// same way regardless of source resolution — but a source at or above
    /// that size is what makes the delivered buffer actually hit the ~160px
    /// cap instead of staying source-sized and smaller than real content.
    private static let width = 1280
    private static let height = 720
    private static let frameRate: Int32 = 30
    /// 5s of frames: comfortably clears one `VideoFrameTiming` batch (120
    /// frames) with margin, short enough to generate in a couple of seconds.
    private static let frameCount = 150

    @MainActor
    static func run(video: VideoPlayerModel, connection: BoardConnection) async {
        guard UserDefaults.standard.bool(forKey: "videoPerfProbe") else { return }
        do {
            let url = try await generateClip()
            // No board is expected to be connected for this probe; muting
            // skips `activateSessionIfNeeded()` in `startPlayback`, which
            // otherwise has nothing to gain here and could fail on a
            // simulator with no audio route.
            video.isMuted = true
            await video.importFile(from: url)
            guard video.hasVideo else {
                logger.error("videoPerfProbe: import did not produce a playable video")
                return
            }
            // `tick()` runs the full decode → luma → quantize path every
            // frame regardless of `connection.connectionState` — only the
            // final send to the board is gated on being connected — so a
            // disconnected `BoardConnection` (the normal state on a
            // simulator with no paired hardware) is sufficient here.
            video.play(connection: connection)
            logger.info("videoPerfProbe: playback started (\(width, privacy: .public)x\(height, privacy: .public), \(frameCount, privacy: .public) frames)")
        } catch {
            logger.error("videoPerfProbe: clip generation failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A moving horizontal-gradient pattern, not a flat colour: each frame is
    /// the same gradient band shifted a little further along, so the
    /// encoder/decoder sees real per-pixel variation frame to frame instead
    /// of a trivially compressible solid frame, without needing a bundled
    /// real-world clip. It is still synthetic — a flat-colour clip would
    /// understate decode cost, but this shape is enough to give the encoder
    /// actual gradients to compress and the decoder actual pixels to
    /// convert, which is what matters for the luma/quantize split.
    private static func generateClip() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoPerfProbe-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // Two widths' worth of gradient bytes so any horizontal shift can be
        // copied out as one contiguous window per row, without wrapping
        // per-pixel on every frame.
        var rowTemplate = [UInt8](repeating: 0, count: width * 2 * 4)
        for x in 0..<(width * 2) {
            let value = UInt8((x * 255 / width) % 256)
            let base = x * 4
            rowTemplate[base] = value
            rowTemplate[base + 1] = value
            rowTemplate[base + 2] = value
            rowTemplate[base + 3] = 255
        }

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var bufferOpt: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOpt)
            guard status == kCVReturnSuccess, let buffer = bufferOpt else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let shift = (index * 8) % width
                let rowBytes = width * 4
                rowTemplate.withUnsafeBytes { templateRaw in
                    let source = templateRaw.baseAddress!.advanced(by: shift * 4)
                    for y in 0..<height {
                        let dest = base.advanced(by: y * bytesPerRow)
                        dest.copyMemory(from: source, byteCount: rowBytes)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: frameRate)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
#endif
