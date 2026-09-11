import SwiftUI
import RinaCore

/// Faces tab (FEATURE_INVENTORY §B): custom pixel editor, parts composer and
/// face library, behind a segmented picker.
struct FacesView: View {
    @Environment(BoardConnection.self) private var connection
    @State private var viewModel = FacesViewModel()
    @State private var tab = Tab.editor

    private enum Tab: String, CaseIterable {
        case editor, parts, library

        var label: String {
            switch self {
            case .editor: return "画板"
            case .parts: return "部件"
            case .library: return "表情库"
            }
        }
    }

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }
                Picker("模式", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                switch tab {
                case .editor, .parts:
                    ScrollView {
                        VStack(spacing: 16) {
                            if tab == .editor { editorSection } else { partsSection }
                        }
                        .padding()
                    }
                case .library:
                    FaceLibraryView(viewModel: viewModel, connection: connection)
                }
            }
            .navigationTitle("表情")
            .task { await viewModel.reloadLibrary(connection: connection) }
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
        }
        .font(.footnote)
        .padding(10)
        .background(Color.red.opacity(0.15))
        .foregroundStyle(.red)
    }

    // MARK: 画板 (pixel editor)

    @ViewBuilder
    private var editorSection: some View {
        card {
            LEDMatrixView(frame: viewModel.editFrame, onToggle: { led in
                viewModel.toggle(led, connection: connection)
            })
            .frame(maxWidth: .infinity)

            HStack {
                Button("清空") { viewModel.clearAll(connection: connection) }
                Button("全亮") { viewModel.fillAll(connection: connection) }
                Button("反转") { viewModel.invertAll(connection: connection) }
                Spacer()
            }
            .buttonStyle(.bordered)

            Toggle("实时发送", isOn: $viewModel.liveMode)

            Button {
                Task { await viewModel.sendFrame(connection: connection) }
            } label: {
                Text("发送到面板").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isConnected)
        }

        card {
            Text("Packed Frame (94位十六进制)").font(.subheadline).foregroundStyle(.secondary)
            Text(viewModel.hex94)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)

            HStack {
                Button("复制") { viewModel.copyHex() }
                Spacer()
            }
            .buttonStyle(.bordered)

            Text("从文本导入 (94位十六进制 / 47整数JSON数组 / base64)").font(.footnote).foregroundStyle(.secondary)
            TextField("粘贴帧数据…", text: $viewModel.importText, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)
            Button("从文本导入") {
                viewModel.importFrame(from: viewModel.importText, connection: connection)
            }
            .buttonStyle(.bordered)
        }

        saveCard
    }

    // MARK: 部件 (parts composer)

    @ViewBuilder
    private var partsSection: some View {
        if let library = viewModel.library {
            card {
                LEDMatrixView(frame: viewModel.editFrame, onToggle: { led in
                    viewModel.toggle(led, connection: connection)
                })
                .frame(maxWidth: .infinity)
            }

            ForEach(PartGroup.allCases, id: \.self) { group in
                card {
                    Text(group.displayName).font(.headline)
                    partRow(group: group, library: library)
                }
            }

            card {
                Toggle("左右眼对称", isOn: $viewModel.symmetryOn)
                HStack {
                    Button("随机") { viewModel.randomize(connection: connection) }
                    Button("默认") { viewModel.resetToDefault(connection: connection) }
                    Button("回退修改") { viewModel.revertEdit(connection: connection) }
                    Spacer()
                }
                .buttonStyle(.bordered)
                Toggle("实时发送", isOn: $viewModel.liveMode)
                Button {
                    Task { await viewModel.sendFrame(connection: connection) }
                } label: {
                    Text("发送到面板").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected)
            }

            saveCard
        } else {
            card {
                Text(viewModel.loadError ?? "部件库加载失败").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func partRow(group: PartGroup, library: PartsLibrary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(library.ids(for: group), id: \.self) { id in
                    let part = library.resolvedPart(group: group, id: id)
                    let selected = viewModel.selectedCall[group] == id
                    Button {
                        viewModel.selectPart(group: group, id: id, connection: connection)
                    } label: {
                        LEDMatrixView(frame: library.frame(for: part), showBoardImage: false)
                            .frame(width: 56, height: 46)
                            .padding(4)
                            .background(selected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
                            )
                    }
                }
            }
        }
    }

    // MARK: Save card (shared by 画板/部件)

    @ViewBuilder
    private var saveCard: some View {
        card {
            Text(viewModel.editingFaceId == nil ? "保存为新表情" : "更新表情").font(.headline)
            TextField("表情名称", text: $viewModel.saveName)
            HStack {
                if viewModel.editingFaceId != nil {
                    Button("另存为新表情") { viewModel.startNewFace() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button {
                    Task { await viewModel.save(connection: connection) }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Text("保存")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected || viewModel.isSaving)
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    FacesView()
        .environment(BoardConnection())
}
