import SwiftUI
import UniformTypeIdentifiers
import RinaCore

/// B10/B11: the saved-face library list (defaults + user faces), with rename,
/// edit, delete, drag-reorder and whole-document import/export.
struct FaceLibraryView: View {
    @Bindable var viewModel: FacesViewModel
    var connection: BoardConnection

    @State private var isEditing = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: JSONFileDocument?

    private var defaults: [SavedFace] { viewModel.faceDocument.sortedFaces.filter { $0.type == .default } }
    private var userFaces: [SavedFace] { viewModel.faceDocument.sortedFaces.filter { $0.type != .default } }

    var body: some View {
        List {
            Section("默认表情") {
                if defaults.isEmpty {
                    Text("暂无").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(defaults) { face in row(for: face) }
            }
            Section("我的表情") {
                if userFaces.isEmpty {
                    Text("暂无").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(userFaces) { face in row(for: face) }
                    .onDelete { offsets in
                        Task {
                            for face in offsets.map({ userFaces[$0] }) {
                                await viewModel.delete(face, connection: connection)
                            }
                        }
                    }
                    .onMove { source, destination in
                        var reordered = userFaces
                        reordered.move(fromOffsets: source, toOffset: destination)
                        Task { await viewModel.reorderUserFaces(reordered, connection: connection) }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .refreshable { await viewModel.reloadLibrary(connection: connection) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "完成" : "排序") { isEditing.toggle() }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button("导出全部") {
                        exportDocument = JSONFileDocument(data: viewModel.exportData() ?? Data())
                        isExporting = true
                    }
                    Button("导入表情列表") { isImporting = true }
                    Button("刷新") { Task { await viewModel.reloadLibrary(connection: connection) } }
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
            }
        }
        .alert("重命名", isPresented: renameBinding, presenting: viewModel.renamingFace) { face in
            TextField("名称", text: $viewModel.renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                Task { await viewModel.rename(face, to: viewModel.renameText, connection: connection) }
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json, defaultFilename: "saved_faces") { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { await viewModel.importDocument(from: data, connection: connection) }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { viewModel.renamingFace != nil }, set: { if !$0 { viewModel.renamingFace = nil } })
    }

    @ViewBuilder
    private func row(for face: SavedFace) -> some View {
        Button {
            Task { await viewModel.apply(face, connection: connection) }
        } label: {
            HStack(spacing: 12) {
                if let frame = face.packedFrame {
                    LEDMatrixView(frame: frame, showBoardImage: false)
                        .frame(width: 44, height: 36)
                } else {
                    Color.gray.opacity(0.2).frame(width: 44, height: 36)
                }
                VStack(alignment: .leading) {
                    Text(face.name)
                    HStack(spacing: 6) {
                        Text(badgeLabel(face.type)).font(.caption2).foregroundStyle(.secondary)
                        Text("序号 \(face.order)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button("编辑") { viewModel.loadForEditing(face) }
                    Button("重命名") { viewModel.renamingFace = face; viewModel.renameText = face.name }
                    if face.type != .default {
                        Button("删除", role: .destructive) {
                            Task { await viewModel.delete(face, connection: connection) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if face.type != .default {
                Button("删除", role: .destructive) {
                    Task { await viewModel.delete(face, connection: connection) }
                }
            }
            Button("重命名") { viewModel.renamingFace = face; viewModel.renameText = face.name }
                .tint(.blue)
        }
    }

    private func badgeLabel(_ type: SavedFace.Kind) -> String {
        switch type {
        case .default: return "默认"
        case .custom: return "自定义"
        case .parts: return "部件"
        }
    }
}

/// Whole-document JSON file for `.fileExporter` (B11).
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
