import SwiftUI
import RinaCore

/// Rename, reorder, gap, and membership editor for one `BoardGroup`
/// (BOARD_GROUP_SPEC.md §3). Pushes `BoardGroupPlayView` for the play panel.
struct BoardGroupEditorView: View {
    let groupID: UUID

    @Environment(BoardGroupStore.self) private var store
    @Environment(BoardGroupCoordinator.self) private var coordinator
    @Environment(BoardSessionStore.self) private var sessions
    @Environment(\.editMode) private var editMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var nameDraft = ""
    @State private var isIdentifying = false
    @State private var isPresentingAddSheet = false
    @State private var errorMessage: String?

    private var group: BoardGroup? {
        store.groups.first { $0.id == groupID }
    }

    var body: some View {
        Group {
            if let group {
                editor(for: group)
            } else {
                ContentUnavailableView("多板组已删除", systemImage: "square.stack.3d.up.slash")
            }
        }
        .navigationTitle(group?.name ?? "多板组")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($errorMessage)
        .onDisappear {
            isIdentifying = false
            // N4: the loop must stop even if the group was deleted out from
            // under this screen while it was open — `stopIdentifyLoop()`
            // cancels the polling task unconditionally, with no group needed.
            if let group {
                coordinator.stopIdentifyLoop(for: group)
            } else {
                coordinator.stopIdentifyLoop()
            }
        }
    }

    @ViewBuilder
    private func editor(for group: BoardGroup) -> some View {
        List {
            Section("名称") {
                TextField("组名称", text: nameBinding(group))
            }

            Section("模式") {
                Picker("模式", selection: modeBinding(group)) {
                    Text("拼接").tag(BoardGroup.Mode.stitched)
                    Text("镜像").tag(BoardGroup.Mode.mirror)
                }
                .pickerStyle(.segmented)
            }

            Section {
                if group.members.isEmpty {
                    Text("还没有面板。点击下方“添加板子”。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(group.members.enumerated()), id: \.element.physicalBoardID) { index, member in
                        memberRow(group: group, member: member, slot: index)
                    }
                    .onMove { offsets, destination in
                        moveMembers(group: group, offsets: offsets, destination: destination)
                    }
                }
            } header: {
                Text("面板（\(group.members.count)/\(BoardGroup.maxMembers)）")
            } footer: {
                if group.members.count >= BoardGroup.maxMembers {
                    Text("已达到 5 块面板上限。")
                }
            }

            if group.mode == .stitched, group.members.count > 1 {
                Section("间隔（拼接模式）") {
                    ForEach(Array(group.gapsAfter.enumerated()), id: \.offset) { index, gap in
                        Stepper(
                            "第 \(index + 1)、\(index + 2) 块面板之间：\(gap) 列",
                            value: gapBinding(group: group, slot: index),
                            in: 0...BoardGroup.maxGap
                        )
                    }
                }
            }

            Section {
                Button {
                    isPresentingAddSheet = true
                } label: {
                    Label("添加板子", systemImage: "plus.circle")
                }
                .disabled(group.members.count >= BoardGroup.maxMembers)

                Button {
                    toggleIdentify(group: group)
                } label: {
                    Label(isIdentifying ? "停止识别编号" : "识别编号",
                          systemImage: isIdentifying ? "stop.circle" : "number.circle")
                }
                .disabled(group.members.isEmpty)

                NavigationLink {
                    BoardGroupPlayView(groupID: group.id)
                } label: {
                    Label("播放", systemImage: "play.circle")
                }
            }
        }
        .rinaTranslucentRows()
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        .sheet(isPresented: $isPresentingAddSheet) {
            NavigationStack {
                addMemberSheet(group: group)
            }
        }
    }

    // MARK: - Member row

    @ViewBuilder
    private func memberRow(group: BoardGroup, member: BoardGroup.Member, slot: Int) -> some View {
        let status = coordinator.status(for: member)
        let nameAndStatus = VStack(alignment: .leading, spacing: 2) {
            Text("\(slot + 1). \(displayName(for: member))")
            Text(BoardGroupStatusFormatting.text(status))
                .font(.caption)
                .foregroundStyle(BoardGroupStatusFormatting.color(status))
        }
        let reorderButtons = HStack(spacing: 4) {
            Button {
                moveMember(group: group, slot: slot, delta: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(slot == 0)
            .accessibilityLabel("左移")
            Button {
                moveMember(group: group, slot: slot, delta: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(slot == group.members.count - 1)
            .accessibilityLabel("右移")
        }
        .buttonStyle(.borderless)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    nameAndStatus
                    reorderButtons
                }
            } else {
                HStack(spacing: 12) {
                    nameAndStatus
                    Spacer()
                    reorderButtons
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                store.removeMember(groupID: group.id, physicalBoardID: member.physicalBoardID)
            } label: {
                Label("移除", systemImage: "trash")
            }
        }
    }

    private func displayName(for member: BoardGroup.Member) -> String {
        coordinator.session(for: member)?.connection.deviceName ?? member.displayName
    }

    // MARK: - Add member sheet

    private var availableSessions: [BoardSession] {
        guard let group else { return [] }
        let existing = Set(group.members.map(\.physicalBoardID))
        return sessions.sessions.filter { session in
            guard let identity = session.connection.boardIdentity, !existing.contains(identity) else { return false }
            return session.connection.connectionState == .connected
        }
    }

    @ViewBuilder
    private func addMemberSheet(group: BoardGroup) -> some View {
        List {
            if group.members.count >= BoardGroup.maxMembers {
                Section {
                    Text("多板组最多支持 5 块面板，已达到上限。")
                        .foregroundStyle(.secondary)
                }
            } else if availableSessions.isEmpty {
                Section {
                    Text("没有可添加的已连接面板。先在连接设置里连接更多面板。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(availableSessions) { session in
                        Button {
                            addMember(group: group, session: session)
                        } label: {
                            Text(session.connection.deviceName ?? session.name)
                        }
                    }
                }
            }
        }
        .navigationTitle("添加板子")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { isPresentingAddSheet = false }
            }
        }
    }

    private func addMember(group: BoardGroup, session: BoardSession) {
        guard let identity = session.connection.boardIdentity else { return }
        let member = BoardGroup.Member(
            physicalBoardID: identity,
            displayName: session.connection.deviceName ?? session.name
        )
        do {
            try store.addMember(groupID: group.id, member: member)
            isPresentingAddSheet = false
        } catch {
            errorMessage = "添加失败：\(error)"
        }
    }

    // MARK: - Bindings / actions

    private func nameBinding(_ group: BoardGroup) -> Binding<String> {
        Binding(
            get: { group.name },
            set: { store.rename(id: group.id, to: $0) }
        )
    }

    private func modeBinding(_ group: BoardGroup) -> Binding<BoardGroup.Mode> {
        Binding(
            get: { group.mode },
            set: { store.setMode(id: group.id, mode: $0) }
        )
    }

    private func gapBinding(group: BoardGroup, slot: Int) -> Binding<Int> {
        Binding(
            get: { group.gapsAfter[safe: slot] ?? 0 },
            set: { newValue in
                do {
                    try store.setGap(groupID: group.id, afterSlot: slot, columns: newValue)
                } catch {
                    errorMessage = "设置间隔失败：\(error)"
                }
            }
        )
    }

    private func moveMembers(group: BoardGroup, offsets: IndexSet, destination: Int) {
        // `List.onMove` gives a batch move; a single-member drag is the only
        // shape the store's `moveMember(from:to:)` needs to handle here.
        guard let from = offsets.first else { return }
        let to = destination > from ? destination - 1 : destination
        guard from != to else { return }
        store.moveMember(groupID: group.id, from: from, to: to)
    }

    private func moveMember(group: BoardGroup, slot: Int, delta: Int) {
        let target = slot + delta
        guard group.members.indices.contains(target) else { return }
        store.moveMember(groupID: group.id, from: slot, to: target)
    }

    private func toggleIdentify(group: BoardGroup) {
        isIdentifying.toggle()
        if isIdentifying {
            coordinator.startIdentifyLoop(for: group)
        } else {
            coordinator.stopIdentifyLoop(for: group)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    let store = BoardGroupStore()
    let group = store.create(name: "客厅拼接屏")
    return NavigationStack {
        BoardGroupEditorView(groupID: group.id)
    }
    .environment(store)
    .environment(BoardGroupCoordinator(store: store, sessions: BoardSessionStore()))
    .environment(BoardSessionStore())
}
