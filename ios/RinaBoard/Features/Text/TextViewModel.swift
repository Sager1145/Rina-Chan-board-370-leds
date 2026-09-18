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
    var userEditedText = false { didSet { scheduleDraftSave() } }
    var restoreConflict = false
    /// The board's text, held aside while a conflict is unresolved.
    var boardText: String?

    // MARK: Speed (§27)

    /// The speed asked for, in the board protocol's own unit (fps). Remembered
    /// with the draft; while a scroll is bound it follows the board's actual
    /// tick interval, so the slider never shows a speed the board isn't running.
    var requestedFps: Double = 10 { didSet { scheduleDraftSave() } }

    /// The latest retune for the board. Reports that disagree are ignored until
    /// the board has accepted it and then echoed it, so echoes of older values
    /// still in flight can't make the slider jump back mid-drag.
    private struct PendingFps {
        var fps: Int
        /// Before delivery, a cap in case the send never completes; after it,
        /// a short grace for reports the board emitted before taking it.
        var until: Date
        var delivered = false
    }
    private var pendingFps: PendingFps?
    /// Bumped by each speed change, so a draft read that finishes later can't
    /// overwrite a slider move made while it was reading.
    private var speedEdits = 0
    /// The bound scroll's speed as the board last reported (or was uploaded
    /// with) — where the slider returns when a retune never lands.
    private var lastBoardFps: Int?

    var draftStorageError: String?
    private var draftSaveTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var restoringDraft = false
    /// False until `restoreDraft()` has run: launch defaults saved before the
    /// read would overwrite the stored draft and its remembered speed.
    private var draftRestoreFinished = false
    private struct Draft: Codable {
        var version = 1
        var text: String
        var fps: Double
        var userEdited: Bool? = nil
    }

    func restoreDraft() async {
        let speedEditsBefore = speedEdits
        defer {
            let editedWhileReading = !draftRestoreFinished
                && (userEditedText || speedEdits != speedEditsBefore)
            draftRestoreFinished = true
            if editedWhileReading { scheduleDraftSave() }
        }
        do {
            guard let data = try await DraftStorage.shared.read("text"), !userEditedText else { return }
            let draft = try JSONDecoder().decode(Draft.self, from: data)
            guard draft.version == 1 else { return }
            restoringDraft = true
            text = draft.text
            if speedEdits == speedEditsBefore { requestedFps = Double(clampFps(draft.fps)) }
            userEditedText = draft.userEdited ?? true
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
        guard !restoringDraft, draftRestoreFinished else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.persistDraft()
        }
    }

    func persistDraft() async {
        guard draftRestoreFinished else { return }
        do {
            let data = try JSONEncoder().encode(Draft(text: text, fps: requestedFps, userEdited: userEditedText))
            try await DraftStorage.shared.write(data, name: "text")
            draftStorageError = nil
        } catch {
            draftStorageError = String(
                format: NSLocalizedString("保存文字草稿失败：%@", comment: "text draft persistence failed"),
                error.localizedDescription
            )
        }
    }

    func releaseOutput() {
        // Any in-flight upload is now superseded: cancellation is cooperative,
        // so the revision is what actually stops its state writes from landing.
        uploadRevision += 1
        uploadTask?.cancel()
        uploadTask = nil
        clearPlaybackState()
        uploadProgress = 0
        isUploading = false
        isGeneratingFont = false
        isStepping = false
        localPhase = nil
    }

    /// A connection generation or selected-board change invalidates every
    /// board-relative value. Keep the editable draft and its requested speed,
    /// but never carry a timeline cursor over to a different board session.
    func connectionChanged() {
        releaseOutput()
    }

    // MARK: Transport

    var uploadProgress: Double = 0
    var isUploading = false
    /// Identifies the upload that currently owns `isUploading`/`localPhase`/
    /// `errorMessage`. Bumped at admission and by `releaseOutput()`.
    private var uploadRevision = 0
    var isGeneratingFont = false
    var isStepping = false
    var localPhase: String?
    var uploadSummary: String?
    var errorMessage: String?

    /// Any replacement or clear ends a drag in progress: the old index means
    /// nothing on another timeline, and a removed Slider may never report
    /// the end of its drag.
    var timeline: ScrollTimeline? { didSet { cancelScrub() } }
    var boundTimelineId: String? {
        didSet { if oldValue != boundTimelineId { cancelScrub() } }
    }

    // MARK: Preview speed-lock

    /// Ignored by `@Observable`: every field a view could read from this is
    /// mutated on each `tick()` (up to 120 Hz), which would otherwise
    /// re-evaluate the body of anything reading any pll-derived property on
    /// every tick (perf PR-9). Views observe `playhead` instead; `pll` stays
    /// the single source of truth and keeps its existing semantics exactly.
    @ObservationIgnored private var pll = ScrollPreviewController(frameCount: 1, userFps: 10)
    /// Small `@Observable` mirror of the pll fields a view reads, kept in
    /// sync by `syncPlayhead()` after every pll mutation (perf PR-9).
    @ObservationIgnored let playhead = TextPreviewPlayhead()
    var displayIndex: Int { playhead.displayIndex }
    /// Actual speed measured from board telemetry — never just an echo of
    /// `requestedFps` (§27). Nil while nothing is playing on the board.
    var measuredFps: Double? {
        guard boundTimelineId != nil, !boardPaused else { return nil }
        return playhead.measuredFps
    }
    var lockState: ScrollPreviewController.LockState { playhead.lockState }

    /// Copies the pll fields views read into `playhead`. Must be called after
    /// every mutation of `pll` (perf PR-9) — `pll` itself is
    /// `@ObservationIgnored`, so nothing else notices those mutations.
    private func syncPlayhead() {
        playhead.update(displayIndex: pll.displayIndex, measuredFps: pll.measuredFps, lockState: pll.lockState)
    }

    var frameCount: Int { timeline?.frameCount ?? 0 }

    /// The frame under the progress bar's thumb while it is being dragged;
    /// the preview shows it instead of the running index until the seek lands.
    var scrubIndex: Int?
    /// True between drag start and release, so a seek still in flight from
    /// the previous drag doesn't clear the new drag's thumb when it lands.
    var isScrubbing = false

    private var scrubGeneration = 0

    struct ScrubCommit {
        let frameIndex: Int
        let timelineId: String
        let generation: Int
    }

    func beginScrub() {
        guard !isScrubbing, boundTimelineId != nil, frameCount > 1 else { return }
        scrubGeneration += 1
        isScrubbing = true
        if scrubIndex == nil { scrubIndex = displayIndex }
    }

    /// Slider updates are local only, including updates before its begin callback.
    func updateScrub(toFrame index: Int) {
        guard boundTimelineId != nil, frameCount > 1 else { return }
        scrubIndex = min(frameCount - 1, max(0, index))
    }

    /// Capture the release synchronously, before the UI launches an async command.
    /// Repeated end callbacks and cancelled drags produce no command.
    func endScrub() -> ScrubCommit? {
        guard isScrubbing else { return nil }
        isScrubbing = false
        guard let index = scrubIndex, let identity = boundTimelineId else { return nil }
        return ScrubCommit(frameIndex: index, timelineId: identity, generation: scrubGeneration)
    }

    func commitScrub(_ commit: ScrubCommit, connection: BoardConnection) async {
        guard !isScrubbing, commit.generation == scrubGeneration,
              commit.timelineId == boundTimelineId,
              connection.connectionState == .connected else { return }
        await seek(toFrame: commit.frameIndex, connection: connection)
    }

    func cancelScrub() {
        scrubGeneration += 1
        isScrubbing = false
        scrubIndex = nil
    }

    /// Whether the board's scroll is paused, taken from `status`: preview
    /// samples only arrive with a newly presented frame, so a plain pause
    /// never reaches them. Set optimistically once a pause/resume is accepted.
    var boardPaused = false

    static let loopPlaybackKey = "textLoopPlayback"
    /// Sent before new uploads; reconnect adopts the board’s current setting.
    var loopPlayback: Bool = UserDefaults.standard.object(forKey: TextViewModel.loopPlaybackKey) as? Bool ?? true {
        didSet {
            if oldValue != loopPlayback { UserDefaults.standard.set(loopPlayback, forKey: Self.loopPlaybackKey) }
        }
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
    /// The board and timeline a queued speed change was submitted *for*.
    /// Written only by `setRequestedFps`, so a later `restoreOnConnect` on a
    /// different board cannot silently retarget a value already in the queue.
    private var fpsDestination: (connection: BoardConnection, timelineId: String)?

    @ObservationIgnored private let fpsSender: LatestValueSender<Double>

    init() {
        let box = WeakBox<TextViewModel>()
        fpsSender = LatestValueSender<Double>(minInterval: 0.12) { fps in
            guard let self = box.value,
                  let destination = self.fpsDestination,
                  // Still the same board, still the same timeline. The drain
                  // loop can resume after a stalled command on another board,
                  // by which time `activeConnection` may already point at a
                  // board this value was never meant for.
                  destination.connection === self.activeConnection,
                  self.boundTimelineId == destination.timelineId else { return }
            let connection = destination.connection
            let fpsInt = Int(fps.rounded())
            let intervalMs = ScrollRasterizer.intervalMs(forFps: fpsInt)
            // Only retunes a scroll already on the board; taking the output
            // over here would pause another tab's playback.
            let accepted = await self.sendWithoutClaim(.setScrollInterval(intervalMs: intervalMs, fps: fpsInt),
                                                       connection: connection)
            // The board never changed, so no status will come to correct the
            // slider: fall back to what it last reported, unless a newer
            // value is already on its way.
            guard self.pendingFps?.fps == fpsInt else { return }
            if accepted {
                self.pendingFps?.delivered = true
                self.pendingFps?.until = Date().addingTimeInterval(0.75)
            } else {
                self.pendingFps = nil
                self.adoptBoardFps(self.lastBoardFps)
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
        if !userEditedText { requestedFps = Double(defaults.fpsDefault) }
    }

    func editText(_ newValue: String) {
        userEditedText = true
        text = ScrollText.truncate(newValue)
    }

    /// Called when the editor loses focus: a cleared field goes back to the
    /// sample text instead of leaving nothing to send.
    func restoreDefaultTextIfEmpty() {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = RinaResources.scrollTextDefaults(bundle: .main).defaultText
        userEditedText = false
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
        // Claim the busy flag synchronously at admission. It used to be set
        // inside `sendDraft`, i.e. after a suspension, so the guard above could
        // admit a second upload while the first was still starting.
        uploadRevision += 1
        let revision = uploadRevision
        isUploading = true
        let task = Task { [weak self] in
            await BoardOutputContext.$session.withValue(token) {
                guard let self else { return }
                await self.sendDraft(connection: connection, revision: revision)
            }
        }
        uploadTask = task
        await task.value
        if connection.output.isCurrent(token) { uploadTask = nil }
    }

    private func sendDraft(connection: BoardConnection, revision: Int) async {
        // Only the newest upload owns the shared upload state. `releaseOutput()`
        // bumps the revision, so a superseded task unwinding later can neither
        // clear the current upload's busy flag nor overwrite its error/phase.
        defer { if revision == uploadRevision { isUploading = false } }
        guard revision == uploadRevision else { return }
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

        uploadProgress = 0.02
        localPhase = "GENERATING"

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
            pendingFps = nil
            lastBoardFps = nil
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
            syncPlayhead()
            userEditedText = self.text != text
            scheduleDraftSave()
            boardPaused = false
            activeConnection = connection
            lastBoardFps = fpsInt
            // A slider move during the upload had nothing bound to retune, or
            // its retune was overridden by the upload's own timing: apply it now.
            if clampFps(requestedFps) != fpsInt {
                setRequestedFps(requestedFps, connection: connection)
            }
            if let sample = try? await connection.getPreviewSync() {
                if let token = BoardOutputContext.session { try connection.output.check(token) }
                observe(preview: sample)
            }
            uploadProgress = 1.0
            localPhase = nil
            startPreviewLoop()
        } catch is CancellationError {
            if revision == uploadRevision { localPhase = nil }
        } catch let error as ScrollRasterizer.RasterizerError {
            guard revision == uploadRevision else { return }
            switch error {
            case .emptyText: errorMessage = TextError.emptyText.errorDescription
            case .textTooLong: errorMessage = TextError.textTooLong.errorDescription
            case .tooManyFrames(let count): errorMessage = TextError.tooManyFrames(count).errorDescription
            }
            localPhase = nil
        } catch {
            guard revision == uploadRevision else { return }
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
            syncPlayhead()
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
        guard !isScrubbing, frameCount > 0, let identity = boundTimelineId,
              connection.connectionState == .connected else { return }
        let revision = scrubGeneration
        let connectionGeneration = connection.connectionGeneration
        defer {
            if revision == scrubGeneration, !isScrubbing { scrubIndex = nil }
        }
        let clamped = min(frameCount - 1, max(0, index))
        if await run(connection, { _ = try await $0.command(.scrollSeek(frameIndex: clamped)) }),
           revision == scrubGeneration, identity == boundTimelineId,
           connectionGeneration == connection.connectionGeneration {
            pll.snap(to: clamped)
            syncPlayhead()
        }
    }

    func setRequestedFps(_ fps: Double, connection: BoardConnection) {
        let clamped = min(Double(RinaLinkConstants.scrollFpsMax),
                          max(Double(RinaLinkConstants.scrollFpsMin), fps))
        speedEdits += 1
        requestedFps = clamped
        // Live retune only while a session with the same timeline is running.
        guard let timelineId = boundTimelineId else { return }
        activeConnection = connection
        fpsDestination = (connection, timelineId)
        pendingFps = PendingFps(fps: clampFps(clamped), until: Date().addingTimeInterval(5))
        fpsSender.submit(clamped)
    }

    /// The fps the board is actually ticking at. `scrollIntervalMs` drives the
    /// firmware; `uiFps` is only a label that older uploads left disagreeing
    /// with it, so the label wins only when it maps to that same interval
    /// (it tells 58/59/60 fps apart, which all tick at 17 ms).
    static func boardFps(intervalMs: Int?, uiFps: Int?) -> Int? {
        let label = uiFps.flatMap { $0 > 0 ? $0 : nil }
        guard let intervalMs, intervalMs > 0 else { return label }
        if let label, ScrollRasterizer.intervalMs(forFps: label) == intervalMs { return label }
        return Int((1000.0 / Double(intervalMs)).rounded())
    }

    /// Makes the speed control show what the bound board scroll really runs at.
    private func adoptBoardFps(_ fps: Int?) {
        guard let fps else { return }
        let boardFps = clampFps(Double(fps))
        lastBoardFps = boardFps
        if let pending = pendingFps {
            if pending.fps == boardFps {
                // A match before delivery may be a stale report that happens to
                // agree while older values are still queued ahead of it.
                if pending.delivered { pendingFps = nil }
            } else if Date() < pending.until {
                return
            } else {
                pendingFps = nil
            }
        }
        if clampFps(requestedFps) != boardFps || requestedFps != requestedFps.rounded() {
            requestedFps = Double(boardFps)
        }
    }

    // MARK: Restore from the board (§26)

    func restoreOnConnect(connection: BoardConnection) async {
        let generation = connection.connectionGeneration
        let outputSession = connection.output.session
        guard let meta = try? await connection.getScrollMeta() else { return }
        guard !Task.isCancelled, generation == connection.connectionGeneration,
              outputSession == connection.output.session, !isUploading,
              meta.uploadComplete == true,
              meta.firmwareScrollActive == true,
              let frameCount = meta.frameCount, frameCount > 0,
              let sourceText = meta.sourceText, !sourceText.isEmpty,
              meta.fontId == ScrollRasterizer.fontId,
              meta.generatorVersion == ScrollRasterizer.generatorVersion
        else { return }

        do {
            let loadedFont = try await loadFontIfNeeded()
            let fpsInt = clampFps(Self.boardFps(intervalMs: meta.scrollIntervalMs, uiFps: meta.uiFps)
                .map(Double.init) ?? requestedFps)
            let rebuilt = try await Task.detached(priority: .userInitiated) { [loadedFont] in
                try ScrollRasterizer.makeTimeline(text: sourceText, font: loadedFont, fps: fpsInt)
            }.value
            guard rebuilt.frameCount == frameCount,
                  !Task.isCancelled,
                  generation == connection.connectionGeneration,
                  outputSession == connection.output.session else { return }

            // Font loading/rasterization can take time. Fetch only a small, fresh
            // presentation sample after that work; never replay the old meta cursor.
            let freshPreview = try? await connection.getPreviewSync()
            guard !Task.isCancelled, generation == connection.connectionGeneration,
                  outputSession == connection.output.session, !isUploading else { return }
            if let id = freshPreview?.scrollTimelineId, !id.isEmpty,
               id != meta.scrollTimelineId { return }
            // A retry (fix for "text page stays cleared while the board
            // scrolls") can land after another tab already claimed output —
            // e.g. a status push that was already stale by the time the font
            // finished loading. Never steal it from a live Video/Performance
            // session.
            guard connection.output.source == nil || connection.output.source == .text else { return }
            timeline = rebuilt
            boundTimelineId = meta.scrollTimelineId
            // Record ownership of what is already on the board, so another
            // tab starting output releases these controls via the stop handler.
            _ = connection.output.claim(.text)
            // The speed is board state, not part of the draft: the controls
            // now retune this running scroll, so they must show its rate.
            pendingFps = nil
            lastBoardFps = fpsInt
            requestedFps = Double(fpsInt)
            pll = ScrollPreviewController(frameCount: rebuilt.frameCount, userFps: Double(fpsInt))
            if let timelineId = meta.scrollTimelineId {
                pll.bind(timelineId: timelineId, frameCount: rebuilt.frameCount)
            }
            activeConnection = connection
            boardPaused = freshPreview?.firmwareScrollPaused ?? meta.firmwareScrollPaused ?? false
            if let loop = meta.scrollLoop { loopPlayback = loop }
            if let index = meta.frameIndex { pll.snap(to: index) }
            syncPlayhead()
            if let freshPreview { observe(preview: freshPreview) }
            // An unsent local draft is never overwritten; the user chooses.
            if userEditedText, text != sourceText {
                boardText = sourceText
                restoreConflict = true
            } else {
                text = sourceText
                userEditedText = false
                boardText = nil
                restoreConflict = false
            }
            scheduleDraftSave()
            startPreviewLoop()
        } catch {
            // Re-rasterisation failure: leave as a silent no-op restore.
        }
    }

    // MARK: Preview phase lock (§28, §29)

    private func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    /// Advances the preview by exactly one frame per iteration, sleeping for
    /// the PLL's next delay — which tracks the board's measured speed and
    /// corrects phase drift — rather than a fixed local interval.
    func startPreviewLoop() {
        pllTask?.cancel()
        pllTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delayMs = self.boardPaused ? 250 : self.pll.nextDelayMs(nowMs: self.nowMs())
                // `nextDelayMs` can move `lockState` on its own (before any
                // tick); sync right away so a cancellation during the sleep
                // below can never leave the UI on a stale lock state.
                self.syncPlayhead()
                do { try await Task.sleep(nanoseconds: UInt64(max(1, delayMs) * 1_000_000)) }
                catch { return }
                // With loop off the board holds its last frame until the pause
                // reaches us by status; wrapping here would flash the start.
                let heldAtEnd = !self.loopPlayback && self.displayIndex >= self.frameCount - 1
                if !self.boardPaused && !heldAtEnd {
                    self.pll.tick()
                    RinaPerf.signposter.emitEvent("TextPreviewTick")
                }
                // Sync again after a real tick moves `displayIndex` (the sync
                // above only covers `nextDelayMs`'s own effect on `lockState`).
                self.syncPlayhead()
            }
        }
    }

    /// Stops the preview loop without discarding the bound timeline (app
    /// backgrounded or board disconnected).
    func suspendPreviewLoop() {
        pllTask?.cancel()
        pllTask = nil
    }

    func refreshPreview(connection: BoardConnection) async {
        guard boundTimelineId != nil, connection.connectionState == .connected else { return }
        let generation = connection.connectionGeneration
        let identity = boundTimelineId
        guard let sample = try? await connection.getPreviewSync(), !Task.isCancelled,
              generation == connection.connectionGeneration, identity == boundTimelineId else { return }
        activeConnection = connection
        observe(preview: sample)
        resumePreviewLoopIfNeeded()
    }

    func resumePreviewLoopIfNeeded() {
        guard activeConnection?.connectionState == .connected, boundTimelineId != nil, pllTask == nil else { return }
        startPreviewLoop()
    }

    /// Feeds one board sample into the PLL (identity check, phase filtering,
    /// rate estimation, pause/step snap).
    func observe(preview: PreviewSync?) {
        guard let preview, boundTimelineId != nil else { return }
        let outcome = pll.record(sample: preview, nowMs: nowMs())
        syncPlayhead()
        if outcome != .identityMismatch {
            if let paused = preview.firmwareScrollPaused { boardPaused = paused }
            if let loop = preview.scrollLoop { loopPlayback = loop }
            // Status only arrives when board state changes, so one skipped
            // report would leave the slider wrong; tick samples keep repeating
            // the live interval. A paused sample's interval can be stale.
            if preview.rateEligible == true, !isUploading, localPhase == nil {
                adoptBoardFps(Self.boardFps(intervalMs: preview.scrollIntervalMs, uiFps: preview.uiFps))
            }
        }
        if outcome == .identityMismatch {
            clearPlaybackState()
        }
    }

    /// The last automatic `restoreOnConnect` retry (§26) scheduled from a
    /// status push, keyed by connection generation so a resync-only status
    /// push after a foreground return cannot retry more than once every 5s.
    private var lastRestoreRetry: (generation: UUID, at: Date)?

    /// Pause state and, while paused, the exact frame — the only way a
    /// pause (user, or end of a non-looping scroll) reaches the app.
    ///
    /// `connection` is optional only so existing call sites/tests that never
    /// exercise the retry below don't need updating; real callers always pass
    /// it. When the firmware reports an active scroll but nothing is bound
    /// here (a failed `getStatus`/`restoreOnConnect` during resync left the
    /// Text page empty), retries `restoreOnConnect` — at most once every 5s
    /// per connection generation — instead of waiting for the next connection
    /// change to notice.
    func observe(status: DeviceStatus?, connection: BoardConnection? = nil) {
        guard let status else {
            releaseOutput()
            return
        }
        guard let renderer = status.renderer else { return }
        boardPaused = renderer.firmwareScrollPaused == true
        if let loop = renderer.scrollLoop { loopPlayback = loop }
        if let connection, boundTimelineId == nil, frameCount == 0, !isUploading,
           renderer.firmwareScrollActive == true {
            scheduleRestoreRetryIfNeeded(connection: connection)
        }
        guard boundTimelineId != nil, !isUploading, localPhase == nil else { return }
        let boardTimelineId = renderer.scrollTimelineId ?? ""
        if renderer.scrollFrameCount == 0 || (!boardTimelineId.isEmpty && boardTimelineId != boundTimelineId) {
            // Stopped or replaced elsewhere (hardware button, another
            // client): discard the old cursor and frame count so the progress
            // display becomes empty and its controls cannot send stale commands.
            clearPlaybackState()
            return
        }
        // A retune from another client, the WebUI or a previous app session.
        adoptBoardFps(Self.boardFps(intervalMs: renderer.scrollIntervalMs,
                                    uiFps: renderer.uiFps ?? renderer.scrollFps))
        guard boardPaused, let index = renderer.scrollFrameIndex, renderer.scrollFrameCount == frameCount else { return }
        pll.snap(to: index)
        syncPlayhead()
    }

    private func scheduleRestoreRetryIfNeeded(connection: BoardConnection) {
        let generation = connection.connectionGeneration
        let now = Date()
        if let last = lastRestoreRetry, last.generation == generation, now.timeIntervalSince(last.at) < 5 {
            return
        }
        lastRestoreRetry = (generation, now)
        Task { [weak self] in
            guard let self, connection.connectionGeneration == generation else { return }
            await self.restoreOnConnect(connection: connection)
        }
    }

    /// Clears state that only describes a particular board-side scroll
    /// session. Draft text, conflict state and send preferences are local and
    /// deliberately survive so the user can resend after reconnecting.
    private func clearPlaybackState() {
        suspendPreviewLoop()
        timeline = nil
        boundTimelineId = nil
        pll.reset()
        syncPlayhead()
        activeConnection = nil
        boardPaused = false
        pendingFps = nil
        // Drop any speed change still waiting to drain: its destination is
        // gone, and the drain loop must not outlive this playback session.
        fpsDestination = nil
        fpsSender.cancel()
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
    /// Returns whether the board accepted the command.
    @discardableResult
    private func sendWithoutClaim(_ command: RinaCommand, connection: BoardConnection) async -> Bool {
        do {
            _ = try await connection.command(command)
            return true
        } catch is CancellationError {
        } catch RatePumpError.dropped {
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
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
