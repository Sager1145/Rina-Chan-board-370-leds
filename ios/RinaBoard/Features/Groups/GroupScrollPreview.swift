import SwiftUI
import UniformTypeIdentifiers
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
    /// `nil` follows the Control Center draft, like `BoardPreviewRow`.
    var color: Color? = nil
    var brightness: Int? = nil
    /// Called with the dragged board's and the drop target's
    /// `physicalBoardID`.
    let onSwap: (String, String) -> Void

    @Environment(BoardGroupCoordinator.self) private var coordinator
    /// Optional for the same reason as in `BoardPreviewRow`: test hosts and
    /// previews don't inject it.
    @Environment(BoardControlCenterModel.self) private var controlCenter: BoardControlCenterModel?
    /// Same reasoning: optional so test hosts and `#Preview`s that don't
    /// inject `AppRouter` don't crash. While its gate is pending (user
    /// requirement: "刚打开app同步时，完成同步再显示预览画面，不要让预览画面闪一下"), this preview
    /// holds every cell blank instead of drawing the draft's stitched
    /// animation or its "输入文字后可预览拼接效果" caption.
    @Environment(AppRouter.self) private var router: AppRouter?
    /// Same setting as the single-board preview's board photo.
    @AppStorage(AppSettingsKey.showBoardPhoto) private var showBoardPhoto = true

    private var resolvedColor: Color {
        color ?? controlCenter?.draftColor ?? .rinaPink
    }

    private var resolvedBrightness: Int {
        brightness ?? controlCenter.map(\.draftBrightness) ?? RinaLinkConstants.brightnessDefault
    }

    /// Rebuilt off the main actor and cached rather than every frame, same
    /// approach as `BoardGroupPlayView`'s previous `rebuildPreview`.
    @State private var draftBitmap: ScrollBitmap?
    @State private var draftVirtualWidth: Int = MatrixGeometry.cols
    @State private var draftStartDate = Date()
    @State private var cachedFont: ArkPixelFont?
    @State private var targetedIndex: Int?

    private static let minCellSide: CGFloat = 70
    /// App-private drag type: a board can't be dropped into a text field as
    /// text, and outside text can't trigger a swap.
    private static let boardDragType = UTType(exportedAs: "com.rinaboard.group-member", conformingTo: .data)

    private var displayLayout: StitchedScreenLayout? {
        try? StitchedScreenLayout(slotCount: group.members.count, gapsAfter: group.gapsAfter)
    }

    var body: some View {
        Group {
            if router?.launchPreviewPending == true {
                boardRow(members: group.members) { _ in PackedFrame() }
            } else if let snapshot = coordinator.playbackSnapshot, snapshot.groupID == group.id {
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
        let row = { (frameIndex: Int) in
            boardRow(members: snapshot.memberOrder) { index in
                GroupScrollBitmap.frame(bitmap: snapshot.bitmap, viewportX: snapshot.viewportXs[index], frameIndex: frameIndex)
            }
        }
        if coordinator.isPaused {
            // A still frame; step() changes pausedFrame, which re-renders.
            row(coordinator.currentFrame() ?? 0)
        } else {
            TimelineView(.animation(minimumInterval: Double(max(snapshot.intervalMs, 1)) / 1000)) { _ in
                row(coordinator.currentFrame() ?? 0)
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
        let usePhoto = LEDBoardPreview.drawsPhoto(showBoardImage: showBoardPhoto)
        let layout = BoardRowLayout(
            gapColumns: group.gapsAfter,
            columnFraction: LEDBoardLayout.columnWidthFraction(usePhoto: usePhoto),
            matrixInsetsFraction: LEDBoardLayout.matrixSideInsetsFraction(usePhoto: usePhoto),
            minBoardWidth: Self.minCellSide
        )
        // Fit every board across the width; once they'd shrink below
        // `minCellSide`, keep that size and scroll sideways instead.
        ViewThatFits(in: .horizontal) {
            layout { boardCells(members: members, frame: frame) }
                .frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                layout { boardCells(members: members, frame: frame) }
            }
        }
    }

    @ViewBuilder
    private func boardCells(members: [BoardGroup.Member], frame: @escaping (Int) -> PackedFrame) -> some View {
        ForEach(Array(members.enumerated()), id: \.element.physicalBoardID) { index, member in
            boardCell(member: member, index: index, frame: frame(index))
        }
    }

    @ViewBuilder
    private func boardCell(member: BoardGroup.Member, index: Int, frame: PackedFrame) -> some View {
        let status = coordinator.status(for: member)
        let name = coordinator.session(for: member)?.connection.deviceName ?? member.displayName
        let isTargeted = targetedIndex == index
        VStack(spacing: 4) {
            LEDBoardPreview(
                frame: frame,
                color: resolvedColor,
                brightness: resolvedBrightness,
                showBoardImage: showBoardPhoto,
                // Bloom only while boards are big enough for it to read.
                bloom: group.members.count <= 2,
                showsUnlitCells: true
            )
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("板 \(index + 1)，\(name)，\(BoardGroupStatusFormatting.text(status))")
        .disabled(coordinator.isStarting)
        .onDrag {
            let provider = NSItemProvider()
            let id = member.physicalBoardID
            provider.registerDataRepresentation(forTypeIdentifier: Self.boardDragType.identifier, visibility: .ownProcess) { completion in
                completion(Data(id.utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [Self.boardDragType], isTargeted: Binding(
            get: { targetedIndex == index },
            set: { targeted in targetedIndex = targeted ? index : (targetedIndex == index ? nil : targetedIndex) }
        )) { providers in
            guard !coordinator.isStarting, let provider = providers.first else { return false }
            let targetID = member.physicalBoardID
            _ = provider.loadDataRepresentation(forTypeIdentifier: Self.boardDragType.identifier) { data, _ in
                guard let data, let sourceID = String(data: data, encoding: .utf8), sourceID != targetID else { return }
                Task { @MainActor in onSwap(sourceID, targetID) }
            }
            return true
        }
    }
}

/// Boards left to right at one shared width. Adjacent boards sit one LED
/// column apart edge to edge (photo edge, or grid edge without the photo).
/// That already leaves `1 + matrixInsets` columns between the two LED
/// matrices; only a configured matrix gap larger than that pushes the boards
/// further apart, so the matrices end up exactly `gapColumns[i]` columns
/// apart. With no width proposed (inside a horizontal scroll view) boards use
/// `minBoardWidth`.
private struct BoardRowLayout: Layout {
    let gapColumns: [Int]
    /// One LED column's width as a fraction of a board's width.
    let columnFraction: CGFloat
    /// Photo border on both sides of the matrix, as a fraction of a board's width.
    let matrixInsetsFraction: CGFloat
    let minBoardWidth: CGFloat

    private func gap(after index: Int, boardWidth: CGFloat) -> CGFloat {
        let column = boardWidth * columnFraction
        let columns = index < gapColumns.count ? gapColumns[index] : 0
        let matrixGapEdgeToEdge = CGFloat(columns) * column - boardWidth * matrixInsetsFraction
        return max(column, matrixGapEdgeToEdge)
    }

    private func totalWidth(boardWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * boardWidth + (0..<(count - 1)).reduce(0) { $0 + gap(after: $1, boardWidth: boardWidth) }
    }

    /// Widest board width whose row still fits `available` (total width is
    /// monotonic in board width, so bisect), floored at `minBoardWidth`.
    private func boardWidth(available: CGFloat?, count: Int) -> CGFloat {
        guard let available, available.isFinite, count > 0 else { return minBoardWidth }
        var low: CGFloat = 0
        var high = available / CGFloat(count)
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if totalWidth(boardWidth: mid, count: count) <= available { low = mid } else { high = mid }
        }
        return max(low, minBoardWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = boardWidth(available: proposal.width, count: subviews.count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
        return CGSize(width: totalWidth(boardWidth: width, count: subviews.count), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = boardWidth(available: bounds.width, count: subviews.count)
        // Centre the row when the boards hit their minimum width limit
        // exactly and leave slack.
        var x = bounds.minX + max(0, (bounds.width - totalWidth(boardWidth: width, count: subviews.count)) / 2)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: nil))
            x += width + gap(after: index, boardWidth: width)
        }
    }
}
