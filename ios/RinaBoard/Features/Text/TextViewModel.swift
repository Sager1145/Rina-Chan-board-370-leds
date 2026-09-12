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

    var text: String = "" { didSet { scheduleDraftSave() } }
    /// Set as soon as the user types, so a board-side restore can't silently
    /// discard an unsent draft (§26).
    var userEditedText = false
    var restoreConflict = false
    /// The board's text, held aside while a conflict is unresolved.
    var boardText: String?

    // MARK: Speed (§27)

    /// The speed asked for, in the board protocol's own unit (fps).
    var requestedFps: Double = 10 { didSet { scheduleDraftSave() } }

    var draftStorageError: String?
    private var draftSaveTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var restoringDraft = false
    private struct Draft: Codable { var version = 1; var text: String; var fps: Double }

    func restoreDraft() async {
        do {
            guard let data = try await DraftStorage.shared.read("text"), !userEditedText else { return }
            let draft = try JSONDecoder().decode(Draft.self, from: data)
            guard draft.version == 1 else { return }
            restoringDraft = true
            text = draft.text; requestedFps = Double(clampFps(draft.fps)); userEditedText = true
            didLoadDefaults = true
            restoringDraft = false
        } catch {
            draftStorageError = String(
                format: NSLocalizedString("无法恢复文字草稿：%@", comment: "text draft restore failed"),
                error.localizedDescription
            )
        }
    }

    private func scheduleDraftSave() {
        guard !restoringDraft else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.persistDraft()
        }
    }

    func persistDraft() async {
        do {
            let data = try JSONEncoder().encode(Draft(text: text, fps: requestedFps))
            try await DraftStorage.shared.write(data, name: "text")
            draftStorageError = nil
        } catch {
            draftStorageError = String(
                format: NSLocalizedString("文字草稿尚未保存：%@", comment: "text draft persistence failed"),
                error.localizedDescription
            )
        }
    }

    func releaseOutput() {
        uploadTask?.cancel()
        uploadTask = nil
        suspendPreviewLoop()
        boundTimelineId = nil
        localPhase = nil
    }

    // MARK: Transport

    var uploadProgress: Double = 0
    var isUploading = false
    var isGeneratingFont = false
    var isStepping = false
    var localPhase: String?
    var uploadSummary: String?
    var errorMessage: String?

    /// Any replacement or clear ends a drag in progress: the old index means
    /// nothing on another timeline, and a removed Slider may never report
    /// the end of its drag.
    var timeline: ScrollTimeline? { didSet { cancelScrub() } }
    var boundTimelineId: String?

    // MARK: Preview speed-lock

    private var pll = ScrollPreviewController(frameCount: 1, userFps: 10)
    var displayIndex: Int { pll.displayIndex }
    /// Actual speed measured from board telemetry — never just an echo of
    /// `requestedFps` (§27).
    var measuredFps: Double { pll.measuredFps }
    var lockState: ScrollPreviewController.LockState { pll.lockState }

    var frameCount: Int { timeline?.frameCount ?? 0 }

    /// The frame under the progress bar's thumb while it is being dragged;
    /// the preview shows it instead of the running index until the seek lands.
    var scrubIndex: Int?
    /// True between drag start and release, so a seek still in flight from
    /// the previous drag doesn't clear the new drag's thumb when it lands.
    var isScrubbing = false

    func cancelScrub() {
        isScrubbing = false
        scrubIndex = nil
    }

    /// Whether the board's scroll is paused, taken from `status`: preview
    /// samples only arrive with a newly presented frame, so a plain pause
    /// never reaches them. Set optimistically once a pause/resume is accepted.
    var boardPaused = false

    static let loopPlaybackKey = "textLoopPlayback"
    /// Loop playback preference. The board keeps it in RAM only, so it is
    /// pushed before every upload and after a reconnect restore.
    var loopPlayback: Bool = UserDefaults.standard.object(forKey: TextViewModel.loopPlaybackKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(loopPlayback, forKey: Self.loopPlaybackKey) }
    }

    var previewFrame: PackedFrame {
        let index = scrubIndex ?? displayIndex
        guard let frames = timeline?.frames, index >= 0, index < frames.count else {
            return PackedFrame()
        }
        return frames[index]
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
            // Only retunes a scroll already on the board; taking the output
            // over here would pause another tab's playback.
            await self.sendWithoutClaim(.setScrollInterval(intervalMs: intervalMs, fps: fpsInt), connection: connection)
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
        if !userEditedText { requestedFps = Double(defaults.fpsDefault) }
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
        guard !isUploading else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !exceedsByteLimit else {
            errorMessage = exceedsByteLimit ? TextError.textTooLong.errorDescription : TextError.emptyText.errorDescription
            return
        }
        guard connection.connectionState == .connected else { errorMessage = TextError.notConnected.errorDescription; return }
        let token = connection.output.begin(.text)
        let task = Task { [weak self] in
            await BoardOutputContext.$session.withValue(token) {
                guard let self else { return }
                await self.sendDraft(connection: connection)
            }
        }
        uploadTask = task
        await task.value
        if connection.output.isCurrent(token) { uploadTask = nil }
    }

    private func sendDraft(connection: BoardConnection) async {
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

        // Before the upload auto-starts the scroll, so a short text can't wrap
        // once under a stale setting. Older firmware rejects it; that must not
        // block sending.
        _ = try? await connection.command(.setScrollLoop(loop: loopPlayback))

        do {
            isGeneratingFont = (font == nil)
            let loadedFont = try await loadFontIfNeeded()
            isGeneratingFont = false
            uploadProgress = 0.04

            let fpsInt = clampFps(requestedFps)
            let built = try await Task.detached(priority: .userInitiated) { [loadedFont] in
                try ScrollRasterizer.makeTimeline(text: text, font: loadedFont, fps: fpsInt)
            }.value
            if let token = BoardOutputContext.session { try connection.output.check(token) }
            uploadProgress = 0.34
            timeline = built

            localPhase = "UPLOADING"
            uploadProgress = 0.36
            let token = BoardOutputContext.session
            let onProgress: (Double) -> Void = { [weak self] progress in
                Task { @MainActor in
                    guard let token, connection.output.isCurrent(token) else { return }
                    self?.uploadProgress = 0.36 + progress * 0.5
                }
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
            userEditedText = self.text != text
            uploadProgress = 1.0
            localPhase = nil
            startPreviewLoop()
        } catch is CancellationError {
            localPhase = nil
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
        if await run(connection, { _ = try await $0.command(.pauseScroll) }) { boardPaused = true }
    }

    func resume(connection: BoardConnection) async {
        guard Date() >= scrollLockoutUntil else { return }
        scrollLockoutUntil = Date().addingTimeInterval(0.25)
        if await run(connection, { _ = try await $0.command(.resumeScroll) }) { boardPaused = false }
    }

    func stop(connection: BoardConnection) async {
        let restoreAuto = connection.status?.renderer?.restoreAutoAfterScroll
            ?? (connection.preview?.playback == "scroll")
        if await run(connection, { _ = try await $0.command(.stopScroll(restoreAuto: restoreAuto, clear: true)) }) {
            pllTask?.cancel(); pllTask = nil
            timeline = nil; boundTimelineId = nil; pll.reset()
            boardPaused = false
        }
    }

    /// Stored locally even while disconnected. Deliberately sent without an
    /// output claim: a preference change must not stop another tab's output.
    func setLoopPlayback(_ loop: Bool, connection: BoardConnection) async {
        loopPlayback = loop
        guard connection.connectionState == .connected else { return }
        await sendWithoutClaim(.setScrollLoop(loop: loop), connection: connection)
    }

    func stepFrame(direction: Int, connection: BoardConnection) async {
        isStepping = true
        defer { isStepping = false }
        // The firmware latches a user pause on every step.
        if await run(connection, { _ = try await $0.command(.scrollStep(direction: direction)) }) { boardPaused = true }
    }

    /// Jumps the board to an absolute frame; a playing scroll keeps playing
    /// from there, a paused one stays paused on it.
    func seek(toFrame index: Int, connection: BoardConnection) async {
        defer { if !isScrubbing { scrubIndex = nil } }
        guard frameCount > 0 else { return }
        let clamped = min(frameCount - 1, max(0, index))
        if await run(connection, { _ = try await $0.command(.scrollSeek(frameIndex: clamped)) }) {
            pll.snap(to: clamped)
        }
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
        let generation = connection.connectionGeneration
        let outputSession = connection.output.session
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
            guard rebuilt.frameCount == frameCount,
                  !Task.isCancelled,
                  generation == connection.connectionGeneration,
                  outputSession == connection.output.session else { return }

            timeline = rebuilt
            boundTimelineId = meta.scrollTimelineId
            // Record ownership of what is already on the board, so another
            // tab starting output releases these controls via the stop handler.
            _ = connection.output.claim(.text)
            if !userEditedText { requestedFps = Double(fpsInt) }
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
            _ = try? await connection.command(.setScrollLoop(loop: loopPlayback))
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
                // With loop off the board holds its last frame until the pause
                // reaches us by status; wrapping here would flash the start.
                let heldAtEnd = !self.loopPlayback && self.displayIndex >= self.frameCount - 1
                if !self.boardPaused && !heldAtEnd { self.pll.tick() }
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

    /// Pause state and, while paused, the exact frame — the only way a
    /// pause (user, or end of a non-looping scroll) reaches the app.
    func observe(status: DeviceStatus?) {
        guard let renderer = status?.renderer else { return }
        boardPaused = renderer.firmwareScrollPaused == true
        guard boundTimelineId != nil, !isUploading, localPhase == nil else { return }
        let boardTimelineId = renderer.scrollTimelineId ?? ""
        if renderer.scrollFrameCount == 0 || (!boardTimelineId.isEmpty && boardTimelineId != boundTimelineId) {
            // Stopped or replaced elsewhere (hardware button, another
            // client): unbind so the controls grey out rather than send
            // commands the board silently accepts and ignores.
            boundTimelineId = nil
            suspendPreviewLoop()
            pll.reset()
            boardPaused = false
            return
        }
        guard boardPaused, let index = renderer.scrollFrameIndex, renderer.scrollFrameCount == frameCount else { return }
        pll.snap(to: index)
    }

    // MARK: Labels

    func phaseKey(connection: BoardConnection) -> String {
        if let localPhase { return localPhase }
        if isStepping { return "STEPPING" }
        let active = connection.status?.renderer?.firmwareScrollActive ?? connection.preview?.firmwareScrollActive
        guard active == true else { return "IDLE" }
        return boardPaused ? "PAUSED" : "ACTIVE"
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

    /// For settings (speed, loop) that must never take the output from
    /// another tab.
    private func sendWithoutClaim(_ command: RinaCommand, connection: BoardConnection) async {
        do {
            _ = try await connection.command(command)
        } catch is CancellationError {
        } catch RatePumpError.dropped {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Returns whether the command reached the board and was accepted.
    @discardableResult
    private func run(_ connection: BoardConnection,
                     _ body: @escaping (BoardConnection) async throws -> Void) async -> Bool {
        do {
            // A transport button is an explicit request to drive the scroll,
            // so it takes the output over; bailing out when another source
            // owned it made the buttons silently do nothing.
            let token = connection.output.claim(.text)
            try await connection.withOutput(token) { try await body(connection) }
            errorMessage = nil
            return true
        } catch is CancellationError {
        } catch RatePumpError.dropped {
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }
}
