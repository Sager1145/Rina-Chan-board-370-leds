import SwiftUI
import RinaCore

/// Multi-board scroll preview for a targeted `BoardGroup` (BOARD_GROUP_SPEC.md
/// §3): every member is drawn side by side with a visible gap and a label
/// (number + name + status) underneath, and can be reordered by long-press
/// dragging one board to a new position. Cells only light up for content the boards
/// are confirmed to be running; nothing uploaded or synced means a dark row.
struct GroupScrollPreview: View {
    let group: BoardGroup
    /// `nil` follows the Control Center draft, like `BoardPreviewRow`.
    var color: Color? = nil
    var brightness: Int? = nil
    /// Commits one insertion move after the local drag preview settles.
    let onMove: (String, String) async throws -> Void

    @Environment(BoardGroupCoordinator.self) private var coordinator
    /// Optional for the same reason as in `BoardPreviewRow`: test hosts and
    /// previews don't inject it.
    @Environment(BoardControlCenterModel.self) private var controlCenter: BoardControlCenterModel?
    /// Same reasoning: optional so test hosts and `#Preview`s that don't
    /// inject `AppRouter` don't crash. While its gate is pending (user
    /// requirement: "刚打开app同步时，完成同步再显示预览画面，不要让预览画面闪一下"), this preview
    /// holds every cell blank.
    @Environment(AppRouter.self) private var router: AppRouter?
    /// Same setting as the single-board preview's board photo.
    @AppStorage(AppSettingsKey.showBoardPhoto) private var showBoardPhoto = true

    private var resolvedColor: Color {
        color ?? controlCenter?.draftColor ?? .rinaPink
    }

    private var resolvedBrightness: Int {
        brightness ?? controlCenter.map(\.draftBrightness) ?? RinaLinkConstants.brightnessDefault
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false
    @State private var drag: MemberDrag?
    @State private var dragTranslation: CGSize = .zero
    @State private var memberFrames: [String: CGRect] = [:]

    private struct MemberDrag {
        let sourceID: String
        let originalIDs: [String]
        let slotCenters: [CGFloat]
        var previewIDs: [String]
        var released = false
    }

    private var reorderAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9)
    }

    private static let minCellSide: CGFloat = 70

    var body: some View {
        Group {
            if router?.launchPreviewPending == true {
                boardRow(members: group.members) { _ in PackedFrame() }
            } else {
                let snapshot = coordinator.previewSnapshot
                let mode = GroupPreviewPolicy.mode(
                    snapshotGroupID: snapshot?.groupID, groupID: group.id, isPaused: coordinator.previewIsPaused
                )
                if let snapshot, mode != .dark {
                    livePreview(snapshot: snapshot)
                } else {
                    // Nothing uploaded or synced: no preview. The dark row
                    // stays so boards can still be drag-reordered.
                    boardRow(members: group.members) { _ in PackedFrame() }
                }
            }
        }
        .onChange(of: isDragging) { _, active in
            // GestureState also resets when the system cancels a drag.
            if !active, drag?.released == false { cancelDrag() }
        }
        .onChange(of: coordinator.isStarting) { _, starting in
            if starting, drag?.released == false { cancelDrag() }
        }
        .onChange(of: group.members.map(\.physicalBoardID)) { _, ids in
            if let drag, !drag.released, ids != drag.originalIDs { cancelDrag() }
        }
        .onChange(of: group.id) { _, _ in cancelDrag() }
        .onDisappear { cancelDrag() }
    }

    // MARK: - Live (playing/paused) preview

    /// Per cell: only a board the coordinator has positive evidence is
    /// actually running this content (`GroupPreviewPolicy.cellIsLive`) draws
    /// the live bitmap window; every other cell (offline, superseded,
    /// uploading, not yet a participant) draws a dark placeholder frame.
    @ViewBuilder
    private func livePreview(snapshot: BoardGroupCoordinator.PlaybackSnapshot) -> some View {
        let groupPaused = coordinator.previewIsPaused
        let row = { (frameIndex: Int) in
            boardRow(members: snapshot.memberOrder) { index in
                let member = snapshot.memberOrder[index]
                let isLive = GroupPreviewPolicy.cellIsLive(
                    coordinator.previewStatus(for: member),
                    isLiveParticipant: coordinator.isLivePreviewParticipant(member),
                    groupPaused: groupPaused
                )
                guard isLive else { return PackedFrame() }
                return GroupScrollBitmap.frame(bitmap: snapshot.bitmap, viewportX: snapshot.viewportXs[index], frameIndex: frameIndex)
            }
        }
        if groupPaused {
            // A still frame; step() changes pausedFrame, which re-renders.
            row(coordinator.previewFrame() ?? 0)
        } else {
            TimelineView(.animation(minimumInterval: Double(max(snapshot.intervalMs, 1)) / 1000)) { _ in
                row(coordinator.previewFrame() ?? 0)
            }
        }
    }

    // MARK: - Draft (not yet playing) preview

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
        .coordinateSpace(name: group.id)
        .onPreferenceChange(MemberFrameKey.self) { memberFrames = $0 }
    }

    @ViewBuilder
    private func boardCells(members: [BoardGroup.Member], frame: @escaping (Int) -> PackedFrame) -> some View {
        ForEach(Array(members.enumerated()), id: \.element.physicalBoardID) { index, member in
            let ids = members.map(\.physicalBoardID)
            let previewIndex = drag?.previewIDs.firstIndex(of: member.physicalBoardID) ?? index
            let tracksPointer = drag?.sourceID == member.physicalBoardID && drag?.released == false
            boardCell(member: member, index: previewIndex, frame: frame(index))
                // Keep the dragged view at its original slot until release;
                // changing preview slots must never move it away from the finger.
                .layoutValue(key: BoardSlotKey.self, value: tracksPointer ? index : previewIndex)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: MemberFrameKey.self, value: [
                            member.physicalBoardID: geometry.frame(in: .named(group.id))
                        ])
                    }
                }
                .offset(tracksPointer ? dragTranslation : .zero)
                .zIndex(drag?.sourceID == member.physicalBoardID ? 1 : 0)
                // A short swipe remains available to the horizontal scroll
                // view; only a completed long press activates board movement.
                .gesture(memberDrag(memberID: member.physicalBoardID, ids: ids))
                .accessibilityActions {
                    if index > 0 {
                        Button("向左移动") { moveAccessibly(member.physicalBoardID, to: ids[index - 1]) }
                    }
                    if index + 1 < ids.count {
                        Button("向右移动") { moveAccessibly(member.physicalBoardID, to: ids[index + 1]) }
                    }
                }
        }
    }

    @ViewBuilder
    private func boardCell(member: BoardGroup.Member, index: Int, frame: PackedFrame) -> some View {
        let status = coordinator.status(for: member)
        let name = coordinator.session(for: member)?.connection.deviceName ?? member.displayName
        let isTargeted = drag?.sourceID == member.physicalBoardID
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
    }

    private func memberDrag(memberID: String, ids: [String]) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(group.id)))
            .updating($isDragging) { value, active, _ in
                if case .second(true, _) = value { active = true }
            }
            .onChanged { value in
                guard !coordinator.isStarting, drag?.released != true,
                      case .second(true, let movement) = value else { return }
                if drag == nil {
                    let centers = ids.compactMap { memberFrames[$0]?.midX }
                    guard centers.count == ids.count else { return }
                    drag = MemberDrag(sourceID: memberID, originalIDs: ids,
                                      slotCenters: centers, previewIDs: ids)
                }
                guard let movement else { return }
                updateDrag(translation: movement.translation)
            }
            .onEnded { value in
                guard drag?.released != true else { return }
                guard case .second(true, let movement) = value, let movement else {
                    cancelDrag()
                    return
                }
                updateDrag(translation: movement.translation)
                finishDrag()
            }
    }

    private func updateDrag(translation: CGSize) {
        guard var current = drag, !current.released,
              let source = current.originalIDs.firstIndex(of: current.sourceID) else { return }
        // Tracking is direct; only discrete neighbour displacement gets a spring.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dragTranslation = translation }
        let center = current.slotCenters[source] + translation.width
        let target = current.slotCenters.indices.min {
            abs(current.slotCenters[$0] - center) < abs(current.slotCenters[$1] - center)
        } ?? source
        var order = current.originalIDs
        order.remove(at: source)
        order.insert(current.sourceID, at: target)
        guard order != current.previewIDs else { return }
        current.previewIDs = order
        withAnimation(reorderAnimation) { drag = current }
    }

    private func finishDrag() {
        guard var current = drag, !current.released,
              let source = current.originalIDs.firstIndex(of: current.sourceID),
              let destination = current.previewIDs.firstIndex(of: current.sourceID) else {
            cancelDrag()
            return
        }
        guard source != destination else {
            cancelDrag()
            return
        }
        // The target is the original occupant of the destination slot. The
        // coordinator commits the same remove/insert operation once, on release.
        let targetID = current.originalIDs[destination]
        current.released = true
        withAnimation(reorderAnimation) {
            drag = current
            dragTranslation = .zero
        }
        Task { @MainActor in
            do { try await onMove(current.sourceID, targetID) }
            catch { /* The caller presents the existing reorder error. */ }
            // Retain the local order until the commit/replay completes, avoiding
            // a flash back to the old playback snapshot while it restarts.
            if drag?.sourceID == current.sourceID, drag?.released == true {
                cancelDrag()
            }
        }
    }

    private func moveAccessibly(_ memberID: String, to targetID: String) {
        guard !coordinator.isStarting, drag == nil else { return }
        Task { @MainActor in
            do { try await onMove(memberID, targetID) }
            catch { /* The caller presents the existing reorder error. */ }
        }
    }

    private func cancelDrag() {
        withAnimation(reorderAnimation) {
            drag = nil
            dragTranslation = .zero
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
        var slotXs: [CGFloat] = []
        for index in subviews.indices {
            slotXs.append(x)
            x += width + gap(after: index, boardWidth: width)
        }
        for subview in subviews {
            let slot = min(max(0, subview[BoardSlotKey.self]), max(0, slotXs.count - 1))
            subview.place(at: CGPoint(x: slotXs[slot], y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: nil))
        }
    }
}


private struct BoardSlotKey: LayoutValueKey {
    static let defaultValue = 0
}

private struct MemberFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
