import SwiftUI
import RinaCore

/// Control tab (design guide §15, §16, §18, §19): the face/frame creation
/// surface, including sending the draft and the saved-face list. Board-global
/// brightness, colour, prev/next and auto mode are deliberately absent — they
/// belong to the Control Center (§63).
struct ControlView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BoardConnection.self) private var connection
    @Environment(ControlViewModel.self) private var model
    @Environment(BoardControlCenterModel.self) private var controlCenter
    @Environment(FaceLibraryModel.self) private var faceLibrary
    @Environment(BootLoaderModel.self) private var bootLoader

    @AppStorage(AppSettingsKey.hapticsEnabled) private var hapticsEnabled = true

    @State private var toggleCount = 0
    /// True while a finger is on the board. The list stands down for that
    /// stretch: on this tab a single finger on the board paints or holds it,
    /// never scrolls the page — only the commands and parts below scroll
    /// (§16).
    @State private var isTouchingBoard = false
    @State private var isNamingSave = false
    @State private var saveNameDraft = ""
    @State private var isChoosingSaveTarget = false
    /// Set by the save-target dialog; applied only when the naming sheet is
    /// confirmed, so cancelling leaves the editor's save target untouched.
    @State private var savesAsNew = false
    @State private var isShowingSavedFaces = false
    /// The destination and identity are frozen the moment the naming sheet
    /// opens (Control §11.3): a reconnect or a board switch while it is open
    /// must not silently redirect an in-progress save.
    @State private var saveLocation: FaceLibraryLocation = .local
    @State private var saveFrame = PackedFrame()
    @State private var saveFaceID: String?
    @State private var saveBoardSource: BoardFaceSaveSource?

    private var isConnected: Bool { connection.connectionState == .connected }
    /// Names the save sheet's destination (DEF-05) so a title alone tells the
    /// user where the face is going, reusing `FaceLibraryLocation`'s own
    /// wording instead of inventing new terms for the same two places. Uses
    /// the frozen `saveLocation`, not the live connection state, so the title
    /// never disagrees with where the sheet is actually about to save.
    private var saveDestinationTitle: String {
        String(format: NSLocalizedString("保存到%@", comment: "save alert title naming its destination"),
               saveLocation.title)
    }
    private var boardColor: Color { controlCenter.draftColor }
    private var boardBrightness: Int { controlCenter.draftBrightness }

    var body: some View {
        NavigationStack {
            BoardSplitPage {
                previewBoard
            } status: {
                previewStatus
            } controls: {
                commandSection
                partsSection
            }
            .listSectionSpacing(.compact)
            .rinaScrollBackground()
            .scrollDisabled(isTouchingBoard)
            // Every finger up ends the drag stroke, so the next one is its
            // own undo step.
            .onChange(of: isTouchingBoard) { _, touching in
                if !touching { model.endStroke() }
            }
            // A pencil held still over the board sends no hover events, so
            // anything that changes whether (or where) the board mirrors it
            // re-decides here: 即时预览, the drawing 镜像 (which adds or drops
            // the mirrored LED), another feature taking the output, or a
            // switch to another board.
            .onChange(of: model.livePreview) { _, _ in
                model.syncBoardHint(connection: connection)
            }
            .onChange(of: model.mirrorDrawing) { _, _ in
                model.syncBoardHint(connection: connection)
            }
            .onChange(of: connection.output.source) { _, _ in
                model.syncBoardHint(connection: connection)
            }
            .onChange(of: ObjectIdentifier(connection)) { _, _ in
                model.syncBoardHint(connection: connection)
            }
            .toolbar(.hidden, for: .navigationBar)
            // No navigation bar, so the list's default top margin only pushes
            // the board away from the status bar.
            .contentMargins(.top, 0, for: .scrollContent)
            .sheet(isPresented: $isNamingSave) {
                FaceNameEditorSheet(title: saveDestinationTitle, initialName: saveNameDraft) { name in
                    guard model.draftFrame == saveFrame, model.editingFaceId == saveFaceID else {
                        return NSLocalizedString("编辑内容已改变，请关闭后重新保存", comment: "face changed while naming")
                    }
                    let success = await model.saveEditedFace(
                        name: name, asNew: savesAsNew, to: saveLocation,
                        library: faceLibrary, connection: connection, expectedBoard: saveBoardSource
                    )
                    return success ? nil : (faceLibrary.errorMessage
                        ?? NSLocalizedString("保存失败，请重试", comment: "save face failed"))
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: toggleCount) { _, _ in hapticsEnabled }
            .sheet(isPresented: $isShowingSavedFaces) { savedFacesSheet }
        }
        .errorAlert(Bindable(model).errorMessage)
        .onAppear { bootLoader.beginWaterfall(count: 3) }
        .task(id: isConnected && scenePhase == .active ? connection.connectionGeneration : nil) {
            guard isConnected, scenePhase == .active else { return }
            await model.runDisplayRefreshLoop(connection: connection)
        }
    }

    // MARK: §16 Interactive preview

    /// The one editable board in the app: `.editable` is what separates this
    /// preview from the read-only ones in Text, Live Video and Debug.
    ///
    /// A tap toggles the LED under it. A drag paints the brush's value
    /// (§18.5) instead, so the finger can light or clear a whole run of LEDs
    /// in one stroke; the brush toggle has no say over taps.
    @ViewBuilder
    private var previewBoard: some View {
        BoardPreviewRow(
            frame: model.draftFrame,
            interaction: .editable(
                onTap: { led in
                    model.toggle(led: led, connection: connection)
                    toggleCount += 1
                },
                onDrag: { led in
                    // Only a real change is worth a haptic: a stroke that
                    // runs over cells already in the brush's state must
                    // stay silent.
                    if model.paint(led: led, connection: connection) {
                        toggleCount += 1
                    }
                },
                onPencilHover: { led in
                    model.pencilHover(led: led, connection: connection)
                },
                pencilHoverMirror: { led in model.pencilHoverMirror(of: led) }
            ),
            zoom: .pinchable(isTouching: $isTouchingBoard),
            accessibilityDescription: previewAccessibilityDescription
        )
        .bootReveal(index: 0)
    }

    /// Draft state is never shown as board-confirmed state (§37), so an
    /// unsent draft wins over every other state.
    @ViewBuilder
    private var previewStatus: some View {
        let litCount = Text("点亮 \(model.draftFrame.litCount) / \(PackedFrame.ledCount)")
        VStack(alignment: .leading, spacing: 4) {
            if model.hasUnsentChanges {
                BoardPreviewStatus("未发送", systemImage: "pencil.circle", tone: .pending) { litCount }
            } else if !isConnected {
                BoardPreviewStatus("未连接", systemImage: "circle.slash", tone: .neutral) { litCount }
            } else if let source = connection.output.source, source != .manual {
                // Identify the feature whose current frame the preview follows.
                BoardOwnerStatus(source: source)
            } else {
                BoardPreviewStatus("已同步", systemImage: "checkmark.circle", tone: .live) { litCount }
            }
            // A caption for the empty-canvas / new-face state only: a fresh
            // editor that has never been assigned a saved-face identity and
            // has nothing drawn on it yet.
            if model.editingFaceId == nil, model.draftFrame.litCount == 0 {
                Text("在面板上点按或拖动即可绘制表情")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let confirmation = model.sendConfirmationMessage {
                Text(confirmation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewAccessibilityDescription: String {
        String(format: NSLocalizedString("面板编辑器，%1$lld/%2$lld 颗 LED 点亮",
                                         comment: "editable board preview accessibility summary"),
               model.draftFrame.litCount, PackedFrame.ledCount)
    }

    // MARK: §18 Command section

    /// Editor commands (§18), one section per row: the untitled send /
    /// saved-list / save row, part selection (live preview, random, eye sync)
    /// and manual drawing (clear, the brush that decides whether a touch on
    /// the board lights or clears, invert, undo). Nothing is hidden behind a
    /// toolbar menu any more.
    private var commandSection: some View {
        Group {
            fileCommandSection
            partCommandSection
            drawingCommandSection
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .bootReveal(index: 1)
    }

    @ViewBuilder
    private var fileCommandSection: some View {
        Section {
            HStack(spacing: 8) {
                Button {
                    Task { await model.send(connection: connection) }
                } label: {
                    CommandChip("发送", systemImage: "paperplane.fill")
                }
                .disabled(!isConnected || model.isSending)

                Button {
                    isShowingSavedFaces = true
                } label: {
                    CommandChip("保存列表", systemImage: "list.bullet.rectangle")
                }

                Button {
                    beginSave()
                } label: {
                    CommandChip("保存", systemImage: "square.and.arrow.down.fill")
                }
                .confirmationDialog("保存表情", isPresented: $isChoosingSaveTarget) {
                    Button("覆盖原表情") { beginNaming(asNew: false) }
                    Button("另存为新表情") { beginNaming(asNew: true) }
                    Button("取消", role: .cancel) {}
                }
            }
            .buttonStyle(.pill)
            .pillButtonRow()
        }
    }

    private var partCommandSection: some View {
        Section {
            HStack(spacing: 8) {
                Toggle(isOn: Bindable(model).livePreview) {
                    CommandChip("实时预览", systemImage: "livephoto")
                }
                .toggleStyle(.pill)

                Button {
                    model.randomizeParts(connection: connection)
                    toggleCount += 1
                } label: {
                    CommandChip("随机", systemImage: "dice.fill")
                }
                .buttonStyle(.pill)

                Toggle(isOn: Binding(
                    get: { model.syncEyes },
                    set: { model.setSyncEyes($0, connection: connection) }
                )) {
                    CommandChip("镜像", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .toggleStyle(.pill)
                .disabled(!model.canSyncEyes)
                .accessibilityHint(Text("选择一侧眼睛部件时，另一侧自动使用对称部件"))
            }
            .pillButtonRow()
        } header: {
            Text("部件选择")
        }
    }

    private var drawingCommandSection: some View {
        Section {
            HStack(spacing: 8) {
                Button {
                    model.clear(connection: connection)
                } label: {
                    CommandChip("清空", systemImage: "eraser.fill")
                }

                Toggle(isOn: Bindable(model).brushOn) {
                    CommandChip(model.brushOn ? "绘制" : "擦除",
                                systemImage: model.brushOn ? "lightbulb.fill" : "lightbulb.slash.fill")
                }
                .toggleStyle(.pill)

                Toggle(isOn: Bindable(model).mirrorDrawing) {
                    CommandChip("镜像", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .toggleStyle(.pill)
                .accessibilityHint(Text("绘制和擦除时，同时修改左右对称位置的 LED"))

                Button {
                    model.invert(connection: connection)
                } label: {
                    CommandChip("反转", systemImage: "circle.lefthalf.filled")
                }

                Button {
                    model.undo(connection: connection)
                } label: {
                    CommandChip("撤销", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
            }
            .buttonStyle(.pill)
            .pillButtonRow()
        } header: {
            Text("手动绘画")
        }
    }

    // MARK: §11 Saved faces

    /// The full saved-face list with its edit tools (reorder, rename, delete,
    /// import/export), as a bottom sheet over the editor. Choosing「编辑」on a
    /// row loads it into the editor and closes the sheet.
    private var savedFacesSheet: some View {
        NavigationStack {
            FaceLibraryView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", systemImage: "xmark") { isShowingSavedFaces = false }
                    }
                }
        }
        .presentationDetents([.medium, .rinaTall])
        .task {
            if faceLibrary.faceDocument.faces.isEmpty {
                await faceLibrary.reload(connection: connection)
            }
        }
    }

    /// Overwrite vs. save-as is decided here, after the tap: only offered
    /// when the edited face can actually be overwritten, and — when its
    /// origin is the board but the board is offline right now — overwrite is
    /// not possible at all (§11.3), so the choice is skipped entirely and the
    /// draft goes straight to naming as a new (local) face.
    private func beginSave() {
        if model.canOverwriteEditingFace,
           !(model.editingLocation == .board && !isConnected) {
            isChoosingSaveTarget = true
        } else {
            beginNaming(asNew: true)
        }
    }

    /// Freezes the destination, the draft frame and the edited face's
    /// identity the moment the naming sheet opens, so a reconnect or board
    /// switch that happens while it is open can never redirect this save.
    private func beginNaming(asNew: Bool) {
        savesAsNew = asNew
        saveNameDraft = model.saveName
        saveFrame = model.draftFrame
        saveFaceID = model.editingFaceId
        saveLocation = model.suggestedSaveLocation(asNew: asNew, isConnected: isConnected)
        saveBoardSource = saveLocation == .board
            ? BoardFaceSaveSource(boardID: connection.boardKey, generation: connection.connectionGeneration)
            : nil
        isNamingSave = true
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
                        selectedId: model.fromParts ? model.selectedCall[group] : nil,
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
