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
    @Environment(BoardGroupStore.self) private var groupStore
    @Environment(BoardGroupCoordinator.self) private var groupCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isEditorFocused: Bool
    @Environment(\.displayScale) private var displayScale
    /// Ark Pixel editor size; follows Dynamic Type, snapped to crisp steps.
    @ScaledMetric(relativeTo: .body) private var editorFontSize: CGFloat = 16
    private static let editorMinHeight: CGFloat = 132

    /// Mirrors the Control Center's "控制对象" choice (BOARD_GROUP_SPEC.md
    /// §3): empty string = `.single`. When a group is targeted, transport,
    /// speed and the sync diagnostics act on / report the whole group; the
    /// preview stays single-board.
    @AppStorage(ControlTargetKey.groupID) private var controlTargetGroupIDStorage = ""

    /// Debounces rapid speed-slider drags (250 ms trailing) while a group is
    /// targeted, so `BoardGroupCoordinator.updatePlayback` isn't called on
    /// every slider tick (BOARD_GROUP_SPEC.md §3). Single-board speed
    /// changes are unaffected — those already debounce inside
    /// `TextViewModel`'s own `fpsSender`.
    @State private var groupPlaybackUpdateTask: Task<Void, Never>?

    /// C1: the fps slider's own in-progress value while a drag (or a
    /// keyboard/VoiceOver adjust) is live, so the label/track never jump
    /// mid-gesture to whatever `displayedFps` happens to read from a
    /// still-in-flight commit. `nil` once nothing is pending.
    @State private var fpsDraft: Double?
    /// `true` between a slider drag's `onEditingChanged(true)` and its
    /// matching `(false)` — a keyboard/VoiceOver adjust never sets this, so
    /// each of its `set` calls schedules its own commit immediately.
    @State private var fpsEditing = false
    /// The pending "commit the fps slider's current value" task scheduled by
    /// `scheduleFpsCommit()` — cancelled and replaced on every new value
    /// while not mid-drag, so only the last one in a burst actually commits.
    @State private var fpsCommitTask: Task<Void, Never>?

    private var isConnected: Bool { connection.connectionState == .connected }

    private var targetedGroup: BoardGroup? {
        guard case .group(let id) = ControlTarget.resolved(storedGroupIDString: controlTargetGroupIDStorage, in: groupStore)
        else { return nil }
        return groupStore.groups.first { $0.id == id }
    }

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
        .onChange(of: groupStore.groups) { _, _ in
            // A group deleted out from under the current target must not
            // keep this tab pointed at a dead id (BOARD_GROUP_SPEC.md §3).
            ControlTarget.validate(&controlTargetGroupIDStorage, in: groupStore)
        }
    }

    // MARK: §23 Preview

    @ViewBuilder
    private var previewBoard: some View {
        if let group = targetedGroup {
            GroupScrollPreview(
                group: group,
                onSwap: { boardA, boardB in
                        Task {
                            do {
                                try await groupCoordinator.swapMembers(group: group, boardA, boardB)
                            } catch {
                                model.errorMessage = String(localized: "调整顺序失败：\(error.localizedDescription)")
                            }
                        }
                    }
            )
        } else {
            // `.inert` by default: the scroll preview mirrors the board's
            // own animation and is not editable (§22.1).
            TextPreviewBoard(model: model)
        }
    }

    private var previewStatus: some View {
        TextPreviewStatusFooter(
            model: model,
            connection: connection,
            groupPhase: groupPhase,
            groupFrame: pausedGroupSnapshot.flatMap { _ in groupCoordinator.currentFrame() },
            groupFrameCount: pausedGroupSnapshot?.frameCount
        )
    }

    /// The footer's frame counter is not clock-driven, so it only shows the
    /// group's position while that is a fixed frame: the targeted group, paused.
    private var pausedGroupSnapshot: BoardGroupCoordinator.PlaybackSnapshot? {
        guard let group = targetedGroup, groupCoordinator.isPaused,
              let snapshot = groupCoordinator.playbackSnapshot, snapshot.groupID == group.id else { return nil }
        return snapshot
    }

    /// What the targeted group is doing, for the status line under the
    /// preview; `nil` with a single-board target or an idle group.
    private var groupPhase: TextPreviewStatusFooter.GroupPhase? {
        guard let group = targetedGroup else { return nil }
        if groupCoordinator.activeGroupID == group.id {
            if groupCoordinator.isPlaying { return .playing }
            if groupCoordinator.isPaused { return .paused }
        }
        let starting = groupCoordinator.isStarting && groupCoordinator.startingGroupID == group.id
        return !starting && groupCoordinator.hasOrphanedScroll(group: group) ? .adopting : nil
    }

    // MARK: §24 Playback

    /// Two sections: the pill row clears its cell background, so sharing a
    /// section with ordinary rows left it sitting on top of a broken card.
    @ViewBuilder
    private var playbackSection: some View {
        if let group = targetedGroup {
            groupPlaybackSection(group)
        } else {
            singleBoardPlaybackSection
        }
    }

    /// App-level group pause/resume/step (`BoardGroupCoordinator.pause`/
    /// `resume`/`step` — no firmware timed-pause support, so this replays
    /// `pause_scroll`/`scroll_seek` to every member instead): the group
    /// target reuses the single-board pill row with pause/play/step live,
    /// same look and layout as the single-board case. The single-board
    /// progress bar is board-specific and stays hidden; the send pill's own
    /// spinner (`isUploading: starting`) is the only loading indicator —
    /// no extra row.
    private func groupPlaybackSection(_ group: BoardGroup) -> some View {
        let playing = groupCoordinator.isPlaying && groupCoordinator.activeGroupID == group.id
        let paused = groupCoordinator.isPaused && groupCoordinator.activeGroupID == group.id
        let allOnline = !group.members.isEmpty
            && group.members.allSatisfy { groupCoordinator.status(for: $0) != .offline }
        let starting = groupCoordinator.isStarting && groupCoordinator.startingGroupID == group.id
        // Boards still scrolling a group the app lost track of (relaunch,
        // reconnect): keep the transport live. Stop works as is; the other
        // controls take the scroll over first (`adoptRunningScroll`).
        let orphaned = !playing && !paused && !starting && groupCoordinator.hasOrphanedScroll(group: group)
        // Drives the adoption `.task(id:)` below. Deliberately omits
        // `!starting`: `adoptRunningScrollIfNeeded` itself flips `isStarting`
        // while it runs, so an id that included it would cancel and restart
        // the task on every attempt (the task would never live long enough
        // to finish, and `model.adoptGroupFps` would never run).
        let needsAdoption = !playing && !paused && groupCoordinator.hasOrphanedScroll(group: group)
        return Section {
            TextPlaybackControls(
                isConnected: allOnline,
                hasTimeline: playing || paused,
                boardHasScroll: orphaned,
                isPaused: paused,
                isUploading: starting,
                uploadProgress: starting ? groupCoordinator.uploadProgress(for: group) : nil,
                isGeneratingFont: false,
                canSend: !model.exceedsByteLimit && !model.text.isEmpty,
                loopPlayback: Binding(
                    get: { model.loopPlayback },
                    set: { loop in
                        model.loopPlayback = loop
                        if playing || paused { scheduleGroupPlaybackUpdate(group: group) }
                    }
                ),
                loopDisabled: false,
                onSend: { Task { await sendOrPlayGroup() } },
                onPlay: { Task { if await adoptIfOrphaned(group) { await groupCoordinator.resume(group: group) } } },
                onPause: { Task { if await adoptIfOrphaned(group) { await groupCoordinator.pause(group: group) } } },
                onStop: { Task { await stopOrStopGroup() } },
                onStepBackward: { Task { if await adoptIfOrphaned(group) { await groupCoordinator.step(group: group, direction: -1) } } },
                onStepForward: { Task { if await adoptIfOrphaned(group) { await groupCoordinator.step(group: group, direction: 1) } } },
                canStop: starting || playing || paused || orphaned
            )
        }
        // Take a still-running group scroll back as soon as every member is
        // online again, so pause/step/speed work without a tap first.
        .task(id: "\(group.id)|\(allOnline)|\(needsAdoption)") {
            if allOnline && needsAdoption { _ = await adoptIfOrphaned(group) }
        }
    }

    /// Makes sure the coordinator drives `group` before a transport action:
    /// adopts a still-running scroll if needed. `false` if nothing is
    /// playing or paused afterwards (the action would be a no-op).
    private func adoptIfOrphaned(_ group: BoardGroup) async -> Bool {
        let driving = groupCoordinator.activeGroupID == group.id
            && (groupCoordinator.isPlaying || groupCoordinator.isPaused)
        if driving { return true }
        guard await groupCoordinator.adoptRunningScrollIfNeeded(group: group) else { return false }
        // The speed follows the boards, as on a single-board reconnect.
        if let fps = groupCoordinator.activeFps { model.adoptGroupFps(fps) }
        return true
    }

    /// Item 2 (BOARD_GROUP_SPEC.md §3 addendum): applies a speed/loop change
    /// live to a playing group via `BoardGroupCoordinator.updatePlayback`,
    /// debounced `delayNanoseconds` (default 250 ms — the loop toggle) so a
    /// rapid burst doesn't fire one re-anchor per tick. The fps slider (C1)
    /// commits its own value only once, on release/settle
    /// (`scheduleFpsCommit`), so it calls this with `delayNanoseconds: 0` —
    /// an extra 250 ms on top of the slider's own debounce would just be
    /// felt as lag. Single-board speed changes never go through here.
    /// Always sends the complete desired state (fps + loop), not just the
    /// field that changed — otherwise a speed change followed by a loop
    /// toggle within the debounce window cancels the pending speed change.
    private func scheduleGroupPlaybackUpdate(group: BoardGroup, delayNanoseconds: UInt64 = 250_000_000) {
        groupPlaybackUpdateTask?.cancel()
        let sendFps = min(Int(model.requestedFps), groupCoordinator.maxFps(for: group))
        let sendLoop = model.loopPlayback
        groupPlaybackUpdateTask = Task {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await groupCoordinator.updatePlayback(group: group, fps: sendFps, loop: sendLoop)
        }
    }

    @ViewBuilder
    private var singleBoardPlaybackSection: some View {
        Section {
            // Transport pills plus the loop toggle (§24): with nothing bound
            // on the board the stop slot becomes "send and play".
            TextPlaybackControls(
                isConnected: isConnected,
                hasTimeline: model.boundTimelineId != nil,
                boardHasScroll: model.boardHasScroll(connection: connection),
                isPaused: model.boardPaused,
                isUploading: model.isUploading,
                uploadProgress: model.isUploading ? model.uploadProgress : nil,
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
                onSend: { Task { await sendOrPlayGroup() } },
                onPlay: { Task { await model.resume(connection: connection) } },
                onPause: { Task { await model.pause(connection: connection) } },
                onStop: { Task { await stopOrStopGroup() } },
                onStepBackward: { Task { await model.stepFrame(direction: -1, connection: connection) } },
                onStepForward: { Task { await model.stepFrame(direction: 1, connection: connection) } }
            )
        }

        Section {
            // Always present, like the Preset Live tab; greyed out until a
            // timeline is on the board. The send pill (`TextPlaybackControls`)
            // already shows its own uploading spinner — no separate progress
            // row here.
            TextPlaybackProgressBar(model: model, connection: connection, isConnected: isConnected)
        }
    }

    /// Firmware without `set_scroll_loop` reports scroll state but no
    /// `scrollLoop`; there the toggle could only ever produce a rejection.
    private var loopUnsupported: Bool {
        guard let renderer = connection.status?.renderer else { return false }
        return renderer.scrollFrameCount != nil && renderer.scrollLoop == nil
    }

    // MARK: Board group target (BOARD_GROUP_SPEC.md §3)

    /// Send: plays to the targeted group when one is set, otherwise the
    /// single-board `model.send(connection:)` — byte-for-byte unchanged in
    /// that case.
    private func sendOrPlayGroup() async {
        guard let group = targetedGroup else {
            await model.send(connection: connection)
            return
        }
        do {
            try await groupCoordinator.play(
                group: group,
                text: model.text,
                fps: min(Int(model.requestedFps), groupCoordinator.maxFps(for: group)),
                loop: model.loopPlayback
            )
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    /// Stop: stops the targeted group when one is set, otherwise the
    /// single-board `model.stop(connection:)`.
    private func stopOrStopGroup() async {
        guard let group = targetedGroup else {
            await model.stop(connection: connection)
            return
        }
        groupPlaybackUpdateTask?.cancel()
        groupPlaybackUpdateTask = nil
        await groupCoordinator.stop(group: group)
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
            ZStack(alignment: .topLeading) {
                // Invisible copy of the text sizes the editor: it grows with
                // the text block from the base height up to twice that, then
                // the editor scrolls inside. Padding mirrors UITextView's
                // text container insets (5 pt line padding, 8 pt top/bottom).
                Text(model.text.hasSuffix("\n") || model.text.isEmpty ? model.text + " " : model.text)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Self.editorMinHeight,
                        maxHeight: Self.editorMinHeight * 2,
                        alignment: .topLeading
                    )
                    .hidden()
                    .accessibilityHidden(true)
                TextEditor(text: Binding(
                    get: { model.text },
                    set: { model.editText($0) }
                ))
                .scrollContentBackground(.hidden)
                .accessibilityLabel("滚动文字内容")
            }
            // Same Ark Pixel font the WebUI uses for this field and the
            // frame generator rasterizes, so the draft previews its glyphs.
            .font(ArkPixelInputFont.font(size: editorFontSize, displayScale: displayScale))
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
        } footer: {
            if model.exceedsByteLimit {
                Text("超出固件 \(ScrollText.maxTextBytes) 字节上限，发送前请缩短文字；不会自动截断。")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: §27 Speed

    /// Group playback can't exceed its members' `group_start` floor — 60 fps
    /// (17 ms) if every connected member advertises `group_60fps`, else the
    /// legacy 50 fps (20 ms) — so a faster rate adopted from a single board
    /// shows as the rate the group will actually send.
    private var displayedFps: Double {
        if let group = targetedGroup {
            return min(model.requestedFps, Double(groupCoordinator.maxFps(for: group)))
        }
        return model.requestedFps
    }

    /// C1: the value the fps label/slider/accessibility all show — the
    /// in-progress drag/adjust value while one is pending, else the
    /// steady-state `displayedFps`.
    private var shownFps: Double { fpsDraft ?? displayedFps }

    private var speedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("请求速度") {
                    Text(String(format: "%.0f fps", shownFps))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { shownFps },
                        set: { newValue in
                            fpsDraft = newValue
                            // A keyboard/VoiceOver adjust never brackets its
                            // `set` calls with `onEditingChanged`, so this is
                            // the only place it gets a commit scheduled; a
                            // drag's own commit is scheduled from
                            // `onEditingChanged(false)` below instead, so a
                            // mid-drag `set` here must not schedule one.
                            if !fpsEditing {
                                scheduleFpsCommit()
                            }
                        }
                    ),
                    in: Double(RinaLinkConstants.scrollFpsMin)...(
                        targetedGroup.map { Double(groupCoordinator.maxFps(for: $0)) }
                            ?? Double(RinaLinkConstants.scrollFpsMax)
                    ),
                    step: 1,
                    onEditingChanged: { editing in
                        fpsEditing = editing
                        if editing {
                            fpsCommitTask?.cancel()
                        } else {
                            scheduleFpsCommit()
                        }
                    }
                )
                .disabled(targetedGroup == nil && !isConnected)
                .accessibilityLabel("请求速度")
                .accessibilityValue(Text(String(format: "%.0f fps", shownFps)))
            }

            // Single-board rate uses presentation samples. Group rows show
            // the interval reported by each board, labeled as configuration.
            if let group = targetedGroup {
                GroupMeasuredFpsRow(group: group)
            } else {
                TextMeasuredFpsRow(model: model)
            }
        }
        .onChange(of: connection.connectionGeneration) { _, _ in
            fpsCommitTask?.cancel()
            fpsCommitTask = nil
            fpsDraft = nil
            fpsEditing = false
        }
        .onChange(of: targetedGroup?.id) { _, _ in
            // The commit target (group vs. single board, or which group)
            // just changed — a pending draft would otherwise commit against
            // the wrong target a moment later.
            fpsCommitTask?.cancel()
            fpsCommitTask = nil
            fpsDraft = nil
            fpsEditing = false
        }
        .onDisappear {
            fpsCommitTask?.cancel()
            fpsCommitTask = nil
            fpsDraft = nil
            fpsEditing = false
        }
    }

    /// C1: commits `fpsDraft` (if any) 100 ms after the slider last moved —
    /// on release (`onEditingChanged(false)`) this fires once for the final
    /// value instead of once per drag tick, and a keyboard/VoiceOver adjust
    /// (no drag) still settles quickly. Runs exactly the commit logic the
    /// slider's `Binding` used to run inline: group mode never touches the
    /// primary connection's own scroll timing directly (that would drop it
    /// out of group-timed playback) — only `updatePlayback` may retune a
    /// live/paused group, forwarded here with no extra debounce
    /// (`delayNanoseconds: 0`) since this commit is already the debounced,
    /// settled value.
    private func scheduleFpsCommit() {
        fpsCommitTask?.cancel()
        fpsCommitTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, !fpsEditing, let value = fpsDraft else { return }
            fpsDraft = nil
            if let group = targetedGroup {
                model.requestedFps = value
                // N3: forward while paused too — B2 has `updatePlayback`
                // just remember the new fps on the anchor (no live send) so
                // `resume()` picks it up, rather than silently dropping a
                // speed change made while paused.
                let active = groupCoordinator.activeGroupID == group.id
                    && (groupCoordinator.isPlaying || groupCoordinator.isPaused)
                if active {
                    scheduleGroupPlaybackUpdate(group: group, delayNanoseconds: 0)
                }
            } else {
                model.setRequestedFps(value, connection: connection)
            }
        }
    }

    // MARK: §29 Sync status

    private var syncSection: some View {
        Section("同步状态") {
            if let group = targetedGroup {
                GroupSyncDiagnosticsRows(group: group)
            } else {
                TextSyncDiagnosticsRows(model: model, connection: connection)
            }
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
    /// A targeted group's playback state; it replaces the single-board phase.
    enum GroupPhase {
        case playing, paused
        /// The boards still scroll a group the app lost track of.
        case adopting
    }

    var model: TextViewModel
    var connection: BoardConnection
    var groupPhase: GroupPhase? = nil
    /// The coordinator's own playback position/frame count while a group is
    /// targeted — the physical boards' real state, not this page's
    /// (unbound) `model.frameCount`/`displayIndex`.
    var groupFrame: Int? = nil
    var groupFrameCount: Int? = nil

    private var isConnected: Bool { connection.connectionState == .connected }

    /// `nil` unless the coordinator actually has a frame/count to show.
    private var groupFrameCounter: Text? {
        guard let groupFrameCount, groupFrameCount > 0, let groupFrame else { return nil }
        return Text("帧 \(groupFrame + 1) / \(groupFrameCount)")
    }

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
        if let groupPhase {
            let counter = groupFrameCounter ?? frameCounter
            switch groupPhase {
            case .playing:
                BoardPreviewStatus("多板组播放中", systemImage: "play.circle", tone: .live) {
                    counter
                }
            case .paused:
                BoardPreviewStatus("多板组已暂停", systemImage: "pause.circle", tone: .neutral) {
                    counter
                }
            case .adopting:
                BoardPreviewStatus("正在接管上次的多板滚动", systemImage: "arrow.triangle.2.circlepath.circle", tone: .pending) {
                    counter
                }
            }
        } else if model.restoreConflict {
            BoardPreviewStatus("草稿与面板不同", systemImage: "exclamationmark.circle", tone: .pending) {
                frameCounter
            }
        } else if isConnected, let source = connection.output.source, source != .text, source != .group {
            // Some other feature owns board output right now: show the
            // board's real mode instead of this tab's own idle phase.
            BoardOwnerStatus(source: source)
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

// MARK: - Board group target rows (BOARD_GROUP_SPEC.md §3)

/// The group's live scroll state, read from every member's own board
/// telemetry — `TextViewModel`'s PLL only ever follows a single-board
/// timeline, so it has nothing to report for a group scroll.
private struct GroupScrollTelemetry {
    /// Member count and how many are online / in step with the group.
    var memberCount = 0
    var inSyncCount = 0
    var failedCount = 0
    /// Configured rates reported by the members, one per member
    /// that reports an active scroll.
    var boardFps: [Int] = []

    @MainActor
    init(group: BoardGroup, coordinator: BoardGroupCoordinator, active: Bool, paused: Bool) {
        memberCount = group.members.count
        guard active else { return }
        for member in group.members {
            switch coordinator.status(for: member) {
            // A paused group sits every participant on the same frame
            // (`pauseCore` marks them `.ready`).
            case .playing: if !paused { inSyncCount += 1 }
            case .ready: if paused { inSyncCount += 1 }
            case .error: failedCount += 1
            default: break
            }
            guard let connection = coordinator.session(for: member)?.connection,
                  connection.connectionState == .connected else { continue }
            let renderer = connection.status?.renderer
            let preview = connection.preview
            guard (renderer?.firmwareScrollActive ?? preview?.firmwareScrollActive) == true,
                  let fps = TextViewModel.boardFps(
                    intervalMs: renderer?.scrollIntervalMs ?? preview?.scrollIntervalMs,
                    uiFps: renderer?.uiFps ?? preview?.uiFps
                  )
            else { continue }
            boardFps.append(fps)
        }
    }
}

private extension BoardGroupCoordinator {
    func groupIsActive(_ group: BoardGroup) -> Bool {
        activeGroupID == group.id && (isPlaying || isPaused)
    }

    func groupIsPaused(_ group: BoardGroup) -> Bool {
        activeGroupID == group.id && isPaused
    }

    func groupIsStarting(_ group: BoardGroup) -> Bool {
        isStarting && startingGroupID == group.id
    }
}

/// Configured group rate reported by member boards, or
/// a range when they disagree (a member that missed the last speed change).
private struct GroupMeasuredFpsRow: View {
    var group: BoardGroup
    @Environment(BoardGroupCoordinator.self) private var coordinator

    var body: some View {
        let telemetry = GroupScrollTelemetry(
            group: group, coordinator: coordinator,
            active: coordinator.groupIsActive(group), paused: coordinator.groupIsPaused(group)
        )
        LabeledContent("面板配置帧率") {
            Text(label(telemetry.boardFps))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ rates: [Int]) -> String {
        guard let low = rates.min(), let high = rates.max() else { return "—" }
        return low == high ? "\(low) fps" : "\(low)–\(high) fps"
    }
}

/// The sync-status rows for a group: the group's own play phase, and how many
/// members acknowledged the latest start/pause commands. These ACKs do not
/// measure physical presentation phase.
private struct GroupSyncDiagnosticsRows: View {
    var group: BoardGroup
    @Environment(BoardGroupCoordinator.self) private var coordinator

    var body: some View {
        let active = coordinator.groupIsActive(group)
        let paused = coordinator.groupIsPaused(group)
        let telemetry = GroupScrollTelemetry(group: group, coordinator: coordinator, active: active, paused: paused)
        Group {
            LabeledContent("状态") {
                Text(TextViewModel.phaseLabel(phaseKey(active: active, paused: paused)))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("播放指令确认") {
                Text(lockLabel(telemetry, active: active))
                    .monospacedDigit()
                    .foregroundStyle(telemetry.failedCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
    }

    private func phaseKey(active: Bool, paused: Bool) -> String {
        if coordinator.groupIsStarting(group) { return "STARTING" }
        guard active else { return "IDLE" }
        return paused ? "PAUSED" : "ACTIVE"
    }

    private func lockLabel(_ telemetry: GroupScrollTelemetry, active: Bool) -> String {
        guard active, telemetry.memberCount > 0 else {
            return TextViewModel.lockStateLabel(.free)
        }
        if telemetry.inSyncCount == telemetry.memberCount {
            return NSLocalizedString("全部已确认", comment: "all group playback commands acknowledged")
        }
        return String(
            format: NSLocalizedString("%1$lld / %2$lld 块已确认", comment: "group boards acknowledging playback commands"),
            telemetry.inSyncCount, telemetry.memberCount
        )
    }
}
