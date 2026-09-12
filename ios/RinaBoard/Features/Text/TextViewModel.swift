import Foundation
import RinaCore

/// Text tab state (design guide §22–§29): the scrolling-text pipeline, moved
/// off the old combined Control screen.
///
/// The local preview is phase-locked to the board rather than free-running:
/// `ScrollPreviewController` takes the board's measured speed as its target
/// frequency and the reported frame index as its phase reference, then makes
/// small timing corrections so the phone and the physical board don't visibly
/// drift apart (§27–§29).
@Observable
@MainActor
final class TextViewModel {
    // MARK: Draft text (§25)

    var text: String = ""
    /// Set as soon as the user types, so a board-side restore can't silently
    /// discard an unsent draft (§26).
    var userEditedText = false
    var restoreConflict = false
    /// The board's text, held aside while a conflict is unresolved.
    var boardText: String?

    // MARK: Speed (§27)

    /// The speed asked for, in the board protocol's own unit (fps).
    var requestedFps: Double = 10

    // MARK: Transport

    var uploadProgress: Double = 0
    var isUploading = false
    var isGeneratingFont = false
    var isStepping = false
    var localPhase: String?
    var uploadSummary: String?
    var errorMessage: String?

    var timeline: ScrollTimeline?
    var boundTimelineId: String?

    // MARK: Preview speed-lock

    private var pll = ScrollPreviewController(frameCount: 1, userFps: 10)
    var displayIndex: Int { pll.displayIndex }
    /// Actual speed measured from board telemetry — never just an echo of
    /// `requestedFps` (§27).
    var measuredFps: Double { pll.measuredFps }
    var lockState: ScrollPreviewController.LockState { pll.lockState }

    var frameCount: Int { timeline?.frameCount ?? 0 }

    var previewFrame: PackedFrame {
        guard let frames = timeline?.frames, displayIndex >= 0, displayIndex < frames.count else {
            return PackedFrame()
        }
        return frames[displayIndex]
    }

    var visibleCharCount: Int { ScrollText.visibleCharCount(text) }
    var byteCount: Int { ScrollText.utf8ByteCount(text) }
    var exceedsByteLimit: Bool { byteCount > ScrollText.maxTextBytes }

    private var font: ArkPixelFont?
    private var pllTask: Task<Void, Never>?
    private var scrollLockoutUntil: Date = .distantPast
    private var didLoadDefaults = false
    private weak var activeConnection: BoardConnection?

    @ObservationIgnored private let fpsSender: LatestValueSender<Double>

    init() {
        let box = WeakBox<TextViewModel>()
        fpsSender = LatestValueSender<Double>(minInterval: 0.12) { fps in
            guard let self = box.value,
                  let connection = self.activeConnection,
                  self.boundTimelineId != nil else { return }
            let fpsInt = Int(fps.rounded())
            let intervalMs = ScrollRasterizer.intervalMs(forFps: fpsInt)
            await self.run(connection) {
                _ = try await $0.command(.setScrollInterval(intervalMs: intervalMs, fps: fpsInt))
            }
        }
        box.value = self
    }

    enum TextError: LocalizedError {
        case fontMissing
        case emptyText
        case textTooLong
        case tooManyFrames(Int)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .fontMissing:
                return NSLocalizedString("字体资源缺失", comment: "font resource missing")
            case .emptyText:
                return NSLocalizedString("请输入要滚动显示的文字", comment: "empty scroll text")
            case .textTooLong:
                return NSLocalizedString("文本超过 4096 字节", comment: "scroll text too long")
            case .tooManyFrames(let count):
                return String(format: NSLocalizedString("生成帧数过多(%lld > 3072)，请缩短文字",
                                                        comment: "too many scroll frames"), count)
            case .notConnected:
                return NSLocalizedString("设备未连接", comment: "not connected")
            }
        }
    }

    // MARK: Bootstrap

    func loadDefaultsIfNeeded() {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        let defaults = RinaResources.scrollTextDefaults(bundle: .main)
        if text.isEmpty { text = defaults.defaultText }
        requestedFps = Double(defaults.fpsDefault)
    }

    func editText(_ newValue: String) {
        userEditedText = true
        text = ScrollText.truncate(newValue)
    }

    // MARK: Conflict resolution (§26)

    func keepDraft() {
        restoreConflict = false
        boardText = nil
    }

    func useBoardText() {
        if let boardText { text = boardText }
        restoreConflict = false
        boardText = nil
        userEditedText = false
    }

    // MARK: Send (§24)

    func send(connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = TextError.notConnected.errorDescription
            return
        }
        errorMessage = nil
        restoreConflict = false
        let text = self.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = TextError.emptyText.errorDescription
            return
        }
        // Never silently truncate on the wire (§25) — refuse and say why.
        guard !ScrollText.exceedsByteLimit(text) else {
            errorMessage = TextError.textTooLong.errorDescription
            return
        }

        isUploading = true
        uploadProgress = 0.02
        localPhase = "GENERATING"
        defer { isUploading = false }

        do {
            isGeneratingFont = (font == nil)
            let loadedFont = try await loadFontIfNeeded()
            isGeneratingFont = false
            uploadProgress = 0.04

            let fpsInt = clampFps(requestedFps)
            let built = try await Task.detached(priority: .userInitiated) { [loadedFont] in
                try ScrollRasterizer.makeTimeline(text: text, font: loadedFont, fps: fpsInt)
            }.value
            uploadProgress = 0.34
            timeline = built

            localPhase = "UPLOADING"
            uploadProgress = 0.36
            let onProgress: (Double) -> Void = { [weak self] progress in
                Task { @MainActor in self?.uploadProgress = 0.36 + progress * 0.5 }
            }
            let reply: ScrollUploadReply
            do {
                reply = try await connection.startScrollBitmapUpload(
                    timeline: built, fps: fpsInt, sourceText: built.text, onProgress: onProgress
                )
                uploadSummary = String(format: NSLocalizedString("已发送 %lld B（位图）", comment: "scroll bitmap upload size"),
                                       built.bitmap.packedBytes().count)
            } catch ScrollUploadError.timelineMismatch(let expected, let got) {
                // Firmware predating the bitmap upload path, or a rasterisation
                // disagreement: fall back once to raw per-frame upload.
                errorMessage = nil
                localPhase = "UPLOADING"
                uploadProgress = 0.36
                reply = try await connection.startScrollUpload(
                    frames: built.frames,
                    fps: Double(fpsInt),
                    timelineId: built.timelineId,
                    fontId: ScrollRasterizer.fontId,
                    generatorVersion: ScrollRasterizer.generatorVersion,
                    sourceText: built.text,
                    onProgress: onProgress
                )
                uploadSummary = String(
                    format: NSLocalizedString("已发送 %1$lld B（逐帧回退，位图预期 frames=%2$lld rotation=%3$lld，实际 frames=%4$lld rotation=%5$lld）",
                                              comment: "scroll per-frame fallback upload size"),
                    built.frames.count * PackedFrame.byteCount,
                    expected.frames, expected.rotation, got.frames, got.rotation
                )
            }
            uploadProgress = 0.90
            localPhase = "STARTING"
            let boundId = reply.timelineId ?? built.timelineId
            boundTimelineId = boundId
            pll = ScrollPreviewController(frameCount: built.frameCount, userFps: Double(fpsInt))
            pll.bind(timelineId: boundId, frameCount: built.frameCount)
            userEditedText = false
            uploadProgress = 1.0
            localPhase = nil
            startPreviewLoop()
        } catch let error as ScrollRasterizer.RasterizerError {
            switch error {
            case .emptyText: errorMessage = TextError.emptyText.errorDescription
            case .textTooLong: errorMessage = TextError.textTooLong.errorDescription
            case .tooManyFrames(let count): errorMessage = TextError.tooManyFrames(count).errorDescription
            }
            localPhase = nil
        } catch {
            errorMessage = error.localizedDescription
            localPhase = nil
        }
    }

    private func clampFps(_ fps: Double) -> Int {
        max(RinaLinkConstants.scrollFpsMin, min(RinaLinkConstants.scrollFpsMax, Int(fps.rounded())))
    }

    private func loadFontIfNeeded() async throws -> ArkPixelFont {
        if let font { return font }
        guard let url = Bundle.main.url(forResource: "ark12", withExtension: "json") else {
            throw TextError.fontMissing
        }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try ArkPixelFont.loadBundled(url: url)
        }.value
        font = loaded
        return loaded
    }

    // MARK: Playback (§24)

    func pause(connection: BoardConnection) async {
        guard Date() >= scrollLockoutUntil else { return }
        scrollLockoutUntil = Date().addingTimeInterval(0.25)
        await run(connection) { _ = try await $0.command(.pauseScroll) }
    }

    func resume(connection: BoardConnection) async {
        guard Date() >= scrollLockoutUntil else { return }
        scrollLockoutUntil = Date().addingTimeInterval(0.25)
        await run(connection) { _ = try await $0.command(.resumeScroll) }
    }

    func stop(connection: BoardConnection) async {
        let restoreAuto = connection.status?.renderer?.restoreAutoAfterScroll
            ?? (connection.preview?.playback == "scroll")
        await run(connection) { _ = try await $0.command(.stopScroll(restoreAuto: restoreAuto, clear: true)) }
        pllTask?.cancel()
        pllTask = nil
        timeline = nil
        boundTimelineId = nil
        pll.reset()
    }

    func stepFrame(direction: Int, connection: BoardConnection) async {
        isStepping = true
        defer { isStepping = false }
        await run(connection) { _ = try await $0.command(.scrollStep(direction: direction)) }
    }

    func setRequestedFps(_ fps: Double, connection: BoardConnection) {
        let clamped = min(Double(RinaLinkConstants.scrollFpsMax),
                          max(Double(RinaLinkConstants.scrollFpsMin), fps))
        requestedFps = clamped
        // Live retune only while a session with the same timeline is running.
        guard boundTimelineId != nil else { return }
        activeConnection = connection
        fpsSender.submit(clamped)
    }

    // MARK: Restore from the board (§26)

    func restoreOnConnect(connection: BoardConnection) async {
        guard let meta = try? await connection.getScrollMeta() else { return }
        guard meta.uploadComplete == true,
              let frameCount = meta.frameCount, frameCount > 0,
              let sourceText = meta.sourceText, !sourceText.isEmpty,
              meta.fontId == ScrollRasterizer.fontId,
              meta.generatorVersion == ScrollRasterizer.generatorVersion
        else { return }

        do {
            let loadedFont = try await loadFontIfNeeded()
            let fpsInt = clampFps(meta.uiFps.map(Double.init) ?? requestedFps)
            let rebuilt = try await Task.detached(priority: .userInitiated) { [loadedFont] in
                try ScrollRasterizer.makeTimeline(text: sourceText, font: loadedFont, fps: fpsInt)
            }.value
            guard rebuilt.frameCount == frameCount else { return }

            timeline = rebuilt
            boundTimelineId = meta.scrollTimelineId
            requestedFps = Double(fpsInt)
            pll = ScrollPreviewController(frameCount: rebuilt.frameCount, userFps: Double(fpsInt))
            if let timelineId = meta.scrollTimelineId {
                pll.bind(timelineId: timelineId, frameCount: rebuilt.frameCount)
            }
            if let index = meta.frameIndex {
                _ = pll.record(sample: PreviewSync(
                    presentedSeq: 0,
                    source: "manual",
                    scrollTimelineId: meta.scrollTimelineId,
                    presentedFrameIndex: index,
                    presentedFrameCount: rebuilt.frameCount,
                    firmwareScrollPaused: true
                ), nowMs: nowMs())
            }
            // An unsent local draft is never overwritten; the user chooses.
            if userEditedText, text != sourceText {
                boardText = sourceText
                restoreConflict = true
            } else {
                text = sourceText
            }
            startPreviewLoop()
        } catch {
            // Re-rasterisation failure: leave as a silent no-op restore.
        }
    }

    // MARK: Preview phase lock (§28, §29)

    private func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// Advances the preview by exactly one frame per iteration, sleeping for
    /// the PLL's next delay — which tracks the board's measured speed and
    /// corrects phase drift — rather than a fixed local interval.
    func startPreviewLoop() {
        pllTask?.cancel()
        pllTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delayMs = self.pll.nextDelayMs(nowMs: self.nowMs())
                self.pll.tick()
                try? await Task.sleep(nanoseconds: UInt64(max(1, delayMs) * 1_000_000))
            }
        }
    }

    /// Stops the preview loop without discarding the bound timeline (app
    /// backgrounded or board disconnected).
    func suspendPreviewLoop() {
        pllTask?.cancel()
        pllTask = nil
    }

    func resumePreviewLoopIfNeeded() {
        guard boundTimelineId != nil, pllTask == nil else { return }
        startPreviewLoop()
    }

    /// Feeds one board sample into the PLL (identity check, phase filtering,
    /// rate estimation, pause/step snap).
    func observe(preview: PreviewSync?) {
        guard let preview, boundTimelineId != nil else { return }
        if pll.record(sample: preview, nowMs: nowMs()) == .identityMismatch {
            timeline = nil
            boundTimelineId = nil
            pllTask?.cancel()
            pllTask = nil
            pll.reset()
        }
    }

    // MARK: Labels

    func phaseKey(connection: BoardConnection) -> String {
        if let localPhase { return localPhase }
        if isStepping { return "STEPPING" }
        guard let preview = connection.preview else { return "IDLE" }
        guard preview.firmwareScrollActive == true else { return "IDLE" }
        return preview.firmwareScrollPaused == true ? "PAUSED" : "ACTIVE"
    }

    static func phaseLabel(_ key: String) -> String {
        switch key.uppercased() {
        case "GENERATING": return NSLocalizedString("生成中", comment: "scroll phase generating")
        case "UPLOADING": return NSLocalizedString("上传中", comment: "scroll phase uploading")
        case "STARTING": return NSLocalizedString("启动中", comment: "scroll phase starting")
        case "ACTIVE": return NSLocalizedString("播放中", comment: "scroll phase active")
        case "STEPPING": return NSLocalizedString("单步", comment: "scroll phase stepping")
        case "STOPPING": return NSLocalizedString("停止中", comment: "scroll phase stopping")
        case "PAUSED": return NSLocalizedString("已暂停", comment: "scroll phase paused")
        case "RESTORING": return NSLocalizedString("恢复中", comment: "scroll phase restoring")
        default: return NSLocalizedString("空闲", comment: "scroll phase idle")
        }
    }

    static func lockStateLabel(_ state: ScrollPreviewController.LockState) -> String {
        switch state {
        case .locked: return NSLocalizedString("锁定", comment: "PLL locked")
        case .gentle: return NSLocalizedString("微调", comment: "PLL gentle")
        case .catchup: return NSLocalizedString("追赶", comment: "PLL catching up")
        case .free: return NSLocalizedString("自由", comment: "PLL free-running")
        }
    }

    // MARK: Command plumbing

    private func run(_ connection: BoardConnection,
                     _ body: @escaping (BoardConnection) async throws -> Void) async {
        do {
            try await body(connection)
        } catch is CancellationError {
        } catch RatePumpError.dropped {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
