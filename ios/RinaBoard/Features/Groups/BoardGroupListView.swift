import SwiftUI
import RinaCore

/// "多板组" entry point (BOARD_GROUP_SPEC.md §3): lists saved `BoardGroup`s,
/// creates new ones, and pushes the editor for an existing one.
struct BoardGroupListView: View {
    @Environment(BoardGroupStore.self) private var store
    @Environment(BoardGroupCoordinator.self) private var coordinator
    @Environment(\.duoWorkspace) private var duoWorkspace
    @Environment(\.foldedDuo) private var foldedDuo

    private var keepsActionsInMenu: Bool { duoWorkspace || foldedDuo || workspace?.usesDuoMenuRouting == true }

    /// Where the open editor's group is kept. Settings passes its workspace
    /// so the editor survives a layout change; a sheet keeps its own.
    var editing: Binding<UUID?>?
    var workspace: SettingsWorkspace?
    /// Passed to the editor; see `BoardGroupEditorView.onPlayed`.
    var onPlayed: (() -> Void)?
    @State private var localEditingGroupID: UUID?

    private var editingGroupID: Binding<UUID?> { editing ?? $localEditingGroupID }

    @State private var newGroupName = ""
    @State private var isPresentingCreate = false

    private var creationPresented: Binding<Bool> {
        if keepsActionsInMenu, let workspace { return Bindable(workspace).isPresentingCreateGroup }
        return $isPresentingCreate
    }

    private var creationName: Binding<String> {
        if keepsActionsInMenu, let workspace { return Bindable(workspace).newGroupName }
        return $newGroupName
    }

    /// The 控制对象 menu's choice (BOARD_GROUP_SPEC.md §3): deleting the
    /// targeted group must reset this to `.single` rather than leave it
    /// pointed at a dead id.
    @AppStorage(ControlTargetKey.groupID) private var controlTargetGroupIDStorage = ""

    var body: some View {
        List {
            if keepsActionsInMenu {
                Section {
                    if creationPresented.wrappedValue {
                        TextField("组名称", text: creationName)
                            .accessibilityIdentifier("groups.create.name")
                        HStack {
                            Button("取消", role: .cancel) { creationPresented.wrappedValue = false }
                            Spacer()
                            Button("创建") { createGroup() }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        createButton
                    }
                }
            }
            if store.groups.isEmpty {
                Section {
                    if keepsActionsInMenu {
                        Text("暂无").foregroundStyle(.secondary)
                    } else {
                        Text("还没有多板组。点击右上角的加号创建一个，把 2–5 块已连接的面板拼成一块大屏。")
                            .foregroundStyle(.secondary)
                    }
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
        .navigationBarBackButtonHidden(keepsActionsInMenu)
        // Duo Settings owns this route in its detail pane. Native pushing
        // promotes nested destinations to the whole Duo window.
        .modifier(GroupEditorNavigation(editing: editingGroupID,
                                        enabled: !keepsActionsInMenu || workspace == nil,
                                        onPlayed: onPlayed))
        .onChange(of: store.groups.map(\.id)) { _, ids in
            if let id = editingGroupID.wrappedValue, !ids.contains(id) { editingGroupID.wrappedValue = nil }
        }
        .toolbar {
            if !keepsActionsInMenu {
                MenuToolbarItem(placement: .primaryAction) { createButton }
            }
        }
        .alert("新建多板组", isPresented: Binding(
            get: { !keepsActionsInMenu && isPresentingCreate },
            set: { isPresentingCreate = $0 }
        )) {
            TextField("组名称", text: $newGroupName)
            Button("取消", role: .cancel) {}
            Button("创建") { createGroup() }
        }
    }

    private var createButton: some View {
        Button {
            creationName.wrappedValue = ""
            creationPresented.wrappedValue = true
        } label: { Label("新建多板组", systemImage: "plus") }
        .accessibilityLabel("新建多板组")
        .accessibilityIdentifier("groups.create")
    }

    private func createGroup() {
        let trimmed = creationName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        store.create(name: trimmed.isEmpty ? String(localized: "多板组") : trimmed)
        creationPresented.wrappedValue = false
    }

    private func groupRow(_ group: BoardGroup) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                let mode = group.mode == .stitched ? String(localized: "拼接") : String(localized: "镜像")
                Text("\(group.members.count) 块面板 · \(mode)")
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

private struct GroupEditorNavigation: ViewModifier {
    @Binding var editing: UUID?
    let enabled: Bool
    var onPlayed: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(item: $editing) { id in
                BoardGroupEditorView(groupID: id, onPlayed: onPlayed)
            }
        } else {
            content
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
