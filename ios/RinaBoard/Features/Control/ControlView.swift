import SwiftUI
import RinaCore

/// Control tab (design guide §15, §16, §18, §19): the face/frame creation
/// surface, including sending the draft and the saved-face list. Board-global
/// brightness, colour, prev/next and auto mode are deliberately absent — they
/// belong to the Control Center (§63).
struct ControlView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardSessionStore.self) private var sessions
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
    @State private var namingSave: FaceSaveNamingPresentation?
    @State private var saveNameDraft = ""
    @State private var isChoosingSaveTarget = false
    /// Set by the save-target dialog; applied only when the naming sheet is
    /// confirmed, so cancelling leaves the editor's save target untouched.
    @State private var savesAsNew = false
    @State private var isShowingSavedFaces = false
    /// The destination and identity are frozen the moment the naming sheet
    /// opens (Control §11.3): a reconnect or a board switch while it is open
    /// must not silently redirect an in-progress save.
    @State private var saveLocation: FaceLibraryLocation = .board
    @State private var saveFrame = PackedFrame()
    @State private var saveFaceID: String?
    @State private var saveBoardSource: BoardFaceSaveSource?
    @State private var multiSave = MultiBoardFaceSaveCoordinator()
    @State private var pickingSaveBoards: FaceSaveTargetsPresentation?
    @State private var selectedSaveBoards: [FrozenFaceSaveDestination] = []
    @State private var continueNamingAfterTargets = false
    @State private var saveMultiSnapshot: MultiBoardFaceSaveSnapshot?
    @State private var saveResults: FaceSaveResultsPresentation?
    @State private var preparedMultiSave = false
    @State private var adoptedMultiOperationID: UUID?
    @State private var adoptingMultiOperationID: UUID?
    @State private var confirmingDiscardPendingSave = false

    private var isConnected: Bool { connection.connectionState == .connected }
    private var canSaveToBoard: Bool { !FrozenFaceSaveDestination.connected(in: sessions).isEmpty }
    /// Names the save sheet's destination (DEF-05) so a title alone tells the
    /// user where the face is going, reusing `FaceLibraryLocation`'s own
    /// wording instead of inventing new terms for the same two places. Uses
    /// the frozen `saveLocation`, not the live connection state, so the title
    /// never disagrees with where the sheet is actually about to save.
    private var saveDestinationTitle: String {
        if !selectedSaveBoards.isEmpty {
            return String(format: NSLocalizedString("保存到 %lld 个面板", comment: "multi-board save naming title"), Int64(selectedSaveBoards.count))
        }
        return String(format: NSLocalizedString("保存到%@", comment: "save alert title naming its destination"),
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
            .modifier(FoldedControlCenterToolbar())
            // No navigation bar, so the list's default top margin only pushes
            // the board away from the status bar.
            .contentMargins(.top, 0, for: .scrollContent)
            .sheet(item: $namingSave, onDismiss: {
                if preparedMultiSave {
                    preparedMultiSave = false
                    saveResults = FaceSaveResultsPresentation(startPrepared: true)
                }
            }) { save in
                FaceNameEditorSheet(title: save.title, initialName: save.name) { name in
                    guard model.draftFrame == save.frame, model.editingFaceId == save.faceID else {
                        return NSLocalizedString("编辑内容已改变，请关闭后重新保存", comment: "face changed while naming")
                    }
                    if let snapshot = save.snapshot, !save.destinations.isEmpty {
                        guard !model.hasPendingBoardSave else {
                            return NSLocalizedString("请先连接原面板，核对上次单面板保存", comment: "single pending blocks multi save")
                        }
                        model.saveName = name
                        guard await model.persistDraft() else { return model.draftStorageError }
                        let prepared = await multiSave.prepare(name: name, snapshot: snapshot, destinations: save.destinations)
                        preparedMultiSave = prepared
                        return prepared ? nil : multiSave.errorMessage
                    }
                    let success = await model.saveEditedFace(
                        name: name, asNew: save.asNew, to: .board,
                        library: faceLibrary, connection: connection, expectedBoard: save.boardSource
                    )
                    return success ? nil : (faceLibrary.errorMessage
                        ?? NSLocalizedString("保存失败，请重试", comment: "save face failed"))
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: toggleCount) { _, _ in hapticsEnabled }
            .sheet(isPresented: $isShowingSavedFaces) { savedFacesSheet }
            .sheet(item: $pickingSaveBoards, onDismiss: {
                if continueNamingAfterTargets {
                    continueNamingAfterTargets = false
                    finishNamingSetup(asNew: savesAsNew)
                }
            }) { picker in
                FaceSaveTargetsSheet(destinations: picker.destinations, currentID: picker.currentID,
                                     overwriteBoardID: picker.overwriteBoardID) { selected in
                    selectedSaveBoards = selected
                    continueNamingAfterTargets = true
                }
            }
            .sheet(item: $saveResults) { results in
                MultiBoardFaceSaveResultsSheet(coordinator: multiSave, startPrepared: results.startPrepared) {
                    await adoptPrimaryMultiSaveResult()
                }
            }
        }
        .errorAlert(Bindable(model).errorMessage)
        .onAppear { bootLoader.beginWaterfall(count: 3) }
        .task {
            await multiSave.restore()
            await adoptPrimaryMultiSaveResult()
        }
        .onChange(of: isConnected) { _, connected in
            if !connected {
                isShowingSavedFaces = false
                if selectedSaveBoards.isEmpty && pickingSaveBoards == nil {
                    namingSave = nil
                    isChoosingSaveTarget = false
                }
            }
        }
        .onChange(of: connection.connectionGeneration) { _, _ in
            isShowingSavedFaces = false
            if selectedSaveBoards.isEmpty && pickingSaveBoards == nil {
                namingSave = nil
                isChoosingSaveTarget = false
            }
        }
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

                if isConnected {
                    Button { isShowingSavedFaces = true } label: {
                        CommandChip("板上表情", systemImage: "list.bullet.rectangle")
                    }
                }

                Button {
                    beginSave()
                } label: {
                    CommandChip("保存", systemImage: "square.and.arrow.down.fill")
                }
                .disabled(!canSaveToBoard || faceLibrary.isSaving || multiSave.isRunning)
                .confirmationDialog("保存表情", isPresented: $isChoosingSaveTarget) {
                    Button("覆盖原表情") { beginNaming(asNew: false) }
                    Button("另存为新表情") { beginNaming(asNew: true) }
                    Button("取消", role: .cancel) {}
                }
            }
            .buttonStyle(.pill)
            .pillButtonRow()
            if multiSave.hasRetainedResult {
                Button(multiSave.allConfirmed ? "查看上次保存结果" : "继续上次保存", systemImage: "clock.arrow.circlepath") {
                    saveResults = FaceSaveResultsPresentation(startPrepared: false)
                }
            }
            if model.hasPendingBoardSave {
                Button("放弃待确认保存", systemImage: "xmark.circle", role: .destructive) {
                    confirmingDiscardPendingSave = true
                }
                .disabled(faceLibrary.isSaving)
                .confirmationDialog("放弃待确认保存？", isPresented: $confirmingDiscardPendingSave,
                                    titleVisibility: .visible) {
                    Button("放弃待确认保存", role: .destructive) {
                        Task { await model.discardPendingBoardSave() }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("不会再核对或重试上次保存，也不会撤回；面板上可能已有该表情，请稍后在其表情列表中检查。当前画面会保留。")
                }
            }
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("control.drawingCommands")
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
                    MenuToolbarItem(placement: .cancellationAction) {
                        Button("关闭窗口", systemImage: "xmark") { isShowingSavedFaces = false }
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

    /// Existing editable board faces offer overwrite or a separate new copy.
    private func beginSave() {
        guard canSaveToBoard else { return }
        selectedSaveBoards = []
        saveMultiSnapshot = nil
        if multiSave.hasRetainedResult {
            saveResults = FaceSaveResultsPresentation(startPrepared: false)
            return
        }
        if model.hasPendingBoardSave {
            guard isConnected else {
                model.errorMessage = NSLocalizedString("请先连接原面板，核对上次保存", comment: "pending single board save must be reconciled first")
                return
            }
            finishNamingSetup(asNew: false, pendingName: model.pendingBoardSaveName)
            return
        }
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
        guard canSaveToBoard else { return }
        savesAsNew = asNew
        let inventory = FrozenFaceSaveDestination.connected(in: sessions)
        if FaceSaveDestinationSelection.requiresPicker(inventory, activeConnection: connection) {
            saveNameDraft = model.saveName
            saveFrame = model.draftFrame
            saveFaceID = model.editingFaceId
            saveMultiSnapshot = model.multiBoardSaveSnapshot(asNew: asNew, originBoardID: connection.boardKey ?? model.draftBoardID, using: faceLibrary)
            pickingSaveBoards = FaceSaveTargetsPresentation(destinations: inventory,
                currentID: saveMultiSnapshot?.originBoardID,
                overwriteBoardID: saveMultiSnapshot?.overwriteSource?.boardID)
            return
        }
        finishNamingSetup(asNew: asNew)
    }

    private func finishNamingSetup(asNew: Bool, pendingName: String? = nil) {
        guard canSaveToBoard else { return }
        savesAsNew = asNew
        if selectedSaveBoards.isEmpty {
            saveNameDraft = model.saveName
            saveFrame = model.draftFrame
            saveFaceID = model.editingFaceId
            saveMultiSnapshot = nil
        }
        saveLocation = .board
        saveBoardSource = BoardFaceSaveSource(boardID: connection.boardKey, generation: connection.connectionGeneration)
        namingSave = FaceSaveNamingPresentation(title: saveDestinationTitle, name: pendingName ?? saveNameDraft,
            frame: saveFrame, faceID: saveFaceID, asNew: asNew, boardSource: saveBoardSource,
            snapshot: saveMultiSnapshot, destinations: selectedSaveBoards)
    }

    private func adoptPrimaryMultiSaveResult() async {
        guard let operation = multiSave.operation, adoptedMultiOperationID != operation.id,
              adoptingMultiOperationID != operation.id else { return }
        let current = connection
        guard operation.snapshot.originBoardID == current.boardKey,
              operation.targets.contains(where: { $0.id == current.boardKey && $0.status == .confirmed }) else { return }
        adoptingMultiOperationID = operation.id
        defer { adoptingMultiOperationID = nil }
        if await model.adoptMultiBoardSave(operation, connection: current) {
            adoptedMultiOperationID = operation.id
            guard current === connection, operation.snapshot.originBoardID == current.boardKey else { return }
            _ = await faceLibrary.reload(connection: current)
        }
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
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
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
