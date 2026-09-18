import SwiftUI
import RinaCore

/// Play panel for one `BoardGroup` (BOARD_GROUP_SPEC.md §3): text, speed,
/// loop, play/stop, per-member status, and a stitched preview driven by one
/// shared clock.
struct BoardGroupPlayView: View {
    let groupID: UUID

    @Environment(BoardGroupStore.self) private var store
    @Environment(BoardGroupCoordinator.self) private var coordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var text = ""
    @State private var fps: Double = 10
    @State private var loop = true
    @State private var isSending = false
    @State private var errorMessage: String?

    /// The bitmap the preview draws from; rebuilt off the main actor and
    /// cached rather than every frame (BOARD_GROUP_SPEC.md §3).
    @State private var previewBitmap: ScrollBitmap?
    @State private var previewVirtualWidth: Int = MatrixGeometry.cols
    @State private var previewStartDate = Date()
    @State private var cachedFont: ArkPixelFont?

    private var group: BoardGroup? {
        store.groups.first { $0.id == groupID }
    }

    var body: some View {
        Group {
            if let group {
                content(for: group)
            } else {
                ContentUnavailableView("多板组已删除", systemImage: "square.stack.3d.up.slash")
            }
        }
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($errorMessage)
    }

    @ViewBuilder
    private func content(for group: BoardGroup) -> some View {
        List {
            Section("预览") {
                stitchedPreview(group: group)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .listRowInsets(EdgeInsets())
                    .padding()
            }

            Section("文字") {
                TextField("要滚动的文字", text: $text, axis: .vertical)
                    .lineLimit(1...3)
            }

            Section("速度") {
                LabeledContent("速度") {
                    Text("\(Int(fps)) fps")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $fps,
                    in: Double(RinaLinkConstants.scrollFpsMin)...Double(RinaLinkConstants.scrollFpsMax),
                    step: 1
                )
                .accessibilityLabel("速度")
                .accessibilityValue(Text("\(Int(fps)) fps"))
                Toggle("循环", isOn: $loop)
            }

            Section {
                if let reason = blockingReason(group) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ViewThatFits {
                    HStack {
                        playButton(group: group)
                        Spacer()
                        stopButton(group: group)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        playButton(group: group)
                        stopButton(group: group)
                    }
                }
            }

            Section("面板状态") {
                ForEach(group.members, id: \.physicalBoardID) { member in
                    let status = coordinator.status(for: member)
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(coordinator.session(for: member)?.connection.deviceName ?? member.displayName)
                            Text(BoardGroupStatusFormatting.text(status))
                                .font(.caption)
                                .foregroundStyle(BoardGroupStatusFormatting.color(status))
                        }
                    } else {
                        HStack {
                            Text(coordinator.session(for: member)?.connection.deviceName ?? member.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(BoardGroupStatusFormatting.text(status))
                                .font(.caption)
                                .foregroundStyle(BoardGroupStatusFormatting.color(status))
                        }
                    }
                }
            }
        }
        .rinaTranslucentRows()
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .task(id: previewKey(group)) {
            await rebuildPreview(group: group)
        }
    }

    @ViewBuilder
    private func playButton(group: BoardGroup) -> some View {
        Button {
            Task { await play(group: group) }
        } label: {
            if isSending {
                ProgressView()
            } else {
                Label("播放", systemImage: "play.fill")
            }
        }
        .disabled(!canPlay(group) || isSending)
    }

    @ViewBuilder
    private func stopButton(group: BoardGroup) -> some View {
        Button(role: .destructive) {
            Task { await coordinator.stop(group: group) }
        } label: {
            Label("停止", systemImage: "stop.fill")
        }
        .disabled(!coordinator.isPlaying || coordinator.activeGroupID != group.id)
    }

    // MARK: - Play gating

    /// Every member must be online and support board groups, and there must
    /// be at least two of them — a partial group never silently plays with
    /// gaps (BOARD_GROUP_SPEC.md §3).
    private func canPlay(_ group: BoardGroup) -> Bool {
        blockingReason(group) == nil
    }

    private func blockingReason(_ group: BoardGroup) -> String? {
        if group.members.count < BoardGroup.minMembersToPlay {
            return "多板组至少需要 2 块面板才能播放。"
        }
        let offline = group.members.filter { coordinator.status(for: $0) == .offline }
        if !offline.isEmpty {
            let names = offline.map { memberName($0) }.joined(separator: "、")
            return "以下面板离线，播放前请先连接：\(names)"
        }
        let unsupported = group.members.filter { coordinator.status(for: $0) == .unsupported }
        if !unsupported.isEmpty {
            let names = unsupported.map { memberName($0) }.joined(separator: "、")
            return "以下面板固件过旧，不支持多板组：\(names)"
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请先输入要滚动的文字。"
        }
        return nil
    }

    private func memberName(_ member: BoardGroup.Member) -> String {
        coordinator.session(for: member)?.connection.deviceName ?? member.displayName
    }

    // MARK: - Play / stop

    private func play(group: BoardGroup) async {
        isSending = true
        defer { isSending = false }
        do {
            try await coordinator.play(group: group, text: text, fps: Int(fps), loop: loop)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Preview

    /// A value that changes exactly when the preview needs rebuilding, so
    /// `.task(id:)` only reruns for the inputs that actually affect the
    /// bitmap.
    private func previewKey(_ group: BoardGroup) -> String {
        "\(text)|\(Int(fps))|\(group.mode.rawValue)|\(group.members.count)|\(group.gapsAfter)"
    }

    private func rebuildPreview(group: BoardGroup) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, group.members.count >= 1,
              let layout = try? StitchedScreenLayout(slotCount: group.members.count, gapsAfter: group.gapsAfter)
        else {
            previewBitmap = nil
            return
        }
        let mode = group.mode
        let virtualWidth = mode == .mirror ? MatrixGeometry.cols : layout.virtualWidth
        let font: ArkPixelFont
        if let cachedFont {
            font = cachedFont
        } else {
            guard let loaded = try? BoardGroupCoordinator.loadDefaultFont() else {
                previewBitmap = nil
                return
            }
            font = loaded
            cachedFont = loaded
        }
        let built = await Task.detached(priority: .utility) {
            try? GroupScrollBitmap.build(text: trimmed, font: font, virtualWidth: virtualWidth)
        }.value
        guard !Task.isCancelled else { return }
        previewBitmap = built
        previewVirtualWidth = virtualWidth
        previewStartDate = Date()
    }

    @ViewBuilder
    private func stitchedPreview(group: BoardGroup) -> some View {
        guard let bitmap = previewBitmap,
              let displayLayout = try? StitchedScreenLayout(slotCount: group.members.count, gapsAfter: group.gapsAfter)
        else {
            return AnyView(
                Text("输入文字后可预览拼接效果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
        }
        let intervalMs = ScrollRasterizer.intervalMs(forFps: Int(fps))
        let intervalSeconds = Double(intervalMs) / 1000
        let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: bitmap.width, virtualWidth: previewVirtualWidth)
        let mode = group.mode

        return AnyView(
            TimelineView(.animation(minimumInterval: intervalSeconds)) { context in
                let elapsed = context.date.timeIntervalSince(previewStartDate)
                let frameIndex = frameCount > 0 ? Int(elapsed / max(intervalSeconds, 0.001)) % frameCount : 0
                GeometryReader { geo in
                    let cellWidth = displayLayout.virtualWidth > 0 ? geo.size.width / CGFloat(displayLayout.virtualWidth) : 0
                    HStack(spacing: 0) {
                        ForEach(Array(group.members.enumerated()), id: \.element.physicalBoardID) { index, _ in
                            let viewportX = mode == .mirror ? 0 : displayLayout.viewportX(slot: index)
                            let frame = GroupScrollBitmap.frame(bitmap: bitmap, viewportX: viewportX, frameIndex: frameIndex)
                            LEDBoardPreview(
                                frame: frame,
                                color: .rinaPink,
                                brightness: 200,
                                showBoardImage: false,
                                bloom: false,
                                showsUnlitCells: true
                            )
                            .frame(width: cellWidth * CGFloat(MatrixGeometry.cols))
                            if index < group.members.count - 1 {
                                Spacer()
                                    .frame(width: cellWidth * CGFloat(group.gapsAfter[index]))
                            }
                        }
                    }
                }
            }
        )
    }
}

#Preview {
    let store = BoardGroupStore()
    let group = store.create(name: "客厅拼接屏")
    return NavigationStack {
        BoardGroupPlayView(groupID: group.id)
    }
    .environment(store)
    .environment(BoardGroupCoordinator(store: store, sessions: BoardSessionStore()))
}
