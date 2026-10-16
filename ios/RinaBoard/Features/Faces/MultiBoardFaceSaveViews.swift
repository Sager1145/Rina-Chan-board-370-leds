import SwiftUI
import RinaCore

/// The presentation and its frozen data travel together. A boolean sheet can
/// otherwise reuse content built before the first destination selection.
@MainActor
struct FaceSaveTargetsPresentation: Identifiable {
    let id = UUID()
    let destinations: [FrozenFaceSaveDestination]
    let currentID: String?
    let overwriteBoardID: String?
}

@MainActor
struct FaceSaveNamingPresentation: Identifiable {
    let id = UUID()
    let title: String
    let name: String
    let frame: PackedFrame
    let faceID: String?
    let asNew: Bool
    let boardSource: BoardFaceSaveSource?
    let snapshot: MultiBoardFaceSaveSnapshot?
    let destinations: [FrozenFaceSaveDestination]
}

struct FaceSaveResultsPresentation: Identifiable {
    let id = UUID()
    let startPrepared: Bool
}

@MainActor
struct FaceSaveDestinationSelection {
    let availableIDs: Set<String>
    private(set) var selectedIDs: Set<String>
    init(destinations: [FrozenFaceSaveDestination], currentID: String?) {
        availableIDs = Set(destinations.map(\.id))
        selectedIDs = []
        if let currentID, availableIDs.contains(currentID) { selectedIDs.insert(currentID) }
    }
    static func requiresPicker(_ destinations: [FrozenFaceSaveDestination], activeConnection: BoardConnection) -> Bool {
        destinations.count > 1 || destinations.first.map { $0.connection !== activeConnection } == true
    }
    var allSelected: Bool { !availableIDs.isEmpty && selectedIDs == availableIDs }
    mutating func setAll(_ selected: Bool) { selectedIDs = selected ? availableIDs : [] }
    mutating func set(_ id: String, selected: Bool) {
        guard availableIDs.contains(id) else { return }
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    }
}

struct FaceSaveTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let destinations: [FrozenFaceSaveDestination]
    let onContinue: ([FrozenFaceSaveDestination]) -> Void
    let overwriteBoardID: String?
    @State private var selection: FaceSaveDestinationSelection

    init(destinations: [FrozenFaceSaveDestination], currentID: String?, overwriteBoardID: String?,
         onContinue: @escaping ([FrozenFaceSaveDestination]) -> Void) {
        self.destinations = destinations
        self.overwriteBoardID = overwriteBoardID
        self.onContinue = onContinue
        _selection = State(initialValue: FaceSaveDestinationSelection(destinations: destinations, currentID: currentID))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("所有已连接面板", isOn: Binding(get: { selection.allSelected }, set: { selection.setAll($0) }))
                        .accessibilityIdentifier("faces.saveTargets.all")
                } footer: {
                    Text("已选择 \(selection.selectedIDs.count) / \(destinations.count) 个面板。稍后连接的面板不会自动加入。")
                }
                Section("选择保存面板") {
                    ForEach(destinations) { destination in
                        Toggle(isOn: Binding(
                            get: { selection.selectedIDs.contains(destination.id) },
                            set: { selection.set(destination.id, selected: $0) })) {
                            VStack(alignment: .leading) {
                                Text(destination.name)
                                Text(destination.id == overwriteBoardID ? "更新此表情" : "保存新副本")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("faces.saveTargets.\(destination.id)")
                    }
                }
            }
            .navigationTitle("保存到哪些面板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续") {
                        onContinue(destinations.filter { selection.selectedIDs.contains($0.id) })
                        dismiss()
                    }.disabled(selection.selectedIDs.isEmpty)
                }
            }
        }
    }
}

struct MultiBoardFaceSaveResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BoardSessionStore.self) private var sessions
    let coordinator: MultiBoardFaceSaveCoordinator
    let startPrepared: Bool
    let onResultsChanged: () async -> Void
    @State private var confirmingEnd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if coordinator.hasUnreadableJournal {
                        Label("上次多面板保存记录无法读取", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if coordinator.allConfirmed {
                        Label("所选面板均已保存并核对", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("保存尚未全部完成", systemImage: "clock")
                            .foregroundStyle(.orange)
                    }
                    if let name = coordinator.operation?.name { Text(name).foregroundStyle(.secondary) }
                }
                ForEach(coordinator.operation?.targets ?? []) { target in
                    Section {
                        HStack {
                            Text(target.name)
                            Spacer()
                            Text(target.status.title)
                                .foregroundStyle(target.status == .confirmed ? Color.green : Color.secondary)
                        }
                        if let message = target.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if let error = coordinator.errorMessage { Text(error).foregroundStyle(.red) }
                if coordinator.hasUnconfirmed {
                    Button("仅重试未完成的面板") {
                        let candidates = FrozenFaceSaveDestination.connected(in: sessions)
                        Task { await coordinator.retry(using: candidates) }
                    }.disabled(coordinator.isRunning)
                }
                if coordinator.hasUnconfirmed || coordinator.hasUnreadableJournal {
                    Button("结束本次保存", role: .destructive) { confirmingEnd = true }
                        .disabled(coordinator.isRunning)
                }
            }
            .confirmationDialog("结束本次保存？", isPresented: $confirmingEnd, titleVisibility: .visible) {
                Button("结束本次保存", role: .destructive) {
                    Task {
                        if await coordinator.endOperation(beforeEnding: onResultsChanged) { dismiss() }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已确认的面板会保留新表情。未完成的面板不会再重试，也不会撤回；其中可能已写入，请稍后在该面板的表情列表中检查。")
            }
            .navigationTitle("保存结果")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task {
                            // Adoption is allowed only on its original verified
                            // carrier. After restart, review/Finish is explicit;
                            // no stale editor target is inferred from an old ACK.
                            await onResultsChanged()
                            await coordinator.finishIfConfirmed()
                            dismiss()
                        }
                    }.disabled(coordinator.isRunning)
                }
            }
            .interactiveDismissDisabled(coordinator.isRunning)
            .task {
                if startPrepared { await coordinator.savePrepared() }
                await onResultsChanged()
            }
            .onChange(of: coordinator.resultsRevision) { _, _ in
                Task { await onResultsChanged() }
            }
        }
    }
}
