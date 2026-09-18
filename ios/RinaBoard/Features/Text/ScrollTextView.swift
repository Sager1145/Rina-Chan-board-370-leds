import SwiftUI
import RinaCore

#if DEBUG
/// Debug-only body-evaluation counters (perf PR-9), used by
/// `TextPreviewInvalidationTests` to prove that the Text tab's per-tick
/// preview updates invalidate only the small subviews that read them, not
/// the parent page. Compiled out of Release.
enum PR9BodyProbe {
    private static var counts: [String: Int] = [:]

    @discardableResult
    static func hit(_ name: String) -> Int {
        let next = (counts[name] ?? 0) + 1
        counts[name] = next
        return next
    }

    static func count(_ name: String) -> Int { counts[name] ?? 0 }

    static func reset() { counts.removeAll() }
}
#endif

/// Text tab (design guide §22–§29): scrolling-text authoring and playback.
///
/// The preview at the top is the app's reconstruction of the board's current
/// scroll animation and is **not** interactive (§22.1). It follows the board's
/// *measured* speed and corrects phase, rather than free-running at the
/// requested fps, so the phone and the physical board stay together (§28/§29).
///
/// Per-tick state (the running preview index, measured fps, PLL lock state —
/// up to 120 Hz while playing) lives on `TextViewModel.playhead`, a separate
/// small `@Observable`, and is read only inside `TextPreviewBoard`,
/// `TextPreviewStatusFooter`, `TextPlaybackProgressBar` and
/// `TextMeasuredFpsRow`/`TextSyncDiagnosticsRows` below (perf PR-9), so this
/// parent body is not re-evaluated on every tick.
struct ScrollTextView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(TextViewModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isEditorFocused: Bool
    @Environment(\.displayScale) private var displayScale
    /// Ark Pixel editor size; follows Dynamic Type, snapped to crisp steps.
    @ScaledMetric(relativeTo: .body) private var editorFontSize: CGFloat = 16

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        #if DEBUG
        let _ = PR9BodyProbe.hit("ScrollTextView")
        #endif
        NavigationStack {
            BoardSplitPage {
                previewBoard
            } status: {
                previewStatus
            } controls: {
                playbackSection
                editorSection
                speedSection
                syncSection
            }
            .listSectionSpacing(.compact)
            .rinaScrollBackground()
            .errorAlert(Bindable(model).errorMessage)
            .toolbar(.hidden, for: .navigationBar)
            .contentMargins(.top, 0, for: .scrollContent)
        }
        .onAppear {
            model.loadDefaultsIfNeeded()
            // Status changes while another tab was showing never reached onChange.
            model.observe(status: connection.status, connection: connection)
        }
        .task { await model.refreshPreview(connection: connection) }
        .onDisappear {
            model.cancelScrub()
            model.suspendPreviewLoop()
        }
        .onChange(of: connection.preview) { _, preview in
            model.observe(preview: preview)
        }
        .onChange(of: connection.status) { _, status in
            model.observe(status: status, connection: connection)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refreshPreview(connection: connection) }
            } else {
                model.suspendPreviewLoop()
            }
        }
    }

    // MARK: §23 Preview

    @ViewBuilder
    private var previewBoard: some View {
        // `.inert` by default: the scroll preview mirrors the board's
        // own animation and is not editable (§22.1).
        TextPreviewBoard(model: model)
    }

    private var previewStatus: some View {
        TextPreviewStatusFooter(model: model, connection: connection)
    }

    // MARK: §24 Playback

    /// Two sections: the pill row clears its cell background, so sharing a
    /// section with ordinary rows left it sitting on top of a broken card.
    @ViewBuilder
    private var playbackSection: some View {
        Section {
            // Transport pills plus the loop toggle (§24): with nothing bound
            // on the board the stop slot becomes "send and play".
            TextPlaybackControls(
                isConnected: isConnected,
                hasTimeline: model.boundTimelineId != nil,
                isPaused: model.boardPaused,
                isUploading: model.isUploading,
                isGeneratingFont: model.isGeneratingFont,
                canSend: !model.exceedsByteLimit,
                loopPlayback: Binding(
                    get: { model.loopPlayback },
                    set: { loop in
                        model.loopPlayback = loop
                        Task { await model.setLoopPlayback(loop, connection: connection) }
                    }
                ),
                loopDisabled: loopUnsupported,
                onSend: { Task { await model.send(connection: connection) } },
                onPlay: { Task { await model.resume(connection: connection) } },
                onPause: { Task { await model.pause(connection: connection) } },
                onStop: { Task { await model.stop(connection: connection) } },
                onStepBackward: { Task { await model.stepFrame(direction: -1, connection: connection) } },
                onStepForward: { Task { await model.stepFrame(direction: 1, connection: connection) } }
            )
        }

        Section {
            // Always present, like the Preset Live tab; greyed out until a
            // timeline is on the board.
            TextPlaybackProgressBar(model: model, connection: connection, isConnected: isConnected)

            if model.isUploading {
                ProgressView(value: model.uploadProgress)
            }
        }
    }

    /// Firmware without `set_scroll_loop` reports scroll state but no
    /// `scrollLoop`; there the toggle could only ever produce a rejection.
    private var loopUnsupported: Bool {
        guard let renderer = connection.status?.renderer else { return false }
        return renderer.scrollFrameCount != nil && renderer.scrollLoop == nil
    }

    // MARK: §25 Text input, §26 restore conflict

    private var editorSection: some View {
        Section {
            // A secondary caption, separate from the tertiary in-field
            // placeholder and the byte-limit footer below (both kept intact):
            // only while the draft is genuinely empty.
            if model.text.isEmpty {
                Text("输入要滚动显示的文字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.restoreConflict {
                VStack(alignment: .leading, spacing: 8) {
                    Label("面板上的文字与本地未发送的草稿不同。", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                    HStack {
                        Button("保留草稿") { model.keepDraft() }
                        Button("使用面板文字") { model.useBoardText() }
                    }
                    .buttonStyle(.pill)
                }
            }

            // The list row is already the card; the editor fills it directly
            // (an inner bordered card read as a double border).
            TextEditor(text: Binding(
                get: { model.text },
                set: { model.editText($0) }
            ))
            .frame(minHeight: 132)
            // Same Ark Pixel font the WebUI uses for this field and the
            // frame generator rasterizes, so the draft previews its glyphs.
            .font(ArkPixelInputFont.font(size: editorFontSize, displayScale: displayScale))
            .scrollContentBackground(.hidden)
            .padding(.top, 6)
            // Leaves room for the character counter in the bottom corner.
            .padding(.bottom, 24)
            .overlay(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("输入要滚动的文字…")
                        .font(ArkPixelInputFont.font(size: editorFontSize, displayScale: displayScale))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(model.visibleCharCount) / \(ScrollText.maxVisibleChars)")
                    .font(.caption)
                    .monospacedDigit()
                    // Over the firmware byte limit the counter carries the
                    // warning the red border used to.
                    .foregroundStyle(model.exceedsByteLimit ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .padding(.trailing, 4)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
                    .accessibilityLabel("字符")
                    .accessibilityValue(Text("\(model.visibleCharCount) / \(ScrollText.maxVisibleChars)"))
            }
            .focused($isEditorFocused)
            .onChange(of: isEditorFocused) { _, focused in
                if !focused { model.restoreDefaultTextIfEmpty() }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .accessibilityLabel("滚动文字内容")
        } footer: {
            if model.exceedsByteLimit {
                Text("超出固件 \(ScrollText.maxTextBytes) 字节上限，发送前请缩短文字；不会自动截断。")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: §27 Speed

    private var speedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("请求速度") {
                    Text(String(format: "%.0f fps", model.requestedFps))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { model.requestedFps },
                        set: { model.setRequestedFps($0, connection: connection) }
                    ),
                    in: Double(RinaLinkConstants.scrollFpsMin)...Double(RinaLinkConstants.scrollFpsMax),
                    step: 1
                )
                .disabled(!isConnected)
                .accessibilityLabel("请求速度")
                .accessibilityValue(Text(String(format: "%.0f fps", model.requestedFps)))
            }

            // Measured from board telemetry, never an echo of the request.
            TextMeasuredFpsRow(model: model)
        }
    }

    // MARK: §29 Sync status

    private var syncSection: some View {
        Section("同步状态") {
            TextSyncDiagnosticsRows(model: model, connection: connection)
        }
    }
}

// MARK: - Per-tick preview subviews (perf PR-9)
//
// Each of these reads `model.displayIndex` / `model.previewFrame` /
// `model.measuredFps` / `model.lockState` — all backed by
// `TextViewModel.playhead` — so only *this* view's body re-evaluates on a
// preview tick or a board sample, not `ScrollTextView`'s.

/// The board preview itself: redrawn on every preview tick.
private struct TextPreviewBoard: View {
    var model: TextViewModel

    var body: some View {
        #if DEBUG
        let _ = PR9BodyProbe.hit("TextPreviewBoard")
        #endif
        BoardPreviewRow(
            frame: model.previewFrame,
            accessibilityDescription: previewAccessibilityDescription
        )
    }

    private var previewAccessibilityDescription: String {
        model.frameCount > 0
            ? String(format: NSLocalizedString("滚动文字预览，第 %1$lld 帧，共 %2$lld 帧",
                                               comment: "scroll preview accessibility summary"),
                     model.displayIndex + 1, model.frameCount)
            : NSLocalizedString("滚动文字预览，暂无内容", comment: "empty scroll preview")
    }
}

/// The frame counter under the preview: also moves every tick while a
/// timeline is bound.
private struct TextPreviewStatusFooter: View {
    var model: TextViewModel
    var connection: BoardConnection

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        #if DEBUG
        let _ = PR9BodyProbe.hit("TextPreviewStatusFooter")
        #endif
        // The playback position once frames exist; before that, how much of
        // the board's text budget the draft uses.
        let frameCounter = model.frameCount > 0
            ? Text("帧 \(model.displayIndex + 1) / \(model.frameCount)")
            : Text("\(model.byteCount) / \(ScrollText.maxTextBytes)")
                .foregroundStyle(model.exceedsByteLimit ? .red : .secondary)
        if model.restoreConflict {
            BoardPreviewStatus("草稿与面板不同", systemImage: "exclamationmark.circle", tone: .pending) {
                frameCounter
            }
        } else if !isConnected {
            BoardPreviewStatus("未连接", systemImage: "circle.slash", tone: .neutral) {
                frameCounter
            }
        } else {
            let phase = model.phaseKey(connection: connection)
            let (systemImage, tone): (String, BoardPreviewStatusTone) = switch phase {
            case "ACTIVE": ("play.circle", .live)
            case "PAUSED": ("pause.circle", .neutral)
            case "IDLE": ("stop.circle", .neutral)
            default: ("arrow.triangle.2.circlepath.circle", .pending)
            }
            BoardPreviewStatus(Text(TextViewModel.phaseLabel(phase)), systemImage: systemImage, tone: tone) {
                frameCounter
            }
        }
    }
}

/// Draggable position on the bound timeline, like the Preset Live tab's. The
/// preview follows the thumb while dragging; the board seeks once, on
/// release, so a drag never floods the command pump. Its shown position
/// follows the playhead while nothing is being dragged, so it moves every
/// tick.
private struct TextPlaybackProgressBar: View {
    var model: TextViewModel
    var connection: BoardConnection
    var isConnected: Bool

    var body: some View {
        #if DEBUG
        let _ = PR9BodyProbe.hit("TextPlaybackProgressBar")
        #endif
        let shownIndex = model.scrubIndex ?? model.displayIndex
        return VStack(alignment: .leading, spacing: 4) {
            Slider(
                value: Binding(
                    get: { Double(model.scrubIndex ?? model.displayIndex) },
                    set: { model.updateScrub(toFrame: Int($0.rounded())) }
                ),
                in: 0...Double(max(1, model.frameCount - 1)),
                onEditingChanged: { editing in
                    if editing {
                        model.beginScrub()
                    } else if let commit = model.endScrub() {
                        Task { await model.commitScrub(commit, connection: connection) }
                    }
                }
            )
            .disabled(!isConnected || model.boundTimelineId == nil || model.frameCount < 2)
            // A disabled Slider may never report the end of its drag.
            .onChange(of: isConnected) { _, connected in
                if !connected { model.cancelScrub() }
            }
            .accessibilityLabel("播放进度")
            // VoiceOver adjusts through the value setter without an editing
            // phase, which would leave the scrub stuck; seek directly instead.
            .accessibilityAdjustableAction { direction in
                guard model.frameCount > 1 else { return }
                let step = max(1, model.frameCount / 20)
                let target = model.displayIndex + (direction == .increment ? step : -step)
                Task { await model.seek(toFrame: target, connection: connection) }
            }
            .accessibilityValue(model.frameCount > 0
                                ? Text("帧 \(shownIndex + 1) / \(model.frameCount)")
                                : Text("无内容"))

            HStack {
                Text(formatFrameTime(shownIndex))
                Spacer()
                Text(formatFrameTime(model.frameCount))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Frames as `mm:ss` at the requested speed.
    private func formatFrameTime(_ frames: Int) -> String {
        let totalSeconds = Int(Double(max(0, frames)) / max(1, model.requestedFps))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// The "面板实测" row: driven by board telemetry (and pll churn), not by the
/// requested-speed slider next to it.
private struct TextMeasuredFpsRow: View {
    var model: TextViewModel

    var body: some View {
        #if DEBUG
        let _ = PR9BodyProbe.hit("TextMeasuredFpsRow")
        #endif
        LabeledContent("面板实测") {
            Text(model.measuredFps.map { String(format: "%.1f fps", $0) } ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// The sync-status section's rows: phase, PLL lock state and the last upload
/// summary. `lockState` moves with pll churn same as the preview index.
private struct TextSyncDiagnosticsRows: View {
    var model: TextViewModel
    var connection: BoardConnection

    var body: some View {
        #if DEBUG
        let _ = PR9BodyProbe.hit("TextSyncDiagnosticsRows")
        #endif
        Group {
            LabeledContent("状态") {
                Text(TextViewModel.phaseLabel(model.phaseKey(connection: connection)))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("相位锁定") {
                Text(TextViewModel.lockStateLabel(model.lockState))
                    .foregroundStyle(.secondary)
            }
            if let summary = model.uploadSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
