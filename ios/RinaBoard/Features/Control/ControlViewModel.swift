import Foundation
import RinaCore

/// State + logic for the Control tab (FEATURE_INVENTORY §A). Owns local
/// "optimistic" drafts for brightness/mode/auto-interval/color (each
/// suppresses firmware echo for 2 s after a local touch, per A2/A3/A5/A6),
/// the scroll-text pipeline (A8-A15) and a compact preview speed-lock that
/// prefers the board's `currentFrame`/`preview` samples over local
/// extrapolation (SCROLL_RASTERIZER_SPEC §6-§7).
@Observable
@MainActor
final class ControlViewModel {
    // MARK: Brightness (A2)
    var brightnessDraft: Double = 50
    private var brightnessTouchUntil: Date = .distantPast

    // MARK: Mode / face (A3/A4)
    var modeOverride: String?
    private var modeOverrideUntil: Date = .distantPast
    /// Optimistic local preview of `autoFaceIndex` while a B1/B2 step is
    /// in flight, suppressing firmware echo for 2s like the other overrides.
    var faceIndexOverride: Int?
    private var faceIndexOverrideUntil: Date = .distantPast

    // MARK: Auto interval (A5)
    var autoIntervalDraft: Double = 3.0 // seconds
    private var autoIntervalTouchUntil: Date = .distantPast

    // MARK: Colour (A6/A7)
    var colorHexDraft: String = "#ec3fc7"
    private var colorTouchUntil: Date = .distantPast
    var selectedParentId: String?
    var colorPresets: ColorPresets?

    // MARK: Scroll text (A8-A15)
    var scrollText: String = ""
    var userEditedText = false
    var scrollFps: Double = 10
    var uploadProgress: Double = 0
    var isUploading = false
    var isGeneratingFont = false
    var localPhase: String?
    var restoreConflict = false
    var errorMessage: String?
    var timeline: ScrollTimeline?
    var boundTimelineId: String?
    /// e.g. "已发送 812 B（位图）" / "已发送 15264 B（逐帧回退）" — set after
    /// every successful `sendScroll()`; shown in the scroll card's readouts row.
    var uploadSummary: String?
    /// Whether a single-frame step (A12) is currently in flight, so the view
    /// can show "单步" instead of inferring phase from the last `preview` sample.
    var isStepping = false

    /// Preview speed-lock (PLL) core, ported bit-for-bit from the WebUI
    /// (SCROLL_RASTERIZER_SPEC §6). Exposed read-only via the computed
    /// properties below so the view never mutates PLL internals directly.
    private var pll = ScrollPreviewController(frameCount: 1, userFps: 10)
    var displayIndex: Int { pll.displayIndex }
    var measuredFps: Double { pll.measuredFps }
    var lockState: ScrollPreviewController.LockState { pll.lockState }

    static func lockStateLabel(_ state: ScrollPreviewController.LockState) -> String {
        switch state {
        case .locked: return "锁定"
        case .gentle: return "微调"
        case .catchup: return "追赶"
        case .free: return "自由"
        }
    }

    private var font: ArkPixelFont?
    private var pllTask: Task<Void, Never>?
    private var scrollLockoutUntil: Date = .distantPast
    private var didLoadDefaults = false
    /// Bound at the start of any command so the coalescing senders below
    /// (created lazily, without a `connection` parameter) know where to send.
    private weak var activeConnection: BoardConnection?

    @ObservationIgnored private let brightnessSender: LatestValueSender<Int>
    @ObservationIgnored private let autoIntervalSender: LatestValueSender<Double>
    @ObservationIgnored private let fpsSender: LatestValueSender<Double>

    init() {
        // A closure that captures `self` (even weakly) is escaping and trips
        // Swift's definite-initialization check before all stored properties
        // (including the senders themselves) are set. Route the capture
        // through a box that's populated *after* `self` is fully
        // initialized instead.
        let box = ControlViewModelBox()
        brightnessSender = LatestValueSender<Int>(minInterval: 0.12) { raw in
            guard let self = box.value, let connection = self.activeConnection else { return }
            await self.run(connection) { _ = try await $0.command(.setBrightness(raw: raw)) }
        }
        autoIntervalSender = LatestValueSender<Double>(minInterval: 0.12) { seconds in
            guard let self = box.value, let connection = self.activeConnection else { return }
            let ms = Int((seconds * 1000).rounded())
            await self.run(connection) { _ = try await $0.command(.setAutoInterval(ms: ms)) }
        }
        fpsSender = LatestValueSender<Double>(minInterval: 0.12) { fps in
            guard let self = box.value, let connection = self.activeConnection, self.boundTimelineId != nil else { return }
            let fpsInt = Int(fps.rounded())
            let ms = ScrollRasterizer.intervalMs(forFps: fpsInt)
            await self.run(connection) { _ = try await $0.command(.setScrollInterval(intervalMs: ms, fps: fpsInt)) }
        }
        box.value = self
    }

    enum ControlError: LocalizedError {
        case fontMissing
        case emptyText
        case textTooLong
        case tooManyFrames(Int)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .fontMissing: return "字体资源缺失"
            case .emptyText: return "请输入要滚动显示的文字"
            case .textTooLong: return "文本超过 4096 字节"
            case .tooManyFrames(let n): return "生成帧数过多(\(n) > 3072)，请缩短文字"
            case .notConnected: return "设备未连接"
            }
        }
    }

    // MARK: Bootstrap

    func loadDefaultsIfNeeded() {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        colorPresets = try? RinaResources.colorPresets(bundle: .main)
        let defaults = RinaResources.scrollTextDefaults(bundle: .main)
        if scrollText.isEmpty {
            scrollText = defaults.defaultText
        }
        scrollFps = Double(defaults.fpsDefault)
    }

    // MARK: Sync from firmware (echo suppression)

    func syncBrightness(from status: DeviceStatus?) {
        guard Date() >= brightnessTouchUntil, let b = status?.renderer?.brightness else { return }
        brightnessDraft = Double(b)
    }

    func syncAutoInterval(from status: DeviceStatus?) {
        guard Date() >= autoIntervalTouchUntil, let ms = status?.renderer?.autoIntervalMs else { return }
        autoIntervalDraft = Double(ms) / 1000.0
    }

    func syncColor(from status: DeviceStatus?) {
        guard Date() >= colorTouchUntil, let hex = status?.renderer?.color else { return }
        colorHexDraft = hex
        selectedParentId = colorPresets?.parent(containing: hex).map { String($0.id) }
    }

    func syncMode(from status: DeviceStatus?) {
        guard Date() >= modeOverrideUntil else { return }
        modeOverride = nil
    }

    func effectiveMode(status: DeviceStatus?) -> String {
        modeOverride ?? status?.renderer?.mode ?? "manual"
    }

    func syncFaceIndex(from status: DeviceStatus?) {
        guard Date() >= faceIndexOverrideUntil else { return }
        faceIndexOverride = nil
    }

    func effectiveFaceIndex(status: DeviceStatus?) -> Int? {
        faceIndexOverride ?? status?.renderer?.autoFaceIndex
    }

    // MARK: Brightness

    func setBrightness(_ raw: Int, connection: BoardConnection) async {
        let clamped = min(200, max(10, raw))
        brightnessDraft = Double(clamped)
        brightnessTouchUntil = Date().addingTimeInterval(2)
        activeConnection = connection
        brightnessSender.submit(clamped)
    }

    // MARK: Mode / face

    func toggleMode(connection: BoardConnection) async {
        let current = effectiveMode(status: connection.status)
        modeOverride = current == "auto" ? "manual" : "auto"
        modeOverrideUntil = Date().addingTimeInterval(2)
        await run(connection) { _ = try await $0.command(.button(button: "B3")) }
    }

    /// A3/A4: if a scroll is currently active, stop it first (without
    /// clearing the frame or restoring the pre-scroll auto mode — that's the
    /// firmware's job on the *next* explicit stop) so B1/B2 face-stepping
    /// doesn't fight the scroll renderer; then optimistically preview the new
    /// face index locally before the firmware's status/preview catches up.
    func step(face direction: Int, connection: BoardConnection) async {
        let button = direction > 0 ? "B1" : "B2"
        if connection.status?.renderer?.firmwareScrollActive == true {
            await run(connection) { _ = try await $0.command(.stopScroll(restoreAuto: false, clear: false)) }
        }
        if let count = connection.status?.renderer?.autoFaceCount, count > 0 {
            let current = effectiveFaceIndex(status: connection.status) ?? 0
            faceIndexOverride = ((current + direction) % count + count) % count
            faceIndexOverrideUntil = Date().addingTimeInterval(2)
        }
        await run(connection) { _ = try await $0.command(.button(button: button)) }
    }

    // MARK: Auto interval

    func setAutoInterval(_ seconds: Double, connection: BoardConnection) async {
        let clamped = min(10, max(0.5, seconds))
        autoIntervalDraft = clamped
        autoIntervalTouchUntil = Date().addingTimeInterval(2)
        activeConnection = connection
        autoIntervalSender.submit(clamped)
    }

    // MARK: Colour

    func setColor(hex: String, connection: BoardConnection) async {
        guard let (r, g, b) = RGBHex.parseHex(hex) else {
            errorMessage = "颜色格式应为 #RRGGBB"
            return
        }
        let cleaned = RGBHex.formatHex(r: r, g: g, b: b)
        colorHexDraft = cleaned
        selectedParentId = colorPresets?.parent(containing: cleaned).map { String($0.id) }
        colorTouchUntil = Date().addingTimeInterval(2)
        await run(connection) { _ = try await $0.command(.setColor(hex: cleaned)) }
    }

    // MARK: Scroll text generation + upload (A9)

    func sendScroll(connection: BoardConnection) async {
        guard connection.connectionState == .connected else {
            errorMessage = ControlError.notConnected.errorDescription
            return
        }
        errorMessage = nil
        restoreConflict = false
        let text = scrollText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = ControlError.emptyText.errorDescription
            return
        }
        guard !ScrollText.exceedsByteLimit(text) else {
            errorMessage = ControlError.textTooLong.errorDescription
            return
        }

        isUploading = true
        uploadProgress = 0.02
        localPhase = "生成中"
        defer { isUploading = false }

        do {
            isGeneratingFont = (font == nil)
            let loadedFont = try await loadFontIfNeeded()
            isGeneratingFont = false
            uploadProgress = 0.04

            let fpsInt = max(1, min(60, Int(scrollFps.rounded())))
            let built = try await Task.detached(priority: .userInitiated) { [loadedFont] in
                try ScrollRasterizer.makeTimeline(text: text, font: loadedFont, fps: fpsInt)
            }.value
            uploadProgress = 0.34
            timeline = built

            localPhase = "上传中"
            uploadProgress = 0.36
            let progressHandler: (Double) -> Void = { [weak self] progress in
                Task { @MainActor in self?.uploadProgress = 0.36 + progress * 0.5 }
            }
            let reply: ScrollUploadReply
            let sentBytes: Int
            do {
                reply = try await connection.startScrollBitmapUpload(
                    timeline: built,
                    fps: fpsInt,
                    sourceText: built.text,
                    onProgress: progressHandler
                )
                sentBytes = built.bitmap.packedBytes().count
                uploadSummary = "已发送 \(sentBytes) B（位图）"
            } catch ScrollUploadError.timelineMismatch(let expected, let got) {
                // Older firmware (pre-§7.1) or a rasterisation disagreement:
                // fall back once to the raw-frame upload so it still works.
                errorMessage = nil
                localPhase = "上传中（回退到逐帧）"
                uploadProgress = 0.36
                reply = try await connection.startScrollUpload(
                    frames: built.frames,
                    fps: Double(fpsInt),
                    timelineId: built.timelineId,
                    fontId: ScrollRasterizer.fontId,
                    generatorVersion: ScrollRasterizer.generatorVersion,
                    sourceText: built.text,
                    onProgress: progressHandler
                )
                sentBytes = built.frames.count * PackedFrame.byteCount
                uploadSummary = "已发送 \(sentBytes) B（逐帧回退，位图预期 frames=\(expected.frames) rotation=\(expected.rotation)，实际 frames=\(got.frames) rotation=\(got.rotation)）"
            }
            uploadProgress = 0.90
            localPhase = "启动中"
            let boundId = reply.timelineId ?? built.timelineId
            boundTimelineId = boundId
            pll = ScrollPreviewController(frameCount: built.frameCount, userFps: Double(fpsInt))
            pll.bind(timelineId: boundId, frameCount: built.frameCount)
            userEditedText = false
            uploadProgress = 1.0
            localPhase = nil
            startPLLIfNeeded()
        } catch let error as ScrollRasterizer.RasterizerError {
            switch error {
            case .emptyText: errorMessage = ControlError.emptyText.errorDescription
            case .textTooLong: errorMessage = ControlError.textTooLong.errorDescription
            case .tooManyFrames(let n): errorMessage = ControlError.tooManyFrames(n).errorDescription
            }
            localPhase = nil
        } catch {
            errorMessage = String(describing: error)
            localPhase = nil
        }
    }

    private func loadFontIfNeeded() async throws -> ArkPixelFont {
        if let font { return font }
        guard let url = Bundle.main.url(forResource: "ark12", withExtension: "json") else {
            throw ControlError.fontMissing
        }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try ArkPixelFont.loadBundled(url: url)
        }.value
        font = loaded
        return loaded
    }

    // MARK: Scroll transport controls (A10-A13)

    func pauseScroll(connection: BoardConnection) async {
        guard Date() >= scrollLockoutUntil else { return }
        scrollLockoutUntil = Date().addingTimeInterval(0.25)
        await run(connection) { _ = try await $0.command(.pauseScroll) }
    }

    func resumeScroll(connection: BoardConnection) async {
        guard Date() >= scrollLockoutUntil else { return }
        scrollLockoutUntil = Date().addingTimeInterval(0.25)
        await run(connection) { _ = try await $0.command(.resumeScroll) }
    }

    func stopScroll(connection: BoardConnection) async {
        let restoreAuto = connection.status?.renderer?.restoreAutoAfterScroll ?? (connection.preview?.playback == "scroll")
        await run(connection) { _ = try await $0.command(.stopScroll(restoreAuto: restoreAuto, clear: true)) }
        pllTask?.cancel()
        timeline = nil
        boundTimelineId = nil
        pll.reset()
    }

    func stepFrame(direction: Int, connection: BoardConnection) async {
        isStepping = true
        defer { isStepping = false }
        await run(connection) { _ = try await $0.command(.scrollStep(direction: direction)) }
    }

    func setScrollFps(_ fps: Double, connection: BoardConnection) async {
        let clamped = min(60, max(1, fps))
        scrollFps = clamped
        // Live retune only while a session with the same timeline is active.
        guard boundTimelineId != nil else { return }
        activeConnection = connection
        fpsSender.submit(clamped)
    }

    // MARK: Restore on connect (SCROLL_RASTERIZER_SPEC §7)

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
            let fpsInt = max(1, min(60, Int((meta.uiFps.map(Double.init) ?? scrollFps).rounded())))
            let rebuilt = try await Task.detached(priority: .userInitiated) { [loadedFont] in
                try ScrollRasterizer.makeTimeline(text: sourceText, font: loadedFont, fps: fpsInt)
            }.value
            guard rebuilt.frameCount == frameCount else { return }

            timeline = rebuilt
            boundTimelineId = meta.scrollTimelineId
            scrollFps = Double(fpsInt)
            pll = ScrollPreviewController(frameCount: rebuilt.frameCount, userFps: Double(fpsInt))
            if let tid = meta.scrollTimelineId {
                pll.bind(timelineId: tid, frameCount: rebuilt.frameCount)
            }
            if let idx = meta.frameIndex {
                _ = pll.record(sample: PreviewSync(
                    presentedSeq: 0,
                    source: "manual",
                    scrollTimelineId: meta.scrollTimelineId,
                    presentedFrameIndex: idx,
                    presentedFrameCount: rebuilt.frameCount,
                    firmwareScrollPaused: true
                ), nowMs: nowMs())
            }
            if userEditedText {
                restoreConflict = true
            } else {
                scrollText = sourceText
            }
            startPLLIfNeeded()
        } catch {
            // Re-rasterisation failure: leave as a silent no-op restore.
        }
    }

    // MARK: Preview speed-lock (SCROLL_RASTERIZER_SPEC §6)

    /// Wall-clock milliseconds for feeding the (Foundation-free) PLL core.
    private func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// Drives the small local-preview strip / frame-index readout: each
    /// iteration advances `displayIndex` by exactly one frame, sleeping for
    /// `pll.nextDelayMs`, which is phase/rate-locked to the firmware's
    /// `preview` samples (fed in via `observe(preview:)`) rather than a fixed
    /// free-run interval.
    func startPLLIfNeeded() {
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

    /// Suspends the local preview loop without discarding the bound timeline
    /// (app backgrounded or the board disconnected); call `resumePLLIfNeeded`
    /// to restart it once foregrounded/reconnected.
    func suspendPLL() {
        pllTask?.cancel()
        pllTask = nil
    }

    /// Restarts the preview loop if a timeline is still bound (app
    /// foregrounded again).
    func resumePLLIfNeeded() {
        guard boundTimelineId != nil, pllTask == nil else { return }
        startPLLIfNeeded()
    }

    /// Feeds one `preview` sample into the PLL core (identity check, phase
    /// filtering, rate estimation, pause/step snap — SCROLL_RASTERIZER_SPEC
    /// §6/§7); called from the view's `onChange(of: connection.preview)`.
    func observe(preview: PreviewSync?) {
        guard let preview, boundTimelineId != nil else { return }
        let outcome = pll.record(sample: preview, nowMs: nowMs())
        if outcome == .identityMismatch {
            timeline = nil
            boundTimelineId = nil
            pllTask?.cancel()
            pll.reset()
        }
    }

    var previewFrame: PackedFrame {
        guard let frames = timeline?.frames, displayIndex >= 0, displayIndex < frames.count else {
            return PackedFrame()
        }
        return frames[displayIndex]
    }

    static func phaseLabel(_ raw: String?) -> String {
        switch raw?.uppercased() {
        case "IDLE": return "空闲"
        case "GENERATING": return "生成中"
        case "UPLOADING": return "上传中"
        case "STARTING": return "启动中"
        case "ACTIVE": return "播放中"
        case "STEPPING": return "单步"
        case "STOPPING": return "停止中"
        case "PAUSED": return "已暂停"
        case "RESTORING": return "恢复中"
        case "STALE": return "已过期"
        case "DROPPED": return "已丢弃"
        default: return "空闲"
        }
    }

    // MARK: Init helper

    private func run(_ connection: BoardConnection, _ body: @escaping (BoardConnection) async throws -> Void) async {
        do {
            try await body(connection)
        } catch is CancellationError {
            // Superseded by a newer coalesced send; not a user-facing error.
        } catch RatePumpError.dropped {
            // Evicted by a later in-flight command with the same key
            // (e.g. rapid slider drags); the latest value always wins.
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

/// Post-init weak capture cell so the coalescing senders' closures don't
/// capture `self` directly during `ControlViewModel.init` (which would trip
/// Swift's definite-initialization check on the sender properties
/// themselves).
@MainActor
private final class ControlViewModelBox {
    weak var value: ControlViewModel?
}
