import SwiftUI
import UniformTypeIdentifiers
import RinaCore

/// Full saved-face management (design guide §11): the complete list with
/// rename, edit, delete, drag reorder and whole-document import/export.
///
/// Two independent libraries — 本机 (device-local) and 当前面板 (the
/// connected board) — are shown one at a time via a picker; each face row's
/// caption says whether it is a preset or a user face. Native list semantics
/// throughout — rows are `List` rows with swipe actions and a context menu,
/// plus a real `EditButton()`/`EditMode` for reordering and batch delete, not
/// website-style cards. Presented as a bottom sheet from the Control tab's
/// 「保存列表」 button (see `ControlView.savedFacesSheet`, which keeps the
/// glass `.rinaTall` presentation detent for this view).
///
/// A row's local management actions (edit, rename, delete, reorder) never
/// depend on the board connection — only 发送 (apply to the board's display)
/// does. Editing routes through `FaceLibraryModel.requestEdit`, which
/// `RootTabView` picks up as `pendingEditRequest` and hands to the Control
/// tab's editor, so this view never needs a direct `ControlViewModel`
/// dependency.
struct FaceLibraryView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(FaceLibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var editMode: EditMode = .inactive
    @State private var orderDraft: [SavedFace]?
    @State private var orderLocation: FaceLibraryLocation?
    @State private var orderGeneration: UUID?
    @State private var isWorking = false
    @State private var searchText = ""
    @State private var pickedLocation: FaceLibraryLocation?
    @State private var renaming: RenameTarget?
    @State private var deletion: DeleteTarget?
    @State private var showDeleteConfirmation = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var importLocation: FaceLibraryLocation = .local
    @State private var importGeneration: UUID?
    @State private var exportDocument: JSONFileDocument?
    @State private var numbers = FaceNumberRegistry.shared

    private struct RenameTarget: Identifiable {
        let face: SavedFace
        let location: FaceLibraryLocation
        let generation: UUID
        var id: String { "\(location.rawValue):\(face.id)" }
    }
    private struct DeleteTarget {
        let faces: [SavedFace]
        let location: FaceLibraryLocation
        let generation: UUID
    }
    private struct LoadKey: Equatable {
        let location: FaceLibraryLocation
        let generation: UUID
    }
    private struct NumberingKey: Equatable {
        let scope: String?
        let ids: [String]
    }

    /// "Which library is on screen" as one piece of state: `nil` means the
    /// user hasn't picked yet, so it follows the connection (board while
    /// connected, local otherwise). Once the user touches the picker their
    /// choice sticks for the life of the sheet, independent of connection
    /// changes.
    private var location: FaceLibraryLocation {
        pickedLocation ?? (connection.connectionState == .connected ? .board : .local)
    }
    private var isConnected: Bool { connection.connectionState == .connected }
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var confirmedFaces: [SavedFace] { model.faces(in: location) }
    private var displayedFaces: [SavedFace] { orderDraft ?? confirmedFaces }
    /// Loading flag for whichever library is on screen — `model.isLoading`
    /// only tracks the board fetch, so the local branch needs its own flag
    /// to avoid a spurious "暂无" flash while `loadLocalIfNeeded()` is
    /// still running.
    private var isLoading: Bool {
        location == .local ? (model.isLocalLoading || !model.isLocalLoaded) : model.isLoading
    }
    /// Proof (not a guess) that the current library actually finished a
    /// successful load, so management actions are safe to allow.
    private var libraryReady: Bool {
        if location == .local { return model.isLocalLoaded }
        return isConnected && model.boardGeneration == connection.connectionGeneration
    }
    /// Display-number scope: "local" or the connected board's physical id.
    /// `nil` when there is no stable board id to scope by — display numbers
    /// are then simply not allocated or shown for the session (the row still
    /// shows "顺序 N"), rather than persisting numbers under a
    /// reconnect-unstable session key.
    private var currentScope: String? {
        if location == .local { return "local" }
        guard let boardID = model.boardID ?? connection.boardKey else { return nil }
        return "board:\(boardID)"
    }
    private var canManage: Bool { libraryReady && !isWorking && !isLoading }
    private var canReorder: Bool {
        canManage && !isSearching && confirmedFaces.count > 1
    }

    var body: some View {
        let all = displayedFaces
        let visible = all.filter(matchesSearch)
        // Rank comes from the entire displayed order, never the search subset.
        let ranks = Dictionary(all.enumerated().map { ($0.element.id, $0.offset + 1) },
                               uniquingKeysWith: { first, _ in first })
        List {
            Picker("库", selection: Binding(get: { location }, set: { pickedLocation = $0 })) {
                ForEach(FaceLibraryLocation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(editMode.isEditing || isWorking)
            .listRowSeparator(.hidden)

            if let message = model.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
            if let message = model.operationMessage {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if isSearching {
                Text("搜索结果不能排序；请先清除搜索")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if visible.isEmpty && !isLoading {
                Text(isSearching ? "没有匹配的表情" : "暂无")
                    .foregroundStyle(.secondary)
            }

            // One ordered section, so presets and user faces can interleave.
            Section {
                ForEach(visible) { face in
                    row(face, rank: ranks[face.id] ?? 0)
                        .moveDisabled(!canReorder)
                        .deleteDisabled(!canManage || !model.canDelete(face))
                }
                .onMove { offsets, destination in
                    guard editMode.isEditing, canReorder else { return }
                    var draft = orderDraft ?? confirmedFaces
                    draft.move(fromOffsets: offsets, toOffset: destination)
                    orderDraft = draft
                }
                .onDelete { offsets in
                    let faces = offsets.compactMap { visible.indices.contains($0) ? visible[$0] : nil }
                        .filter(model.canDelete)
                    prepareDelete(faces)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("表情库")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索表情")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
                    .disabled(isWorking || isLoading || !libraryReady || isSearching || confirmedFaces.isEmpty)
                    .accessibilityIdentifier("faces.editMode")
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button("导出全部", systemImage: "square.and.arrow.up") { exportAll() }
                    Button("导入表情列表", systemImage: "square.and.arrow.down") {
                        importLocation = location
                        importGeneration = connection.connectionGeneration
                        isImporting = true
                    }.disabled(!canManage)
                    Button("刷新", systemImage: "arrow.clockwise") {
                        let source = location
                        let link = connection
                        perform { await refresh(source, connection: link) }
                    }
                    if location == .local, model.canUndoLocalDelete {
                        Button("撤销删除", systemImage: "arrow.uturn.backward") {
                            perform { _ = await model.undoLocalDelete() }
                        }
                    }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
                .disabled(isWorking || editMode.isEditing)
            }
        }
        // Bind the container for both List and toolbar. Not `.constant`, so
        // a drag reorder and Done/Cancel actually flow through one state.
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { old, new in
            if !old.isEditing && new.isEditing {
                orderDraft = confirmedFaces
                orderLocation = location
                orderGeneration = connection.connectionGeneration
            } else if old.isEditing && !new.isEditing {
                commitOrder()
            }
        }
        .onChange(of: searchText) { _, _ in
            if isSearching && editMode.isEditing { cancelOrder() }
        }
        .onChange(of: connection.connectionGeneration) { _, _ in
            cancelOrder()
            renaming = nil
            deletion = nil
            showDeleteConfirmation = false
        }
        .onChange(of: location) { _, _ in
            model.operationMessage = nil
            model.errorMessage = nil
        }
        .onAppear {
            model.operationMessage = nil
            model.errorMessage = nil
        }
        .task(id: LoadKey(location: location, generation: connection.connectionGeneration)) {
            if location == .local {
                await model.loadLocalIfNeeded()
            } else if isConnected && model.boardGeneration != connection.connectionGeneration {
                await model.reload(connection: connection)
            }
        }
        .task(id: NumberingKey(scope: currentScope, ids: confirmedFaces.map(\.id))) {
            if let scope = currentScope {
                numbers.ensureNumbers(for: confirmedFaces.map(\.id), scope: scope)
            }
        }
        .refreshable {
            guard !isWorking, !editMode.isEditing else { return }
            isWorking = true
            defer { isWorking = false }
            await refresh(location, connection: connection)
        }
        .overlay { if isLoading || isWorking { ProgressView().allowsHitTesting(false) } }
        .interactiveDismissDisabled(isWorking || editMode.isEditing)
        .sheet(item: $renaming) { target in
            FaceNameEditorSheet(title: NSLocalizedString("重命名", comment: "rename saved face"),
                                initialName: model.displayName(for: target.face)) { name in
                guard valid(target.location, generation: target.generation) else { return changedBoardMessage }
                isWorking = true
                defer { isWorking = false }
                let succeeded = await model.rename(target.face, to: name, in: target.location, connection: connection)
                return succeeded ? nil : (model.errorMessage ?? failedMessage)
            }
        }
        .confirmationDialog("删除表情？", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible, presenting: deletion) { target in
            Button("删除", role: .destructive) {
                guard valid(target.location, generation: target.generation) else {
                    model.errorMessage = changedBoardMessage
                    return
                }
                let link = connection
                // An edit-mode delete ends/cancels the reorder draft first, so
                // Done never submits a permutation that still names a
                // just-deleted id.
                cancelOrder()
                perform { _ = await model.delete(target.faces, from: target.location, connection: link) }
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("将删除 \(target.faces.count) 个表情")
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument,
                      contentType: .json, defaultFilename: "saved_faces") { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            guard valid(importLocation, generation: importGeneration) else {
                model.errorMessage = changedBoardMessage
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.reportImportUnreadable()
                return
            }
            let target = importLocation
            let link = connection
            perform { await model.importDocument(from: data, to: target, connection: link) }
        }
    }

    @ViewBuilder
    private func row(_ face: SavedFace, rank: Int) -> some View {
        HStack(spacing: 12) {
            if let frame = face.packedFrame {
                SavedFaceThumbnail(frame: frame, accessibilityDescription: "")
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .frame(width: SavedFaceThumbnail.size.width, height: SavedFaceThumbnail.size.height)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName(for: face))
                HStack {
                    if let scope = currentScope, let serial = numbers.number(for: face.id, scope: scope) {
                        Text("编号 F\(String(format: "%06lld", Int64(serial)))")
                    }
                    Text("顺序 \(rank)")
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                Text(face.type == .default ? "预设" : "我的表情")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !editMode.isEditing {
                Button { edit(face) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(Text(model.isProtected(face) ? "编辑副本" : "编辑"))
                    .disabled(!canManage || face.packedFrame == nil)
                Button { send(face) } label: { Image(systemName: "paperplane") }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("发送")
                    .disabled(!canManage || !isConnected || face.packedFrame == nil)
            }
        }
        // The row itself is never disabled as a whole when offline: local
        // management (edit/rename/delete/reorder) works without a board.
        // Only 发送 (above) and the board-only actions below check
        // `isConnected`.
        .contextMenu {
            Button(model.isProtected(face) ? "编辑副本" : "编辑", systemImage: "pencil") { edit(face) }
                .disabled(!canManage || editMode.isEditing || face.packedFrame == nil)
            Button("发送", systemImage: "paperplane") { send(face) }
                .disabled(!canManage || !isConnected || editMode.isEditing || face.packedFrame == nil)
            if !model.isProtected(face) {
                Button("重命名", systemImage: "character.cursor.ibeam") { rename(face) }
                    .disabled(!canManage || editMode.isEditing)
            }
            Button("创建副本", systemImage: "plus.square.on.square") {
                let source = location; let link = connection
                perform { _ = await model.duplicate(face, from: source, connection: link) }
            }.disabled(!canManage || editMode.isEditing)
            Button(location == .local ? "复制到当前面板" : "复制到本机", systemImage: "arrow.turn.up.right") {
                let source = location
                let target: FaceLibraryLocation = source == .local ? .board : .local
                let link = connection
                perform { _ = await model.copy(face, from: source, to: target, connection: link) }
            }.disabled(!canManage || editMode.isEditing || (location == .local && !isConnected))
            if model.canDelete(face) {
                Button("删除", systemImage: "trash", role: .destructive) { prepareDelete([face]) }
                    .disabled(!canManage)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if model.canDelete(face) {
                Button("删除", role: .destructive) { prepareDelete([face]) }.disabled(!canManage)
            }
            if !model.isProtected(face) {
                Button("重命名") { rename(face) }.disabled(!canManage || editMode.isEditing)
            }
        }
    }

    private func matchesSearch(_ face: SavedFace) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || face.name.localizedCaseInsensitiveContains(query)
            || model.displayName(for: face).localizedCaseInsensitiveContains(query)
            || face.id.localizedCaseInsensitiveContains(query)
    }
    private var changedBoardMessage: String {
        NSLocalizedString("面板已更换，请重新选择表情", comment: "saved face belongs to another board")
    }
    private var failedMessage: String {
        NSLocalizedString("操作失败，请重试", comment: "saved face operation failed")
    }
    private func valid(_ source: FaceLibraryLocation, generation: UUID?) -> Bool {
        source == .local || (isConnected && generation == connection.connectionGeneration
                           && model.boardGeneration == generation)
    }
    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        guard !isWorking else { return }
        isWorking = true // Set before creating the Task: prevents double-tap enqueueing.
        Task { @MainActor in
            defer { isWorking = false }
            await operation()
        }
    }
    private func send(_ face: SavedFace) {
        guard canManage, isConnected, !editMode.isEditing else { return }
        let source = location; let link = connection
        perform { await model.apply(face, from: source, connection: link) }
    }
    private func edit(_ face: SavedFace) {
        guard canManage, !editMode.isEditing, face.packedFrame != nil else { return }
        model.requestEdit(face, location: location,
                          connectionGeneration: connection.connectionGeneration)
        dismiss()
    }
    private func rename(_ face: SavedFace) {
        guard canManage, !editMode.isEditing, !model.isProtected(face) else { return }
        renaming = RenameTarget(face: face, location: location, generation: connection.connectionGeneration)
    }
    private func prepareDelete(_ faces: [SavedFace]) {
        guard canManage, !faces.isEmpty else { return }
        deletion = DeleteTarget(faces: faces, location: location, generation: connection.connectionGeneration)
        showDeleteConfirmation = true
    }
    private func cancelOrder() {
        orderDraft = nil; orderLocation = nil; orderGeneration = nil
        editMode = .inactive
    }
    private func commitOrder() {
        guard let draft = orderDraft, let source = orderLocation else { return }
        let generation = orderGeneration
        guard valid(source, generation: generation) else {
            cancelOrder(); model.errorMessage = changedBoardMessage; return
        }
        guard draft.map(\.id) != model.faces(in: source).map(\.id) else { cancelOrder(); return }
        // If another operation is already running, `perform` would silently
        // no-op and leave the drafted order on screen unwritten. Drop the
        // draft instead of showing an order that was never persisted.
        guard !isWorking else { orderDraft = nil; orderLocation = nil; orderGeneration = nil; return }
        let link = connection
        perform {
            _ = await model.reorderFaces(draft, in: source, connection: link)
            // The model retains its confirmed order on failure. Clearing the
            // draft therefore rolls back the UI without an invented success.
            cancelOrder()
        }
    }
    private func refresh(_ source: FaceLibraryLocation, connection: BoardConnection) async {
        if source == .local { await model.reloadLocal() }
        else { await model.reload(connection: connection) }
    }
    private func exportAll() {
        guard let data = model.exportData(faces: confirmedFaces, from: location) else {
            model.errorMessage = NSLocalizedString("导出失败", comment: "saved faces export failed")
            return
        }
        exportDocument = JSONFileDocument(data: data)
        isExporting = true
    }
}

/// Whole-document JSON file for `.fileExporter`.
struct JSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
