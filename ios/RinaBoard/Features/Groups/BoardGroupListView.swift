import SwiftUI
import RinaCore

/// "多板组" entry point (BOARD_GROUP_SPEC.md §3): lists saved `BoardGroup`s,
/// creates new ones, and pushes the editor for an existing one.
struct BoardGroupListView: View {
    @Environment(BoardGroupStore.self) private var store
    @Environment(BoardGroupCoordinator.self) private var coordinator

    @State private var newGroupName = ""
    @State private var isPresentingCreate = false

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
                        NavigationLink {
                            BoardGroupEditorView(groupID: group.id)
                        } label: {
                            groupRow(group)
                        }
                    }
                    .onDelete(perform: deleteGroups)
                }
            }
        }
        .rinaTranslucentRows()
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("多板组")
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
            if coordinator.isPlaying, coordinator.activeGroupID == group.id {
                Label("播放中", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.rinaPink)
                    .accessibilityLabel("播放中")
            }
        }
    }

    private func deleteGroups(at offsets: IndexSet) {
        for index in offsets {
            store.remove(id: store.groups[index].id)
        }
    }
}

#Preview {
    NavigationStack {
        BoardGroupListView()
    }
    .environment(BoardGroupStore())
    .environment(BoardGroupCoordinator(store: BoardGroupStore(), sessions: BoardSessionStore()))
}
