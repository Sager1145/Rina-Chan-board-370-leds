import SwiftUI
import RinaCore

/// "多板组" entry point (BOARD_GROUP_SPEC.md §3): lists saved `BoardGroup`s,
/// creates new ones, and pushes the editor for an existing one.
struct BoardGroupListView: View {
    @Environment(BoardGroupStore.self) private var store
    @Environment(BoardGroupCoordinator.self) private var coordinator

    /// Where the open editor's group is kept. Settings passes its workspace
    /// so the editor survives a layout change; a sheet keeps its own.
    var editing: Binding<UUID?>?
    /// Passed to the editor; see `BoardGroupEditorView.onPlayed`.
    var onPlayed: (() -> Void)?
    @State private var localEditingGroupID: UUID?

    private var editingGroupID: Binding<UUID?> { editing ?? $localEditingGroupID }

    @State private var newGroupName = ""
    @State private var isPresentingCreate = false

    /// The 控制对象 menu's choice (BOARD_GROUP_SPEC.md §3): deleting the
    /// targeted group must reset this to `.single` rather than leave it
    /// pointed at a dead id.
    @AppStorage(ControlTargetKey.groupID) private var controlTargetGroupIDStorage = ""

    var body: some View {
        List {
            if store.groups.isEmpty {
                Section {
                    Text("还没有多板组。点击右上角的加号创建一个，把 2–5 块已连接的面板拼成一块大屏。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(store.groups) { group in
                        Button {
                            editingGroupID.wrappedValue = group.id
                        } label: {
                            HStack {
                                groupRow(group)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteGroups)
                }
            }
        }
        .rinaTranslucentRows()
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("多板组")
        .navigationDestination(item: editingGroupID) { id in
            BoardGroupEditorView(groupID: id, onPlayed: onPlayed)
        }
        .onChange(of: store.groups.map(\.id)) { _, ids in
            if let id = editingGroupID.wrappedValue, !ids.contains(id) { editingGroupID.wrappedValue = nil }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newGroupName = ""
                    isPresentingCreate = true
                } label: {
                    Label("新建多板组", systemImage: "plus")
                }
                .accessibilityLabel("新建多板组")
            }
        }
        .alert("新建多板组", isPresented: $isPresentingCreate) {
            TextField("组名称", text: $newGroupName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                store.create(name: trimmed.isEmpty ? "多板组" : trimmed)
            }
        }
    }

    private func groupRow(_ group: BoardGroup) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                Text("\(group.members.count) 块面板 · \(group.mode == .stitched ? "拼接" : "镜像")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // N1: paused counts as active here too — app-level pause never
            // ends group ownership, so this row must keep showing the group
            // is "live" rather than reading as idle.
            if coordinator.activeGroupID == group.id, coordinator.isPlaying || coordinator.isPaused {
                SwapLabel(coordinator.isPaused ? "已暂停" : "播放中", systemImage: coordinator.isPaused ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.rinaPink)
                    .accessibilityLabel(coordinator.isPaused ? "已暂停" : "播放中")
            }
        }
    }

    private func deleteGroups(at offsets: IndexSet) {
        // N5: collect ids from the IndexSet against the list as it stands
        // now, before any removal shifts later indices out from under the
        // remaining offsets.
        let ids = offsets.map { store.groups[$0].id }
        let groupsByID = Dictionary(uniqueKeysWithValues: store.groups.map { ($0.id, $0) })
        for id in ids {
            // A group still playing or starting must give up ownership —
            // otherwise the boards keep scrolling group-owned, the resync
            // loop no-ops against a deleted group, and its Stop button
            // becomes unreachable. The row goes away now; the stop runs
            // behind it so a slow board can't make the row snap back.
            if let group = groupsByID[id],
               coordinator.activeGroupID == id && (coordinator.isPlaying || coordinator.isPaused)
                || (coordinator.isStarting && coordinator.startingGroupID == id) {
                Task { await coordinator.stop(group: group) }
            }
            store.remove(id: id)
            if ControlTarget(storedGroupIDString: controlTargetGroupIDStorage) == .group(id) {
                controlTargetGroupIDStorage = ""
            }
        }
    }
}

#Preview {
    NavigationStack {
        BoardGroupListView()
    }
    .environment(BoardGroupStore())
    .environment(BoardGroupCoordinator(store: BoardGroupStore(), sessions: BoardSessionStore()))
    .environment(AppRouter())
}
