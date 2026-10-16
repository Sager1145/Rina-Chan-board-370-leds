import SwiftUI
import UniformTypeIdentifiers
import RinaCore

/// The connected board's confirmed saved faces: rename, edit, delete, reorder,
/// import/export, and an explicit copy flow for preserved legacy local data.
/// Editing hands a board-scoped snapshot to Control through `requestEdit`.
struct FaceLibraryView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(FaceLibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.duoWorkspace) private var duoWorkspace
    @Environment(\.foldedDuo) private var foldedDuo

    private var keepsActionsInMenu: Bool { duoWorkspace || foldedDuo }

    @State private var editMode: EditMode = .inactive
    @State private var orderDraft: [SavedFace]?
    @State private var orderLocation: FaceLibraryLocation?
    @State private var orderGeneration: UUID?
    @State private var orderCursor: BoardFaceSaveSource?
    @State private var isWorking = false
    @State private var searchText = ""
    @State private var isMigratingLegacy = false
    @State private var renaming: RenameTarget?
    @State private var deletion: DeleteTarget?
    @State private var showDeleteConfirmation = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var importLocation: FaceLibraryLocation = .board
    @State private var importGeneration: UUID?
    @State private var importCursor: BoardFaceSaveSource?
    @State private var exportDocument: JSONFileDocument?
    @State private var numbers = FaceNumberRegistry.shared

    private struct RenameTarget: Identifiable {
        let face: SavedFace
        let location: FaceLibraryLocation
        let generation: UUID
        let cursor: BoardFaceSaveSource
        var id: String { "\(location.rawValue):\(face.id)" }
    }
    private struct DeleteTarget {
        let faces: [SavedFace]
        let location: FaceLibraryLocation
        let generation: UUID
        let cursor: BoardFaceSaveSource
    }
    private struct LoadKey: Equatable {
        let location: FaceLibraryLocation
        let generation: UUID
    }
    private struct NumberingKey: Equatable {
        let scope: String?
        let ids: [String]
    }

    /// Formal saved faces always belong to the currently verified board.
    private var location: FaceLibraryLocation { .board }
    private var isConnected: Bool { connection.connectionState == .connected }
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var confirmedFaces: [SavedFace] { libraryReady ? model.faces(in: .board) : [] }
    private var displayedFaces: [SavedFace] { orderDraft ?? confirmedFaces }
    private var isLoading: Bool { model.isLoading }
    private var libraryReady: Bool {
        isConnected && model.boardGeneration == connection.connectionGeneration
    }
    /// Display numbers are scoped to a verified physical board identity.
    private var currentScope: String? {
        guard let boardID = model.boardID ?? connection.boardKey else { return nil }
        return "board:\(boardID)"
    }
    private var canManage: Bool { libraryReady && !isWorking && !isLoading }
    private var canReorder: Bool {
        canManage && !isSearching && confirmedFaces.count > 1
    }

    private var editLibraryButton: some View {
        EditButton()
            .disabled(isWorking || isLoading || !libraryReady || isSearching || confirmedFaces.isEmpty)
            .accessibilityIdentifier("faces.editMode")
    }

    private var managementMenu: some View {
        Menu {
            Button("从旧本机库复制…", systemImage: "tray.and.arrow.up") {
                isMigratingLegacy = true
            }.disabled(!canManage)
            Button("导出全部", systemImage: "square.and.arrow.up") { exportAll() }
                .disabled(!libraryReady || confirmedFaces.isEmpty)
            Button("导入表情列表", systemImage: "square.and.arrow.down") {
                importLocation = location
                importGeneration = connection.connectionGeneration
                importCursor = currentCursor
                isImporting = true
            }.disabled(!canManage)
            Button("刷新", systemImage: "arrow.clockwise") {
                let source = location
                let link = connection
                perform { await refresh(source, connection: link) }
            }
            .disabled(!libraryReady)
        } label: { Label("更多", systemImage: "ellipsis.circle") }
        .disabled(isWorking || editMode.isEditing)
    }

    var body: some View {
        let all = displayedFaces
        let visible = all.filter(matchesSearch)
        // Rank comes from the entire displayed order, never the search subset.
        let ranks = Dictionary(all.enumerated().map { ($0.element.id, $0.offset + 1) },
                               uniquingKeysWith: { first, _ in first })
        List {
            if keepsActionsInMenu {
                Section {
                    TextField("搜索表情", text: $searchText)
                        .accessibilityIdentifier("faces.search")
                    editLibraryButton
                    managementMenu
                }
            }

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
            if visible.isEmpty && !isLoading && model.errorMessage == nil {
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
        .navigationTitle("板上表情")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(FaceLibrarySearchPlacement(text: $searchText, inMenu: keepsActionsInMenu))
        .toolbar {
            if !keepsActionsInMenu {
                MenuToolbarItem(placement: .primaryAction) { editLibraryButton }
                MenuToolbarItem(placement: .secondaryAction) { managementMenu }
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
                orderCursor = currentCursor
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
            guard isConnected else { dismiss(); return }
            if model.boardGeneration != connection.connectionGeneration {
                await model.reload(connection: connection)
            }
        }
        .onChange(of: isConnected) { _, connected in if !connected { dismiss() } }
        .onChange(of: connection.connectionGeneration) { _, _ in dismiss() }
        .sheet(isPresented: $isMigratingLegacy) {
            LegacyFaceMigrationView()
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
                guard valid(target.location, generation: target.generation), cursorStillCurrent(target.cursor) else { return changedBoardMessage }
                isWorking = true
                defer { isWorking = false }
                let succeeded = await model.rename(target.face, to: name, in: target.location, connection: connection)
                return succeeded ? nil : (model.errorMessage ?? failedMessage)
            }
        }
        .confirmationDialog("删除表情？", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible, presenting: deletion) { target in
            Button("删除", role: .destructive) {
                guard valid(target.location, generation: target.generation), cursorStillCurrent(target.cursor) else {
                    model.errorMessage = changedBoardMessage
                    return
                }
                let link = connection
                // An edit-mode delete ends/cancels the reorder draft first, so
                // Done never submits a permutation that still names a
                // just-deleted id.
                cancelOrder()
                perform {
                    guard cursorStillCurrent(target.cursor) else { model.errorMessage = changedBoardMessage; return }
                    _ = await model.delete(target.faces, from: target.location, connection: link)
                }
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
            guard valid(importLocation, generation: importGeneration), cursorStillCurrent(importCursor) else {
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
            let cursor = importCursor
            perform {
                guard cursorStillCurrent(cursor) else { model.errorMessage = changedBoardMessage; return }
                await model.importDocument(from: data, to: target, connection: link)
            }
        }
    }

    @ViewBuilder
    private func row(_ face: SavedFace, rank: Int) -> some View {
        let rowContent = HStack(spacing: 12) {
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
                    .accessibilityLabel(model.isProtected(face) ? Text("编辑副本") : Text("编辑"))
                    .disabled(!canManage || face.packedFrame == nil)
                Button { send(face) } label: { Image(systemName: "paperplane") }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("发送")
                    .disabled(!canManage || !isConnected || face.packedFrame == nil)
            }
        }
        Group {
            if editMode.isEditing {
                rowContent
            } else {
                // The row itself is never disabled as a whole when offline:
                rowContent.contextMenu {
                    if model.isProtected(face) {
                        Button("编辑副本", systemImage: "pencil") { edit(face) }
                            .disabled(!canManage || face.packedFrame == nil)
                    } else {
                        Button("编辑", systemImage: "pencil") { edit(face) }
                            .disabled(!canManage || face.packedFrame == nil)
                    }
                    Button("发送", systemImage: "paperplane") { send(face) }
                        .disabled(!canManage || !isConnected || face.packedFrame == nil)
                    if !model.isProtected(face) {
                        Button("重命名", systemImage: "character.cursor.ibeam") { rename(face) }
                            .disabled(!canManage)
                    }
                    Button("创建副本", systemImage: "plus.square.on.square") {
                        let source = location; let link = connection
                        perform { _ = await model.duplicate(face, from: source, connection: link) }
                    }.disabled(!canManage)
                    if model.canDelete(face) {
                        Divider()
                        Button("删除", systemImage: "trash", role: .destructive) { prepareDelete([face]) }
                            .disabled(!canManage)
                    }
                }
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
    private var currentCursor: BoardFaceSaveSource {
        BoardFaceSaveSource(boardID: connection.boardKey, generation: connection.connectionGeneration,
                            expectedBootId: connection.bootId, expectedGen: connection.currentFacesGeneration)
    }
    private func cursorStillCurrent(_ cursor: BoardFaceSaveSource?) -> Bool {
        guard let cursor else { return false }
        return cursor == currentCursor
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
        renaming = RenameTarget(face: face, location: location, generation: connection.connectionGeneration, cursor: currentCursor)
    }
    private func prepareDelete(_ faces: [SavedFace]) {
        guard canManage, !faces.isEmpty else { return }
        deletion = DeleteTarget(faces: faces, location: location, generation: connection.connectionGeneration, cursor: currentCursor)
        showDeleteConfirmation = true
    }
    private func cancelOrder() {
        orderDraft = nil; orderLocation = nil; orderGeneration = nil
        editMode = .inactive
    }
    private func commitOrder() {
        guard let draft = orderDraft, let source = orderLocation else { return }
        let generation = orderGeneration
        guard valid(source, generation: generation), cursorStillCurrent(orderCursor) else {
            cancelOrder(); model.errorMessage = changedBoardMessage; return
        }
        guard draft.map(\.id) != model.faces(in: source).map(\.id) else { cancelOrder(); return }
        // If another operation is already running, `perform` would silently
        // no-op and leave the drafted order on screen unwritten. Drop the
        // draft instead of showing an order that was never persisted.
        guard !isWorking else { orderDraft = nil; orderLocation = nil; orderGeneration = nil; return }
        let link = connection
        let cursor = orderCursor
        perform {
            guard cursorStillCurrent(cursor) else { cancelOrder(); model.errorMessage = changedBoardMessage; return }
            _ = await model.reorderFaces(draft, in: source, connection: link)
            // The model retains its confirmed order on failure. Clearing the
            // draft therefore rolls back the UI without an invented success.
            cancelOrder()
        }
    }
    private func refresh(_ source: FaceLibraryLocation, connection: BoardConnection) async {
        await model.reload(connection: connection)
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

private struct FaceLibrarySearchPlacement: ViewModifier {
    @Binding var text: String
    let inMenu: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if inMenu { content }
        else { content.searchable(text: $text, prompt: "搜索表情") }
    }
}


/// The legacy store is visible only through this explicit connected-board copy
/// flow. Its source snapshots remain intact regardless of cancellation/failure.
private struct LegacyFaceMigrationView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(FaceLibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var faces: [SavedFace] = []
    @State private var selected = Set<String>()
    @State private var target: BoardFaceSaveSource?
    @State private var loading = true
    @State private var copying = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("将选中的旧本机表情复制到当前面板。原文件会保留。")
                        .foregroundStyle(.secondary)
                }
                if loading { ProgressView() }
                if !loading && faces.isEmpty { Text("没有可复制的旧本机表情") }
                ForEach(faces) { face in
                    Button {
                        if !selected.insert(face.id).inserted { selected.remove(face.id) }
                    } label: {
                        HStack {
                            Text(face.name)
                            Spacer()
                            Image(systemName: selected.contains(face.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }.disabled(copying)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("复制旧本机表情")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(copying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("复制到当前面板") {
                        guard let target else { return }
                        copying = true
                        Task {
                            let result = await library.migrateLegacyFaces(
                                faces.filter { selected.contains($0.id) }, to: target, connection: connection)
                            message = library.operationMessage ?? library.errorMessage
                            selected.subtract(result.succeededIDs)
                            copying = false
                        }
                    }.disabled(copying || loading || selected.isEmpty)
                }
            }
            .task {
                target = BoardFaceSaveSource(boardID: connection.boardKey,
                                              generation: connection.connectionGeneration)
                faces = await library.legacyMigrationFaces()
                message = library.errorMessage
                loading = false
            }
            .onChange(of: connection.connectionState == .connected) { _, connected in
                if !connected { dismiss() }
            }
            .onChange(of: connection.connectionGeneration) { _, _ in dismiss() }
            .interactiveDismissDisabled(copying)
        }
    }
}
