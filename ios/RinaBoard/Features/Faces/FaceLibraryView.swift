import SwiftUI
import UniformTypeIdentifiers
import RinaCore

/// Full saved-face management (design guide §11): the complete list with
/// rename, edit, delete, drag reorder and whole-document import/export.
///
/// Presets and user faces share one list in board order; each row's caption
/// says which it is. Native list semantics throughout — rows are `List` rows
/// with swipe actions and a context menu, not website-style cards. Presented
/// as a bottom sheet from the Control tab's「保存列表」button.
struct FaceLibraryView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(FaceLibraryModel.self) private var model
    @Environment(ControlViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: JSONFileDocument?

    /// With no board connected there is nothing to read from — DEF-07 fell
    /// back to an empty board document forever. The device-local library
    /// (`FaceLibraryModel.localDocument`) exists precisely for this case, so
    /// pick it whenever the board isn't actually reachable.
    private var location: FaceLibraryLocation {
        connection.connectionState == .connected ? .board : .local
    }

    /// Loading flag for whichever library is on screen — `model.isLoading`
    /// only tracks the board fetch, so the local branch needs its own flag
    /// to avoid a spurious "暂无" flash while `loadLocalIfNeeded()` is
    /// still running.
    private var isLoadingCurrent: Bool {
        location == .local ? (model.isLocalLoading || !model.isLocalLoaded) : model.isLoading
    }

    var body: some View {
        // Reads the cached sort (`FaceLibraryModel.faces(in:)`) instead of
        // `model.faceDocument.sortedFaces`, which would re-sort on every body
        // pass — this is the actual hot list the cache exists to speed up.
        let faces = model.faces(in: location)
        List {
            Section {
                if faces.isEmpty && !isLoadingCurrent {
                    Text("暂无").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(faces) { face in
                    row(for: face)
                        .deleteDisabled(!model.canDelete(face))
                }
                .onDelete { offsets in
                    let doomed = offsets.map { faces[$0] }.filter(model.canDelete)
                    Task {
                        for face in doomed {
                            await model.delete(face, from: location, connection: connection)
                        }
                    }
                }
                .onMove { source, destination in
                    var reordered = faces
                    reordered.move(fromOffsets: source, toOffset: destination)
                    Task {
                        switch location {
                        case .board:
                            await model.reorderFaces(reordered, connection: connection)
                        case .local:
                            let userOrder = reordered.filter { $0.type != .default }
                            await model.reorderUserFaces(userOrder, in: .local, connection: connection)
                        }
                    }
                }
            } header: {
                Text(location.title)
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("表情库")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .task(id: location) {
            if location == .local {
                await model.loadLocalIfNeeded()
            }
        }
        .refreshable { await model.reload(connection: connection) }
        .overlay {
            if isLoadingCurrent && faces.isEmpty {
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
                    exportDocument = JSONFileDocument(data: model.exportData(faces: faces, from: location) ?? Data())
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
            guard let data = try? Data(contentsOf: url) else { return }
            Task { await model.importDocument(from: data, to: location, connection: connection) }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { model.renamingFace != nil },
                set: { if !$0 { model.renamingFace = nil } })
    }

    @ViewBuilder
    private func row(for face: SavedFace) -> some View {
        Button {
            guard !isEditing, location == .board else { return }
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
        .disabled(location != .board)
        .contextMenu {
            Button("编辑", systemImage: "pencil") {
                editor.loadForEditing(face)
                dismiss()
            }
            Button("重命名", systemImage: "character.cursor.ibeam") {
                model.renamingFace = face
                model.renameText = face.name
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
