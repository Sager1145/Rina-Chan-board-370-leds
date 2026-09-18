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
/// not website-style cards. Presented as a bottom sheet from the Control
/// tab's「保存列表」button.
struct FaceLibraryView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(FaceLibraryModel.self) private var model
    @Environment(ControlViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: JSONFileDocument?
    @State private var searchText = ""

    /// "Which library is on screen" as one piece of state: `nil` means the
    /// user hasn't picked yet, so it follows the connection (board while
    /// connected, local otherwise). Once the user touches the picker their
    /// choice sticks for the life of the sheet, independent of connection
    /// changes.
    @State private var pickedLocation: FaceLibraryLocation?

    private var location: FaceLibraryLocation {
        pickedLocation ?? (connection.connectionState == .connected ? .board : .local)
    }

    private var otherLocation: FaceLibraryLocation {
        location == .board ? .local : .board
    }

    /// Loading flag for whichever library is on screen — `model.isLoading`
    /// only tracks the board fetch, so the local branch needs its own flag
    /// to avoid a spurious "暂无" flash while `loadLocalIfNeeded()` is
    /// still running.
    private var isLoadingCurrent: Bool {
        location == .local ? (model.isLocalLoading || !model.isLocalLoaded) : model.isLoading
    }

    /// Applying a face to the board only ever makes sense for the board's
    /// own library, and only while actually connected to one.
    private var canApplyToBoard: Bool {
        location == .board && connection.connectionState == .connected
    }

    /// Proof (not a guess) that the current library actually finished a
    /// successful load: the local one has completed its one-time load with
    /// no error, or the board one was read for the connection generation
    /// that is still current while actually connected.
    private var isEmptyLibraryConfirmed: Bool {
        guard model.errorMessage == nil else { return false }
        if location == .local { return model.isLocalLoaded }
        return connection.connectionState == .connected
            && model.boardGeneration == connection.connectionGeneration
    }

    private func matchesSearch(_ face: SavedFace) -> Bool {
        searchText.isEmpty || face.name.localizedCaseInsensitiveContains(searchText)
    }

    var body: some View {
        // Reads the cached sort (`FaceLibraryModel.faces(in:)`) instead of
        // `model.faceDocument.sortedFaces`, which would re-sort on every body
        // pass — this is the actual hot list the cache exists to speed up.
        let allFaces = model.faces(in: location)
        let defaults = allFaces.filter { $0.type == .default && matchesSearch($0) }
        let users = allFaces.filter { $0.type != .default && matchesSearch($0) }
        List {
            Picker("库", selection: pickerBinding) {
                ForEach(FaceLibraryLocation.allCases) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if allFaces.isEmpty && !isLoadingCurrent {
                Text("暂无").font(.footnote).foregroundStyle(.secondary)
                // Only once the library has actually finished loading
                // successfully and come back empty: never while loading
                // (guarded above), never after a load error, and never for
                // the board library while disconnected (nothing was loaded).
                if isEmptyLibraryConfirmed {
                    Text("这里还没有表情。一起做一个吧。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if !defaults.isEmpty {
                Section("默认表情") {
                    ForEach(defaults) { face in
                        row(for: face)
                            .deleteDisabled(!model.canDelete(face))
                    }
                }
            }
            if !users.isEmpty {
                Section("我的表情") {
                    ForEach(users) { face in
                        row(for: face)
                            .deleteDisabled(!model.canDelete(face))
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { users[$0] }.filter(model.canDelete)
                        Task {
                            for face in doomed {
                                await model.delete(face, from: location, connection: connection)
                            }
                        }
                    }
                    .onMove { source, destination in
                        var reordered = users
                        reordered.move(fromOffsets: source, toOffset: destination)
                        Task { await model.reorderUserFaces(reordered, in: location, connection: connection) }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("表情库")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索表情")
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .task(id: location) {
            if location == .local {
                await model.loadLocalIfNeeded()
            }
        }
        .refreshable { await model.reload(connection: connection) }
        .overlay {
            if isLoadingCurrent && allFaces.isEmpty {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "完成" : "编辑") {
                    withAnimation { isEditing.toggle() }
                }
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("导出全部", systemImage: "square.and.arrow.up") {
                    exportDocument = JSONFileDocument(data: model.exportData(faces: allFaces, from: location) ?? Data())
                    isExporting = true
                }
                Button("导入表情列表", systemImage: "square.and.arrow.down") { isImporting = true }
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.reload(connection: connection) }
                }
            }
        }
        .alert("重命名", isPresented: renameBinding, presenting: model.renamingFace) { face in
            TextField("名称", text: Bindable(model).renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                Task { await model.rename(face, to: model.renameText, in: location, connection: connection) }
            }
        }
        .fileExporter(isPresented: $isExporting,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: "saved_faces") { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.reportImportUnreadable()
                return
            }
            Task { await model.importDocument(from: data, to: location, connection: connection) }
        }
    }

    private var pickerBinding: Binding<FaceLibraryLocation> {
        Binding(get: { location }, set: { pickedLocation = $0 })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { model.renamingFace != nil },
                set: { if !$0 { model.renamingFace = nil } })
    }

    @ViewBuilder
    private func row(for face: SavedFace) -> some View {
        Button {
            guard !isEditing, canApplyToBoard else { return }
            Task { await model.apply(face, connection: connection) }
        } label: {
            HStack(spacing: 12) {
                if let frame = face.packedFrame {
                    SavedFaceThumbnail(frame: frame, accessibilityDescription: "")
                } else {
                    Color.gray.opacity(0.2)
                        .frame(width: SavedFaceThumbnail.size.width, height: SavedFaceThumbnail.size.height)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(face.name)
                    HStack(spacing: 6) {
                        Text(face.type == .default ? "预设" : "我的表情")
                        if face.type == .parts {
                            Text("部件")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canApplyToBoard)
        .contextMenu {
            Button("编辑", systemImage: "pencil") {
                editor.loadForEditing(face)
                dismiss()
            }
            Button("重命名", systemImage: "character.cursor.ibeam") {
                model.renamingFace = face
                model.renameText = face.name
            }
            Button("复制到\(otherLocation.title)", systemImage: "arrow.turn.up.right") {
                Task { await model.copy(face, from: location, to: otherLocation, connection: connection) }
            }
            if model.canDelete(face) {
                Button("删除", systemImage: "trash", role: .destructive) {
                    Task { await model.delete(face, from: location, connection: connection) }
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if model.canDelete(face) {
                Button("删除", role: .destructive) {
                    Task { await model.delete(face, from: location, connection: connection) }
                }
            }
            Button("重命名") {
                model.renamingFace = face
                model.renameText = face.name
            }
            .tint(.blue)
        }
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
