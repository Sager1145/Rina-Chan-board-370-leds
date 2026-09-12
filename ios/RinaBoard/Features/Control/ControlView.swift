import SwiftUI
import RinaCore

/// Control tab (design guide §15, §16, §18, §19): the face/frame creation
/// surface. Board-global brightness, colour, prev/next, auto mode and saves
/// are deliberately absent — they belong to the Control Center (§63).
struct ControlView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(ControlViewModel.self) private var model
    @Environment(BoardControlCenterModel.self) private var controlCenter
    @Environment(FaceLibraryModel.self) private var faceLibrary
    @Environment(BootLoaderModel.self) private var bootLoader

    @AppStorage(AppSettingsKey.hapticsEnabled) private var hapticsEnabled = true

    @State private var toggleCount = 0
    @State private var isNamingSave = false
    @State private var saveNameDraft = ""

    private var isConnected: Bool { connection.connectionState == .connected }
    private var boardColor: Color { controlCenter.draftColor }
    private var boardBrightness: Int { controlCenter.draftBrightness }

    var body: some View {
        NavigationStack {
            List {
                previewSection
                commandSection
                partsSection
            }
            .toolbar(.hidden, for: .navigationBar)
            // No navigation bar, so the list's default top margin only pushes
            // the board away from the status bar.
            .contentMargins(.top, 0, for: .scrollContent)
            .alert("保存表情", isPresented: $isNamingSave) {
                TextField("名称", text: $saveNameDraft)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    Task {
                        model.saveName = saveNameDraft
                        let payload = model.upsertPayload(using: faceLibrary)
                        // Only record the save when the board actually took it;
                        // `.failed` leaves the editor's state untouched.
                        if case .saved(let id) = await faceLibrary.save(payload, connection: connection) {
                            model.didSave(as: id)
                        }
                    }
                }
            } message: {
                Text("保存到面板的表情库，可在控制中心中管理。")
            }
            .sensoryFeedback(.impact(weight: .light), trigger: toggleCount) { _, _ in hapticsEnabled }
        }
        .onAppear { bootLoader.beginWaterfall(count: 3) }
    }

    // MARK: §16 Interactive preview

    /// The one editable board in the app: `.editable` is what separates this
    /// preview from the read-only ones in Text, Live Video and Debug.
    private var previewSection: some View {
        Section {
            BoardPreviewRow(
                frame: model.draftFrame,
                interaction: .editable { led in
                    model.toggle(led: led, connection: connection)
                    toggleCount += 1
                },
                accessibilityDescription: previewAccessibilityDescription
            )
            .bootReveal(index: 0)
        } footer: {
            HStack {
                Text("\(model.draftFrame.litCount) / \(PackedFrame.ledCount) 点亮")
                Spacer()
                // Draft state is never shown as board-confirmed state (§37).
                if model.hasUnsentChanges {
                    Label("未发送", systemImage: "pencil.circle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .monospacedDigit()
        }
    }

    private var previewAccessibilityDescription: String {
        String(format: NSLocalizedString("面板编辑器，%1$lld/%2$lld 颗 LED 点亮",
                                         comment: "editable board preview accessibility summary"),
               model.draftFrame.litCount, PackedFrame.ledCount)
    }

    // MARK: §18 Command section

    /// Every editor command lives in one section (§18): the primary send
    /// action, the two persistent modes as button-style toggles, the frame
    /// operations, and the save actions. Nothing is hidden behind a toolbar
    /// menu any more.
    private var commandSection: some View {
        Section {
            HStack(spacing: 8) {
                Toggle(isOn: Bindable(model).livePreview) {
                    CommandChip("实时预览", systemImage: "livephoto")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)

                Button {
                    model.randomizeParts(connection: connection)
                    toggleCount += 1
                } label: {
                    CommandChip("随机", systemImage: "dice.fill")
                }
                .buttonStyle(.bordered)

                Toggle(isOn: Binding(
                    get: { model.syncEyes },
                    set: { model.setSyncEyes($0, connection: connection) }
                )) {
                    CommandChip("同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .disabled(!model.canSyncEyes)

                Button {
                    saveNameDraft = model.saveName
                    isNamingSave = true
                } label: {
                    CommandChip("保存", systemImage: "square.and.arrow.down.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!isConnected)
            }

            HStack(spacing: 8) {
                Button {
                    model.clear(connection: connection)
                } label: {
                    CommandChip("清空", systemImage: "eraser.fill")
                }

                Button {
                    model.fill(connection: connection)
                } label: {
                    CommandChip("全亮", systemImage: "sun.max.fill")
                }

                Button {
                    model.invert(connection: connection)
                } label: {
                    CommandChip("反转", systemImage: "circle.lefthalf.filled")
                }

                Button {
                    model.revertToBaseline(connection: connection)
                } label: {
                    CommandChip("回退", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canRevert)
            }
            .buttonStyle(.bordered)

            if model.editingFaceId != nil {
                Button {
                    model.startNewFace()
                } label: {
                    CommandChip("另存为新表情", systemImage: "doc.on.doc.fill")
                }
                .buttonStyle(.bordered)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("命令")
        } footer: {
            if !model.canSyncEyes {
                Text("当前部件数据与左右眼映射不一致，已停用逐灯同步。")
            } else if !model.livePreview {
                Text("实时预览已关闭，修改仅保存在本地，点击面板控制栏最右侧的「发送」才会写入。")
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .bootReveal(index: 1)
    }

    // MARK: §19 Face parts

    @ViewBuilder
    private var partsSection: some View {
        if let library = model.library {
            ForEach(PartGroup.allCases, id: \.self) { group in
                Section(group.displayName) {
                    FacePartSelectorView(
                        group: group,
                        library: library,
                        selectedId: model.selectedCall[group],
                        color: boardColor,
                        brightness: boardBrightness
                    ) { id in
                        model.selectPart(group: group, id: id, connection: connection)
                        toggleCount += 1
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
                }
            }
            .bootReveal(index: 2)
        } else {
            Section {
                ContentUnavailableView("部件库不可用",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(model.loadError ?? ""))
            }
            // Same slot in the waterfall as the library it stands in for.
            .bootReveal(index: 2)
        }
    }
}

/// Horizontal icon + title label used by every command control (§18), kept flat
/// so four chips share one row without clipping at larger Dynamic Type sizes.
private struct CommandChip: View {
    static let minHeight: CGFloat = 22

    private let title: LocalizedStringKey
    private let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight)
        .contentShape(Capsule())
        .accessibilityLabel(Text(title))
    }
}
