import SwiftUI
import RinaCore

/// Text tab (design guide §22–§29): scrolling-text authoring and playback.
///
/// The preview at the top is the app's reconstruction of the board's current
/// scroll animation and is **not** interactive (§22.1). It follows the board's
/// *measured* speed and corrects phase, rather than free-running at the
/// requested fps, so the phone and the physical board stay together (§28/§29).
struct ScrollTextView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(TextViewModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isEditorFocused: Bool

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        NavigationStack {
            List {
                previewSection
                playbackSection
                editorSection
                speedSection
                syncSection
            }
            .toolbar(.hidden, for: .navigationBar)
            .contentMargins(.top, 0, for: .scrollContent)
        }
        .onAppear { model.loadDefaultsIfNeeded() }
        .onChange(of: connection.preview) { _, preview in
            model.observe(preview: preview)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.resumePreviewLoopIfNeeded()
            } else {
                model.suspendPreviewLoop()
            }
        }
    }

    // MARK: §23 Preview

    private var previewSection: some View {
        Section {
            // `.inert` by default: the scroll preview mirrors the board's
            // own animation and is not editable (§22.1).
            BoardPreviewRow(
                frame: model.previewFrame,
                accessibilityDescription: previewAccessibilityDescription
            )
        } footer: {
            if model.frameCount > 0 {
                Text("帧 \(model.displayIndex + 1) / \(model.frameCount)")
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private var previewAccessibilityDescription: String {
        model.frameCount > 0
            ? String(format: NSLocalizedString("滚动文字预览，第 %1$lld 帧，共 %2$lld 帧",
                                               comment: "scroll preview accessibility summary"),
                     model.displayIndex + 1, model.frameCount)
            : NSLocalizedString("滚动文字预览，暂无内容", comment: "empty scroll preview")
    }

    // MARK: §24 Playback

    private var playbackSection: some View {
        Section("播放") {
            // Four transport buttons only (§24): with nothing bound on the
            // board the stop slot becomes "send and play".
            TextPlaybackControls(
                isConnected: isConnected,
                hasTimeline: model.boundTimelineId != nil,
                isPaused: connection.preview?.firmwareScrollPaused == true,
                isUploading: model.isUploading,
                isGeneratingFont: model.isGeneratingFont,
                canSend: !model.exceedsByteLimit,
                onSend: { Task { await model.send(connection: connection) } },
                onPlay: { Task { await model.resume(connection: connection) } },
                onPause: { Task { await model.pause(connection: connection) } },
                onStop: { Task { await model.stop(connection: connection) } },
                onStepBackward: { Task { await model.stepFrame(direction: -1, connection: connection) } },
                onStepForward: { Task { await model.stepFrame(direction: 1, connection: connection) } }
            )

            if model.isUploading {
                ProgressView(value: model.uploadProgress)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: §25 Text input, §26 restore conflict

    private var editorBorderColor: Color {
        if model.exceedsByteLimit { return .red }
        return isEditorFocused ? .accentColor : Color(.separator)
    }

    private var editorSection: some View {
        Section {
            if model.restoreConflict {
                VStack(alignment: .leading, spacing: 8) {
                    Label("面板上的文字与本地未发送的草稿不同。", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                    HStack {
                        Button("保留草稿") { model.keepDraft() }
                        Button("使用面板文字") { model.useBoardText() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // The editor is the primary input of this tab, so it reads as a
            // card on the row rather than as plain list text.
            TextEditor(text: Binding(
                get: { model.text },
                set: { model.editText($0) }
            ))
            .frame(minHeight: 132)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(editorBorderColor, lineWidth: isEditorFocused ? 2 : 1)
            )
            .overlay(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("输入要滚动的文字…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .focused($isEditorFocused)
            .animation(.easeInOut(duration: 0.15), value: isEditorFocused)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityLabel("滚动文字内容")

            LabeledContent("字符") {
                Text("\(model.visibleCharCount) / \(ScrollText.maxVisibleChars)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("字节") {
                Text("\(model.byteCount) / \(ScrollText.maxTextBytes)")
                    .monospacedDigit()
                    .foregroundStyle(model.exceedsByteLimit ? .red : .secondary)
            }
        } header: {
            Text("文字")
        } footer: {
            if model.exceedsByteLimit {
                Text("超出固件 \(ScrollText.maxTextBytes) 字节上限，发送前请缩短文字；不会自动截断。")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: §27 Speed

    private var speedSection: some View {
        Section("速度") {
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
            LabeledContent("面板实测") {
                Text(String(format: "%.1f fps", model.measuredFps))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: §29 Sync status

    private var syncSection: some View {
        Section("同步状态") {
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
