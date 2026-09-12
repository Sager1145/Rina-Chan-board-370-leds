import SwiftUI
import UniformTypeIdentifiers
import RinaCore

/// Full saved-face management (design guide §11): the complete list with
/// rename, edit, delete, drag reorder and whole-document import/export.
///
/// Native list semantics throughout — rows are `List` rows with swipe actions
/// and a context menu, not website-style cards. Pushed from the Control
/// Center's Saves section.
struct FaceLibraryView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(FaceLibraryModel.self) private var model
    @Environment(ControlViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: JSONFileDocument?

    var body: some View {
        List {
            Section("默认表情") {
                if model.defaultFaces.isEmpty {
                    Text("暂无").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.defaultFaces) { face in row(for: face) }
            }
            Section("我的表情") {
                if model.userFaces.isEmpty {
                    Text("暂无").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.userFaces) { face in row(for: face) }
                    .onDelete { offsets in
                        let doomed = offsets.map { model.userFaces[$0] }
                        Task {
                            for face in doomed {
                                await model.delete(face, connection: connection)
                            }
                        }
                    }
                    .onMove { source, destination in
                        var reordered = model.userFaces
                        reordered.move(fromOffsets: source, toOffset: destination)
                        Task { await model.reorderUserFaces(reordered, connection: connection) }
                    }
            }
        }
        .navigationTitle("表情库")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .refreshable { await model.reload(connection: connection) }
        .overlay {
            if model.isLoading && model.faceDocument.faces.isEmpty {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "完成" : "排序") { isEditing.toggle() }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button("导出全部", systemImage: "square.and.arrow.up") {
                        exportDocument = JSONFileDocument(data: model.exportData() ?? Data())
                        isExporting = true
                    }
                    Button("导入表情列表", systemImage: "square.and.arrow.down") { isImporting = true }
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task { await model.reload(connection: connection) }
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("重命名", isPresented: renameBinding, presenting: model.renamingFace) { face in
            TextField("名称", text: Bindable(model).renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                Task { await model.rename(face, to: model.renameText, connection: connection) }
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
            Task { await model.importDocument(from: data, connection: connection) }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { model.renamingFace != nil },
                set: { if !$0 { model.renamingFace = nil } })
    }

    @ViewBuilder
    private func row(for face: SavedFace) -> some View {
        Button {
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
                        Text(badgeLabel(face.type))
                        Text("序号 \(face.order)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("编辑", systemImage: "pencil") {
                editor.loadForEditing(face)
                dismiss()
            }
            Button("重命名", systemImage: "character.cursor.ibeam") {
                model.renamingFace = face
                model.renameText = face.name
            }
            if face.type != .default {
                Button("删除", systemImage: "trash", role: .destructive) {
                    Task { await model.delete(face, connection: connection) }
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if face.type != .default {
                Button("删除", role: .destructive) {
                    Task { await model.delete(face, connection: connection) }
                }
            }
            Button("重命名") {
                model.renamingFace = face
                model.renameText = face.name
            }
            .tint(.blue)
        }
    }

    private func badgeLabel(_ type: SavedFace.Kind) -> String {
        switch type {
        case .default: return NSLocalizedString("默认", comment: "saved face kind default")
        case .custom: return NSLocalizedString("自定义", comment: "saved face kind custom")
        case .parts: return NSLocalizedString("部件", comment: "saved face kind parts")
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
