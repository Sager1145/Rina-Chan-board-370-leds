import AVFoundation
import CoreTransferable
import Foundation
import PhotosUI
import QuartzCore
import RinaCore
import SwiftUI
import UniformTypeIdentifiers

/// Where imported videos are kept. It lives outside the model so the Photos
/// transfer closure, which runs off the main actor, can copy into it directly.
enum VideoFileStore {
    static let shared: PresetLiveFileStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return PresetLiveFileStore(directory: base.appendingPathComponent("Video", isDirectory: true))
    }()
}

/// A video handed over by the Photos picker, already copied into app storage.
/// The picker's own file is deleted as soon as the closure returns, so the
/// copy has to happen inside it.
struct PickedVideo: Transferable {
    let url: URL
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let stored = try VideoFileStore.shared.copyIntoStorage(received.file)
            return PickedVideo(url: stored, title: received.file.deletingPathExtension().lastPathComponent)
        }
    }
}

private enum VideoImportError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        NSLocalizedString("该文件不包含视频画面", comment: "imported file has no video track")
    }
}

/// Plays an imported video locally and streams it to the board as on/off
/// faces.
///
/// Modelled on n2048-creative-technology/video-to-LED-matrix: frames are
/// pulled from the player at a fixed send rate, downsampled to the matrix
/// grid, and handed to a single-slot "latest frame wins" sender, so a slow
/// link drops frames instead of falling behind the video. The downsample and
/// on/off decision live in `VideoFrameQuantizer` (RinaCore).
@Observable
@MainActor
final class VideoPlayerModel {
    static let frameRates = [10, 15, 24, 30]

    private(set) var title: String?
    private(set) var isLoading = false
    private(set) var isPlaying = false
    private(set) var positionMs = 0
    private(set) var durationMs = 0
    private(set) var previewFrame = PackedFrame()
    var errorMessage: String?

    var settings: VideoFrameQuantizer.Settings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            refreshCurrentFrame()
        }
    }

    var frameRate: Int {
        didSet { defaults.set(frameRate, forKey: Self.frameRateKey) }
    }

    var loops: Bool {
        didSet { defaults.set(loops, forKey: Self.loopsKey) }
    }

    var isMuted: Bool {
        didSet {
            guard isMuted != oldValue else { return }
            defaults.set(isMuted, forKey: Self.mutedKey)
            player?.isMuted = isMuted
            if isPlaying, !isMuted, let connection = lastConnection { play(connection: connection) }
        }
    }

    var hasVideo: Bool { player != nil }
    var needsBoardResume: Bool { isPlaying && outputSession == nil }

    private static let fileKey = "videoFile"
    private static let titleKey = "videoTitle"
    private static let fitKey = "videoFit"
    private static let modeKey = "videoMode"
    private static let thresholdKey = "videoThreshold"
    private static let autoThresholdKey = "videoAutoThreshold"
    private static let invertKey = "videoInvert"
    private static let mirrorKey = "videoMirror"
    private static let frameRateKey = "videoFrameRate"
    private static let loopsKey = "videoLoops"
    private static let mutedKey = "videoMuted"

    /// Longest edge of the image the quantizer samples from. The grid is
    /// 22×18 with 5 samples per cell axis, so anything past ~110 px adds cost
    /// without changing the result.
    private static let samplingEdge: CGFloat = 160

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: PresetLiveFileStore
    /// Observed so the source preview picks up a newly imported video.
    private(set) var player: AVPlayer?
    /// Upright pixel size of the current video, `.zero` when there is none.
    private(set) var videoSize: CGSize = .zero
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var imageGenerator: AVAssetImageGenerator?
    @ObservationIgnored private var storedURL: URL?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var frameLoop: Task<Void, Never>?
    @ObservationIgnored private var stillTask: Task<Void, Never>?
    @ObservationIgnored private var sender: LatestValueSender<PackedFrame>?
    @ObservationIgnored private var lastLuma: VideoFrameQuantizer.LumaImage?
    @ObservationIgnored private var lastSubmitted: PackedFrame?
    @ObservationIgnored private weak var lastConnection: BoardConnection?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var playbackStartTask: Task<Void, Never>?
    /// True while this model is itself taking a new lease. `begin` runs the
    /// stop handler of the previous holder, which can be this model; that
    /// call must not pause the playback the lease is being taken for.
    @ObservationIgnored private var isAcquiringOutput = false
    private var outputSession: UUID?

    init(defaults: UserDefaults = .standard, store: PresetLiveFileStore = VideoFileStore.shared) {
        self.defaults = defaults
        self.store = store
        settings = VideoFrameQuantizer.Settings(
            fit: defaults.string(forKey: Self.fitKey).flatMap(VideoFrameQuantizer.Fit.init(rawValue:)) ?? .fill,
            mode: defaults.string(forKey: Self.modeKey).flatMap(VideoFrameQuantizer.Mode.init(rawValue:)) ?? .threshold,
            threshold: defaults.object(forKey: Self.thresholdKey) as? Double ?? 0.5,
            autoThreshold: defaults.object(forKey: Self.autoThresholdKey) as? Bool ?? true,
            invert: defaults.bool(forKey: Self.invertKey),
            mirror: defaults.bool(forKey: Self.mirrorKey)
        )
        let storedRate = defaults.integer(forKey: Self.frameRateKey)
        frameRate = Self.frameRates.contains(storedRate) ? storedRate : 15
        loops = defaults.object(forKey: Self.loopsKey) as? Bool ?? true
        isMuted = defaults.bool(forKey: Self.mutedKey)
        sender = LatestValueSender(minInterval: 0.01) { [weak self] frame in
            await self?.send(frame)
        }
    }

    // MARK: Import

    func restoreLastVideoIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        guard player == nil, let name = defaults.string(forKey: Self.fileKey) else { return }
        let url = store.storedURL(named: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            forgetStoredVideo()
            return
        }
        let title = defaults.string(forKey: Self.titleKey) ?? url.deletingPathExtension().lastPathComponent
        Task { await load(url, title: title, isNewImport: false) }
    }

    func importFile(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        isLoading = true
        let store = self.store
        do {
            // Videos can be hundreds of megabytes; never copy on the main actor.
            let stored = try await Task.detached { try store.copyIntoStorage(url) }.value
            await load(stored, title: url.deletingPathExtension().lastPathComponent, isNewImport: true)
        } catch {
            isLoading = false
            reportImportFailure(error)
        }
    }

    func importFromPhotos(_ item: PhotosPickerItem) async {
        isLoading = true
        do {
            guard let picked = try await item.loadTransferable(type: PickedVideo.self) else {
                isLoading = false
                return
            }
            await load(picked.url, title: picked.title, isNewImport: true)
        } catch {
            isLoading = false
            reportImportFailure(error)
        }
    }

    private func reportImportFailure(_ error: Error) {
        errorMessage = String(format: NSLocalizedString("导入视频失败：%@", comment: "video import failed"),
                              error.localizedDescription)
    }

    /// Validates the file before it replaces anything: a file that turns out
    /// not to be a playable video leaves the current one untouched.
    private func load(_ url: URL, title: String, isNewImport: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }

        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { throw VideoImportError.noVideoTrack }
            let duration = try await asset.load(.duration)
            // Applies each track's orientation transform, so portrait phone
            // videos reach the output upright instead of rotated.
            let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            guard generation == loadGeneration else {
                if isNewImport { store.remove(url) }
                return
            }
            install(asset: asset, composition: composition, duration: duration, url: url, title: title)
        } catch {
            guard generation == loadGeneration else { return }
            // Either way the copy is unusable; a restored one would otherwise
            // sit in Application Support with nothing left pointing at it.
            store.remove(url)
            if isNewImport {
                reportImportFailure(error)
            } else {
                forgetStoredVideo()
            }
        }
    }

    private func install(asset: AVURLAsset, composition: AVMutableVideoComposition,
                         duration: CMTime, url: URL, title: String) {
        stop()
        teardownPlayer()
        if let previous = storedURL, previous != url { store.remove(previous) }

        let size = Self.samplingSize(for: composition.renderSize)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = composition
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackReachedEnd() }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)

        self.player = player
        videoSize = composition.renderSize
        videoOutput = output
        imageGenerator = generator
        storedURL = url
        self.title = title
        durationMs = duration.isNumeric ? max(0, Int((duration.seconds * 1000).rounded())) : 0
        positionMs = 0
        lastLuma = nil
        previewFrame = PackedFrame()
        errorMessage = nil
        defaults.set(url.lastPathComponent, forKey: Self.fileKey)
        defaults.set(title, forKey: Self.titleKey)
        renderStill(atMs: 0)
    }

    private func forgetStoredVideo() {
        defaults.removeObject(forKey: Self.fileKey)
        defaults.removeObject(forKey: Self.titleKey)
    }

    private func teardownPlayer() {
        frameLoop?.cancel()
        frameLoop = nil
        stillTask?.cancel()
        stillTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        videoSize = .zero
        videoOutput = nil
        imageGenerator = nil
    }

    // MARK: Transport

    func play(connection: BoardConnection) {
        playbackStartTask?.cancel()
        player?.pause()
        deactivateSessionIfNeeded()
        playbackStartTask = Task { [weak self] in
            await self?.startPlayback(connection: connection)
        }
    }

    private func startPlayback(connection: BoardConnection) async {
        guard !Task.isCancelled else { return }
        guard let player else {
            errorMessage = NSLocalizedString("请先导入视频", comment: "play pressed with no video")
            return
        }
        lastConnection = connection
        // Audio first: taking the board stops whichever feature holds it, and
        // that must not happen for a start that is about to fail.
        if !isMuted, !(await activateSessionIfNeeded()) { return }
        guard !Task.isCancelled else { return }
        if connection.connectionState == .connected {
            acquireOutput(connection: connection)
        } else {
            outputSession = nil
        }
        if durationMs > 0, positionMs >= durationMs - 50 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
            positionMs = 0
        }
        stillTask?.cancel()
        player.play()
        isPlaying = true
        errorMessage = nil
        // Put the face that is already on screen on the board right away
        // instead of waiting for the video to decode its next frame.
        refreshCurrentFrame()
        startFrameLoop()
    }

    func pause() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        suspendBoardOutput()
        player?.pause()
        deactivateSessionIfNeeded()
        isPlaying = false
        frameLoop?.cancel()
        frameLoop = nil
    }

    func stop() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        pause()
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        positionMs = 0
        deactivateSessionIfNeeded()
        renderStill(atMs: 0)
    }

    func seek(toMs ms: Int) {
        guard let player else { return }
        let clamped = max(0, min(durationMs, ms))
        positionMs = clamped
        player.seek(to: CMTime(value: CMTimeValue(clamped), timescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        // While playing, the video output delivers the new position on its own.
        if !isPlaying { renderStill(atMs: clamped) }
    }

    private func playbackReachedEnd() {
        guard isPlaying, let player else { return }
        if loops {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        } else {
            positionMs = durationMs
            isPlaying = false
            suspendBoardOutput()
            frameLoop?.cancel()
            frameLoop = nil
            deactivateSessionIfNeeded()
        }
    }

    // MARK: Board output

    /// Registered as this source's stop handler: another feature took the
    /// board. Connected, that means stop playing, like 演出 does; while
    /// disconnected only the (already dead) lease is dropped.
    func releaseOutput(connected: Bool) {
        guard !isAcquiringOutput else { return }
        if connected { pause() } else { suspendBoardOutput() }
    }

    func suspendBoardOutput() {
        outputSession = nil
        lastSubmitted = nil
        sender?.cancel()
    }

    /// Explicitly takes a fresh lease for a video that kept playing locally
    /// after the board connection dropped.
    func resumeBoardOutput(connection: BoardConnection) {
        guard isPlaying, connection.connectionState == .connected, outputSession == nil else { return }
        lastConnection = connection
        acquireOutput(connection: connection)
        refreshCurrentFrame()
    }

    private func acquireOutput(connection: BoardConnection) {
        isAcquiringOutput = true
        defer { isAcquiringOutput = false }
        outputSession = connection.output.begin(.video)
        lastSubmitted = nil
    }

    private func send(_ frame: PackedFrame) async {
        guard let connection = lastConnection, connection.connectionState == .connected,
              let token = outputSession, connection.output.isCurrent(token) else { return }
        do {
            _ = try await connection.setFrame(frame, playback: .idle, reason: "video", outputSession: token)
        } catch is CancellationError {
        } catch RatePumpError.dropped {
            if outputSession == token { lastSubmitted = nil }
        } catch {
            guard outputSession == token, connection.output.isCurrent(token) else { return }
            lastSubmitted = nil
            errorMessage = String(format: NSLocalizedString("发送失败：%@", comment: "frame send failed"),
                                  error.localizedDescription)
        }
    }

    // MARK: Frames

    private func startFrameLoop() {
        frameLoop?.cancel()
        frameLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .seconds(1.0 / Double(max(1, self.frameRate))))
            }
        }
    }

    private func tick() {
        guard let player, let videoOutput else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite {
            positionMs = max(0, min(durationMs, Int((seconds * 1000).rounded())))
        }
        // The system stops AVPlayer on its own for a call, Siri or unplugged
        // headphones. Follow it, or the page keeps claiming playback while
        // the board freezes on one face. Reaching the end also stops the
        // player; that case belongs to `playbackReachedEnd`.
        if player.rate == 0, positionMs < durationMs - 250 {
            pause()
            return
        }
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
              let luma = Self.luma(from: buffer) else { return }
        lastLuma = luma
        render(luma)
    }

    /// Paused frames come from an image generator: the video output only
    /// delivers frames while the player is running.
    private func renderStill(atMs ms: Int) {
        guard let generator = imageGenerator else { return }
        stillTask?.cancel()
        let time = CMTime(value: CMTimeValue(ms), timescale: 1000)
        stillTask = Task { [weak self] in
            guard let image = try? await generator.image(at: time).image,
                  let luma = Self.luma(from: image) else { return }
            guard !Task.isCancelled, let self, self.imageGenerator === generator, !self.isPlaying else { return }
            self.lastLuma = luma
            self.render(luma)
        }
    }

    private func refreshCurrentFrame() {
        if let lastLuma { render(lastLuma) }
    }

    private func render(_ luma: VideoFrameQuantizer.LumaImage) {
        let frame = VideoFrameQuantizer.frame(from: luma, settings: settings)
        previewFrame = frame
        // Identical consecutive faces are common (static shots, letterboxes);
        // they cost a round trip each and change nothing on the board.
        guard outputSession != nil, frame != lastSubmitted else { return }
        lastSubmitted = frame
        sender?.submit(frame)
    }

    private func saveSettings() {
        defaults.set(settings.fit.rawValue, forKey: Self.fitKey)
        defaults.set(settings.mode.rawValue, forKey: Self.modeKey)
        defaults.set(settings.threshold, forKey: Self.thresholdKey)
        defaults.set(settings.autoThreshold, forKey: Self.autoThresholdKey)
        defaults.set(settings.invert, forKey: Self.invertKey)
        defaults.set(settings.mirror, forKey: Self.mirrorKey)
    }

    // MARK: Image conversion

    nonisolated private static func samplingSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: samplingEdge, height: samplingEdge) }
        let scale = min(1, samplingEdge / max(size.width, size.height))
        return CGSize(width: max(2, (size.width * scale).rounded()),
                      height: max(2, (size.height * scale).rounded()))
    }

    /// Rec. 709 luma from a BGRA buffer. Strides over the source when the
    /// output ignored the requested size, so cost stays bounded either way.
    nonisolated private static func luma(from buffer: CVPixelBuffer) -> VideoFrameQuantizer.LumaImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let stride = max(1, Int((Double(max(width, height)) / Double(samplingEdge)).rounded(.up)))
        let w = width / stride
        let h = height / stride
        guard w > 0, h > 0 else { return nil }
        let source = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = source + y * stride * bytesPerRow
            for x in 0..<w {
                let p = row + x * stride * 4
                let luma = (54 * Int(p[2]) + 183 * Int(p[1]) + 19 * Int(p[0])) >> 8
                pixels[y * w + x] = UInt8(min(255, luma))
            }
        }
        return VideoFrameQuantizer.LumaImage(width: w, height: h, pixels: pixels)
    }

    nonisolated private static func luma(from image: CGImage) -> VideoFrameQuantizer.LumaImage? {
        let size = samplingSize(for: CGSize(width: image.width, height: image.height))
        let w = Int(size.width)
        let h = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? VideoFrameQuantizer.LumaImage(width: w, height: h, pixels: pixels) : nil
    }

    // MARK: Audio session

    private func activateSessionIfNeeded() async -> Bool {
        guard !Task.isCancelled else { return false }
        sessionActive = true
        do {
            try await PlaybackAudioSession.acquire(.video)
            guard !Task.isCancelled else { return false }
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            deactivateSessionIfNeeded()
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func deactivateSessionIfNeeded() {
        guard sessionActive else { return }
        sessionActive = false
        PlaybackAudioSession.release(.video)
    }
}
