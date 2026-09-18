import SwiftUI
import RinaCore

/// Multi-board scroll preview for a targeted `BoardGroup` (BOARD_GROUP_SPEC.md
/// §3): every member is drawn side by side with a visible gap and a label
/// (number + name + status) underneath, and can be reordered by long-press
/// dragging one board onto another. Used by both the Text tab (draft, not yet
/// playing) and `BoardGroupPlayView` (live playback snapshot).
struct GroupScrollPreview: View {
    let group: BoardGroup
    let draftText: String
    let draftFps: Int
    var color: Color = .rinaPink
    var brightness: Int = 200
    let onSwap: (Int, Int) -> Void

    @Environment(BoardGroupCoordinator.self) private var coordinator

    /// Rebuilt off the main actor and cached rather than every frame, same
    /// approach as `BoardGroupPlayView`'s previous `rebuildPreview`.
    @State private var draftBitmap: ScrollBitmap?
    @State private var draftVirtualWidth: Int = MatrixGeometry.cols
    @State private var draftStartDate = Date()
    @State private var cachedFont: ArkPixelFont?
    @State private var draggingIndex: Int?
    @State private var targetedIndex: Int?

    private static let minGap: CGFloat = 8
    private static let minCellSide: CGFloat = 70

    private var displayLayout: StitchedScreenLayout? {
        try? StitchedScreenLayout(slotCount: group.members.count, gapsAfter: group.gapsAfter)
    }

    var body: some View {
        Group {
            if let snapshot = coordinator.playbackSnapshot, snapshot.groupID == group.id {
                livePreview(snapshot: snapshot)
            } else {
                draftPreview()
            }
        }
        .task(id: draftPreviewKey) {
            await rebuildDraftBitmap()
        }
    }

    // MARK: - Live (playing/paused) preview

    @ViewBuilder
    private func livePreview(snapshot: BoardGroupCoordinator.PlaybackSnapshot) -> some View {
        TimelineView(.animation) { _ in
            let frameIndex = coordinator.currentFrame().map { snapshot.frameCount > 0 ? $0 % max(snapshot.frameCount, 1) : 0 } ?? 0
            boardRow(members: snapshot.memberOrder) { index in
                GroupScrollBitmap.frame(bitmap: snapshot.bitmap, viewportX: snapshot.viewportXs[index], frameIndex: frameIndex)
            }
        }
    }

    // MARK: - Draft (not yet playing) preview

    private var draftPreviewKey: String {
        "\(draftText)|\(group.mode.rawValue)|\(group.members.count)|\(group.gapsAfter)"
    }

    @ViewBuilder
    private func draftPreview() -> some View {
        if let bitmap = draftBitmap, let layout = displayLayout {
            let intervalMs = ScrollRasterizer.intervalMs(forFps: max(draftFps, 1))
            let intervalSeconds = Double(intervalMs) / 1000
            let frameCount = GroupScrollBitmap.frameCount(bitmapWidth: bitmap.width, virtualWidth: draftVirtualWidth)
            let mode = group.mode
            TimelineView(.animation(minimumInterval: intervalSeconds)) { context in
                let elapsed = context.date.timeIntervalSince(draftStartDate)
                let frameIndex = frameCount > 0 ? Int(elapsed / max(intervalSeconds, 0.001)) % frameCount : 0
                boardRow(members: group.members) { index in
                    let viewportX = mode == .mirror ? 0 : layout.viewportX(slot: index)
                    return GroupScrollBitmap.frame(bitmap: bitmap, viewportX: viewportX, frameIndex: frameIndex)
                }
            }
        } else {
            Text("输入文字后可预览拼接效果")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rebuildDraftBitmap() async {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, group.members.count >= 1, let layout = displayLayout else {
            draftBitmap = nil
            return
        }
        let mode = group.mode
        let virtualWidth = mode == .mirror ? MatrixGeometry.cols : layout.virtualWidth
        let font: ArkPixelFont
        if let cachedFont {
            font = cachedFont
        } else {
            guard let loaded = try? BoardGroupCoordinator.loadDefaultFont() else {
                draftBitmap = nil
                return
            }
            font = loaded
            cachedFont = loaded
        }
        let built = await Task.detached(priority: .utility) {
            try? GroupScrollBitmap.build(text: trimmed, font: font, virtualWidth: virtualWidth)
        }.value
        guard !Task.isCancelled else { return }
        draftBitmap = built
        draftVirtualWidth = virtualWidth
        draftStartDate = Date()
    }

    // MARK: - Shared row layout

    @ViewBuilder
    private func boardRow(members: [BoardGroup.Member], frame: @escaping (Int) -> PackedFrame) -> some View {
        let count = members.count
        GeometryReader { geo in
            let gapCount = max(count - 1, 0)
            let cellSide = gapCount > 0
                ? (geo.size.width - Self.minGap * CGFloat(gapCount)) / CGFloat(count)
                : geo.size.width
            if cellSide >= Self.minCellSide || count <= 1 {
                HStack(spacing: 0) {
                    boardCells(members: members, cellWidth: cellSide, frame: frame)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        boardCells(members: members, cellWidth: Self.minCellSide, frame: frame)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func boardCells(members: [BoardGroup.Member], cellWidth: CGFloat, frame: @escaping (Int) -> PackedFrame) -> some View {
        ForEach(Array(members.enumerated()), id: \.element.physicalBoardID) { index, member in
            boardCell(member: member, index: index, cellWidth: cellWidth, frame: frame(index))
            if index < members.count - 1 {
                let gapCells = index < group.gapsAfter.count ? group.gapsAfter[index] : 0
                Spacer()
                    .frame(width: max(Self.minGap, cellWidth * CGFloat(gapCells) / CGFloat(MatrixGeometry.cols)))
            }
        }
    }

    @ViewBuilder
    private func boardCell(member: BoardGroup.Member, index: Int, cellWidth: CGFloat, frame: PackedFrame) -> some View {
        let status = coordinator.status(for: member)
        let name = coordinator.session(for: member)?.connection.deviceName ?? member.displayName
        let isTargeted = targetedIndex == index
        VStack(spacing: 4) {
            LEDBoardPreview(
                frame: frame,
                color: color,
                brightness: brightness,
                showBoardImage: false,
                bloom: false,
                showsUnlitCells: true
            )
            .frame(width: cellWidth)
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            HStack(spacing: 4) {
                Text("\(index + 1)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.2)))
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            Text(BoardGroupStatusFormatting.text(status))
                .font(.caption2)
                .foregroundStyle(BoardGroupStatusFormatting.color(status))
        }
        .frame(width: cellWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("板 \(index + 1)，\(name)，\(BoardGroupStatusFormatting.text(status))")
        .opacity(draggingIndex == index ? 0.5 : 1)
        .disabled(coordinator.isStarting)
        .draggable(String(index)) {
            Text("\(index + 1)")
                .font(.caption)
                .padding(6)
                .background(Capsule().fill(.thinMaterial))
                .onAppear { draggingIndex = index }
        }
        .dropDestination(for: String.self) { items, _ in
            defer {
                draggingIndex = nil
                targetedIndex = nil
            }
            guard let raw = items.first, let sourceIndex = Int(raw), sourceIndex != index else { return false }
            onSwap(sourceIndex, index)
            return true
        } isTargeted: { targeted in
            targetedIndex = targeted ? index : (targetedIndex == index ? nil : targetedIndex)
        }
    }
}
