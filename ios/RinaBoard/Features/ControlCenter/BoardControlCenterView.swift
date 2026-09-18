import SwiftUI
import RinaCore

/// The global Control Center (design guide §5–§11).
///
/// Board-wide state only: status, brightness, previous/next, auto mode,
/// colour. Saving and the saved-face list live on the Control tab. It never
/// keeps its own copy of canonical board state —
/// everything is read from `BoardConnection` and `BoardControlCenterModel`,
/// so a change made here is immediately visible on every tab (§51).
///
/// The same view is used for all three presentations: as the expanded sheet
/// behind the iOS 26 tab-bar accessory, as a pushed screen under Settings on
/// earlier releases, and — with `isEmbedded` — as a block of sections inside
/// another page's list, which is where the two-column iPad layout puts it
/// (under every page's board preview, `BoardSplitPage`).
struct BoardControlCenterView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardControlCenterModel.self) private var model
    @Environment(FaceLibraryModel.self) private var faceLibrary
    @Environment(BoardStore.self) private var boardStore
    @Environment(BoardSessionStore.self) private var sessions
    @Environment(BoardGroupStore.self) private var groupStore
    @Environment(BoardGroupCoordinator.self) private var groupCoordinator
    @Environment(GroupControlFanOut.self) private var fanOut
    @Environment(GroupAutoCycler.self) private var groupAutoCycler
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var boardSwitcher: ConnectionViewModel?

    /// Which board(s) the sections below act on (BOARD_GROUP_SPEC.md §3's
    /// "控制对象" menu). Empty string = `.single`.
    @AppStorage(ControlTargetKey.groupID) private var controlTargetGroupIDStorage = ""
    @State private var isPresentingGroupManage = false
    /// The group id captured when "新建多板组…" created it, so the sheet's
    /// content doesn't depend on the still-current control target and a
    /// target change while it's open can't blank it out from under the user.
    @State private var newGroupEditorTarget: GroupSheetTarget?
    /// The group id captured at the moment each sheet was presented (B1):
    /// a `sheet(item:)`, not `sheet(isPresented:)` gated on re-reading
    /// `controlTarget` — so the target menu changing while either sheet is
    /// open can't blank its content.
    @State private var playingGroupTarget: GroupSheetTarget?
    @State private var editingGroupTarget: GroupSheetTarget?
    /// The id `newGroupEditorTarget` was last set to, read back by
    /// `cleanupNewGroupIfUnused()` after the sheet's `onDismiss` — by then
    /// `newGroupEditorTarget` itself has already gone back to `nil`.
    @State private var pendingNewGroupID: UUID?

    /// Non-nil when presented as a sheet, so it can offer a Done button.
    var onDismiss: (() -> Void)?

    /// True when the sections are dropped straight into another page's list
    /// instead of owning one. An embedded panel brings no list, no navigation
    /// title and no background of its own — the page around it supplies all
    /// three — and it is never a sheet, so it never has a Done button.
    var isEmbedded = false

    @AppStorage(AppSettingsKey.hapticsEnabled) private var hapticsEnabled = true

    /// Bumped by the transport row's own taps. Board-driven state changes must
    /// not buzz the phone — only the user's presses do (§42).
    @State private var controlTicks = 0

    private var isConnected: Bool { connection.connectionState == .connected }

    /// True only while a group is targeted AND the fan-out actually has a
    /// primary attached (`fanOut.primaryID != nil`) — H1: a group can be the
    /// "控制对象" while the active board isn't currently one of its members
    /// (an implicit, non-explicit navigation away), in which case the group
    /// cycler/fan-out has nothing to mirror through and the mode row/prev/
    /// next must fall back to the ordinary single-board path instead of
    /// silently doing nothing.
    private var groupControlSynced: Bool {
        targetedGroup != nil && fanOut.primaryID != nil
    }

    /// The mode row's displayed auto/manual state. While a group is targeted
    /// and synced this reads `GroupAutoCycler.isRunning` instead of the
    /// primary's own firmware `renderer.mode` — the primary never leaves
    /// `manual` while the synced cycle runs (BOARD_GROUP_SPEC.md §3
    /// addendum).
    private var isAutoModeOn: Bool {
        groupControlSynced ? groupAutoCycler.isRunning : model.isAutoMode(status: connection.status)
    }

    /// Routes the mode toggle to the synced group cycler while a group is
    /// targeted and synced, instead of sending `set_mode auto` to the primary
    /// (which `GroupControlFanOut` would otherwise mirror to every member's
    /// own independent, unsynced firmware auto timer). Falls back to the
    /// ordinary single-board path otherwise (H1).
    private func toggleAutoMode() async {
        if groupControlSynced {
            if groupAutoCycler.isRunning { groupAutoCycler.stop() } else { _ = groupAutoCycler.start() }
        } else {
            await model.toggleAutoMode(connection: connection)
        }
    }

    /// Routes prev/next to the group cycler's own index while a group is
    /// targeted and synced, so every member receives the identical resulting
    /// frame. Falls back to the ordinary single-board path otherwise (H1).
    private func stepFace(direction: Int) async {
        if groupControlSynced {
            await groupAutoCycler.step(direction: direction)
        } else {
            await model.step(face: direction, connection: connection)
        }
    }

    private var canDisconnect: Bool {
        switch connection.connectionState {
        case .connected, .connecting, .reconnecting: return true
        case .disconnected, .failed: return false
        }
    }

    /// Read through the store rather than injected: `any BLEConnecting` cannot
    /// go in the environment (`@Environment(T.self)` needs a concrete
    /// observable type).
    private var bleTransport: any BLEConnecting { sessions.active.bleTransport }

    @ViewBuilder
    var body: some View {
        content
    }

    /// A group's id captured at the moment a sheet was presented — see the
    /// `newGroupEditorTarget`/`playingGroupTarget`/`editingGroupTarget`
    /// declarations above (B1).
    private struct GroupSheetTarget: Identifiable {
        let id: UUID
    }

    /// The four group sheets plus the §3 "Item 7" validation, factored out so
    /// both `content` branches can attach exactly one copy each (B1): on a
    /// `Group` of `Section`s every modifier is applied per-section, so
    /// attaching these to the `Group` itself would open/close four sheets and
    /// run the validation once per section instead of once.
    @ViewBuilder
    private func groupSheets<V: View>(_ view: V) -> some View {
        view
            .onChange(of: groupStore.groups) { _, _ in
                // Item 7: a group deleted out from under the current target
                // must not keep this menu (and the Text tab) pointed at a
                // dead id.
                ControlTarget.validate(&controlTargetGroupIDStorage, in: groupStore)
            }
            .sheet(isPresented: $isPresentingGroupManage) {
                NavigationStack { BoardGroupListView().sheetDoneButton() }
            }
            .sheet(item: $newGroupEditorTarget, onDismiss: cleanupNewGroupIfUnused) { target in
                NavigationStack { BoardGroupEditorView(groupID: target.id).sheetDoneButton() }
            }
            .sheet(item: $playingGroupTarget) { target in
                NavigationStack { BoardGroupPlayView(groupID: target.id).sheetDoneButton() }
            }
            .sheet(item: $editingGroupTarget) { target in
                NavigationStack { BoardGroupEditorView(groupID: target.id).sheetDoneButton() }
            }
    }

    /// "新建多板组…" creates the group immediately (so the editor has an id
    /// to work with) but the user may simply dismiss without naming or
    /// adding a member to it. If the sheet closes and the group it created
    /// is still exactly that — no members, still the default name — delete
    /// it rather than leave an empty phantom group in "管理多板组…".
    private func cleanupNewGroupIfUnused() {
        guard let id = pendingNewGroupID else { return }
        pendingNewGroupID = nil
        guard let group = groupStore.groups.first(where: { $0.id == id }) else { return }
        guard group.members.isEmpty, group.name == Self.defaultNewGroupName else { return }
        groupStore.remove(id: id)
        if ControlTarget(storedGroupIDString: controlTargetGroupIDStorage) == .group(id) {
            controlTargetGroupIDStorage = ""
        }
    }

    private static let defaultNewGroupName = "多板组"

    @ViewBuilder
    private var content: some View {
        if isEmbedded {
            // A modifier on a `Group` of `Section`s is applied to every
            // section in it, so the lifecycle rides the first section alone:
            // one alert and one run of each task, not five.
            Group {
                groupSheets(
                    statusSection
                        .errorAlert(errorMessage)
                        .task { await loadPanelContents() }
                        .task { await HotspotJoiner.revalidateLastJoinedSSID() }
                )
                groupControlSection
                brightnessSection
                modeSection
                colorSection
            }
        } else {
            ownList
        }
    }

    /// The current control target, validated against `groupStore` (a stale
    /// stored group id reads back as `.single`).
    private var controlTarget: ControlTarget {
        ControlTarget.resolved(storedGroupIDString: controlTargetGroupIDStorage, in: groupStore)
    }

    private var targetedGroup: BoardGroup? {
        guard case .group(let id) = controlTarget else { return nil }
        return groupStore.groups.first { $0.id == id }
    }

    private var ownList: some View {
        groupSheets(
            List {
                Group {
                    statusSection
                    groupControlSection
                    brightnessSection
                    modeSection
                    colorSection
                }
                .rinaTranslucentRows(onDismiss == nil)
            }
        )
        .listSectionSpacing(.compact)
        // Pushed from Settings before iOS 26; with `onDismiss` it is the
        // tab-bar accessory's sheet, which keeps its presentation background.
        .rinaScrollBackground(onDismiss == nil)
        .errorAlert(errorMessage)
        .navigationTitle("面板控制")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onDismiss)
                }
            }
        }
        .task { await loadPanelContents() }
        .task {
            // See ConnectionView: refresh the cache whenever this surface
            // (re)appears rather than trusting a possibly stale join.
            await HotspotJoiner.revalidateLastJoinedSSID()
        }
    }

    private func loadPanelContents() async {
        model.loadDefaultsIfNeeded()
        if faceLibrary.faceDocument.faces.isEmpty {
            await faceLibrary.reload(connection: connection)
        }
    }

    // MARK: §7.1 Board summary

    private var statusSection: some View {
        Section {
            controlTargetRow
            if let group = targetedGroup {
                // Group mode: one row per member (name, 主控 badge, connection
                // state + a per-member "连接" retry, battery) replaces the
                // single-board connection/battery rows below — never both
                // (user requirement: "需要显示多条电池信息，连接信息").
                GroupMemberStatusList(group: group)
            } else {
                LabeledContent("连接状态") {
                    // State is never communicated by colour alone (§7, §41).
                    HStack(spacing: 10) {
                        Label(connectionStateText, systemImage: connectionStateSymbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(connectionStateTint)
                        // Also stops a connect or reconnect loop in progress:
                        // `disconnect()` cancels the retry task too.
                        if canDisconnect {
                            Button(isConnected ? "断开" : "取消", role: .destructive) {
                                connection.disconnect()
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("controlCenter.disconnect")
                        }
                    }
                }
                if let greeting = model.connectionGreeting {
                    Text(greeting)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error = connection.lastError, !isConnected {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("connection.failureReason")
                    // Secondary encouragement directly under the concrete
                    // failure reason above — it never stands in for that
                    // reason, and only appears once one is already shown.
                    // Only once the app has given up: while it is still
                    // retrying on its own, lastError is set too.
                    if case .failed = connection.connectionState {
                        Text("请重新尝试连接")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // Embedded (the iPad preview column) the bar is always there:
                // that column is the only place the battery shows on iPad,
                // and a row that appears with the first power report would
                // shift the whole panel. As its own screen it keeps to real
                // readings.
                if isEmbedded || connection.batteryReading != nil {
                    BoardBatteryRow()
                }
            }
        } header: {
            // Named only where the panel rides inside another page's list
            // (the iPad preview column). On its own screen the navigation
            // title already says what this is.
            if isEmbedded { Text("面板控制") }
        }
    }

    /// Either model's error, one alert at a time; dismissing clears both.
    private var errorMessage: Binding<String?> {
        Binding(
            get: { boardSwitcher?.lastErrorMessage ?? model.errorMessage ?? faceLibrary.errorMessage },
            set: { if $0 == nil { boardSwitcher?.lastErrorMessage = nil; model.errorMessage = nil; faceLibrary.errorMessage = nil } }
        )
    }

    /// One selectable row of the "控制对象" menu's inline picker: a saved
    /// board, or a multi-board group.
    private enum ControlSelection: Hashable {
        case board(String)
        /// Single-board mode on whatever board is connected (or none), for
        /// when that board is not a saved one — so "单板" is always a choice.
        case currentSingle
        case group(UUID)
    }

    /// True when the live board has no saved-board row to check, including
    /// when nothing is saved at all.
    private var showsCurrentSingleRow: Bool {
        !boardStore.boards.contains { $0.id == currentBoardID }
    }

    /// The row currently checked by the picker. `.board("")` when no saved
    /// board matches the live connection (not yet connected, or connected to
    /// something not saved) — it simply leaves every row unchecked.
    private var controlSelectionTag: ControlSelection {
        if let group = targetedGroup { return .group(group.id) }
        if isConnected, let id = currentBoardID,
           boardStore.boards.contains(where: { $0.id == id }) { return .board(id) }
        return showsCurrentSingleRow ? .currentSingle : .board("")
    }

    /// One checkmark row of the 控制对象 menu. Turning a checked row off is
    /// ignored: the menu always has exactly one target.
    private func controlTargetToggle(_ title: String, systemImage: String,
                                     selection: ControlSelection) -> some View {
        Toggle(isOn: Binding(
            get: { controlSelectionTag == selection },
            set: { isOn in if isOn { handleControlSelection(selection) } }
        )) {
            Label(title, systemImage: systemImage)
        }
    }

    private func handleControlSelection(_ newValue: ControlSelection) {
        switch newValue {
        case .board(let id):
            guard let board = boardStore.boards.first(where: { $0.id == id }) else { return }
            controlTargetGroupIDStorage = ControlTarget.single.storedGroupIDString
            switchBoard(to: board)
        case .currentSingle:
            controlTargetGroupIDStorage = ControlTarget.single.storedGroupIDString
        case .group(let id):
            controlTargetGroupIDStorage = ControlTarget.group(id).storedGroupIDString
        }
    }

    /// The "控制对象" row: a title above a `Menu`. At accessibility sizes the
    /// title sits above the menu instead of beside it (via `LabeledContent`,
    /// whose own adaptive layout truncates rather than wraps).
    @ViewBuilder
    private var controlTargetRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                // The menu itself already carries "控制对象" as its
                // accessibility label; this caption is for sighted users only.
                Text("控制对象")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // A Menu sizes to its label's ideal width by default, which
                // wrapped the value at half the row; give it the full row.
                controlTargetMenu
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            LabeledContent("控制对象") {
                controlTargetMenu
            }
            // Otherwise the separator starts under the menu's value text.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        }
    }

    /// The native `Menu` a tap opens, in two titled sections: "单板" (the
    /// saved boards) and "多板组" (the groups plus 新建/管理). Rows are inline
    /// `Picker`s, so the system draws the checkmark and handles Dynamic Type,
    /// VoiceOver's "已选择" and keyboard/pointer.
    private var controlTargetMenu: some View {
        Menu {
            // Titled Sections of Toggle rows: a Menu draws each Toggle as a
            // native checkmark item (VoiceOver "已选择"), and keeps the section
            // titles, which inline Pickers lost on iOS 26.
            Section("单板") {
                if showsCurrentSingleRow {
                    controlTargetToggle(
                        isConnected ? "单板：\(boardName)" : "单板（未连接）",
                        systemImage: "rectangle.on.rectangle",
                        selection: .currentSingle
                    )
                }
                ForEach(boardStore.boards) { board in
                    controlTargetToggle(board.name, systemImage: "rectangle.on.rectangle",
                                        selection: .board(board.id))
                }
            }

            if !groupStore.groups.isEmpty {
                Section("多板组") {
                    ForEach(groupStore.groups) { group in
                        controlTargetToggle(
                            "\(group.name) · \(onlineMemberCount(group))/\(group.members.count) 在线",
                            systemImage: "rectangle.split.3x1",
                            selection: .group(group.id)
                        )
                    }
                }
            }

            Section {
                Button {
                    let group = groupStore.create(name: Self.defaultNewGroupName)
                    pendingNewGroupID = group.id
                    newGroupEditorTarget = GroupSheetTarget(id: group.id)
                } label: {
                    Label("新建多板组…", systemImage: "plus")
                }
                Button {
                    isPresentingGroupManage = true
                } label: {
                    Label("管理多板组…", systemImage: "list.bullet")
                }
            }
        } label: {
            controlTargetMenuLabel
        }
        .disabled(isSwitchingBoard)
        .accessibilityLabel("控制对象")
        .accessibilityValue(controlTargetLabel)
        .accessibilityIdentifier("controlCenter.controlTargetSelector")
    }

    /// The row the user taps to open the menu. At accessibility sizes the
    /// title and value stack vertically and the value is free to wrap onto
    /// further lines; otherwise it's one line, truncating in the middle so
    /// both a long board name's start and end stay legible.
    @ViewBuilder
    private var controlTargetMenuLabel: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Label(controlTargetLabel, systemImage: controlTargetIcon)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: AppLayout.minimumTapTarget, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                Label(controlTargetLabel, systemImage: controlTargetIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .frame(minHeight: AppLayout.minimumTapTarget)
        }
    }

    /// The "控制对象" menu label: the active board's name with a single-board
    /// glyph, or the targeted group's name and member count with a
    /// multi-board glyph.
    private var controlTargetLabel: String {
        if let group = targetedGroup {
            return "\(group.name) · \(group.members.count) 块"
        }
        return boardName
    }

    private var controlTargetIcon: String {
        targetedGroup != nil ? "rectangle.split.3x1" : "rectangle.on.rectangle"
    }

    private func onlineMemberCount(_ group: BoardGroup) -> Int {
        group.members.filter { groupCoordinator.status(for: $0) != .offline }.count
    }

    // MARK: §7.2 Multi-board group panel

    /// Shown only while the control target is a group: the group's own
    /// summary and controls, plus a way back to `.single`
    /// (BOARD_GROUP_SPEC.md §3).
    @ViewBuilder
    private var groupControlSection: some View {
        if let group = targetedGroup {
            Section("多板组控制") {
                LabeledContent("名称", value: group.name)
                LabeledContent("模式", value: group.mode == .stitched ? "拼接" : "镜像")
                // H1: the active board is targeting this group but isn't
                // (yet) one of its members, so the fan-out has no primary to
                // mirror through — the mode row/prev/next below fell back to
                // the ordinary single-board path; say so rather than leaving
                // it looking like group control silently did nothing.
                if fanOut.primaryID == nil, isConnected {
                    Text("当前面板不在组内，未同步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await groupCoordinator.identifyAll(group) }
                } label: {
                    Label("识别编号", systemImage: "number.circle")
                }
                .disabled(group.members.isEmpty)

                Button {
                    // Captured now, not re-read from `controlTarget` once the
                    // sheet is already up (B1) — the id this button meant
                    // when pressed, even if the target menu changes later.
                    playingGroupTarget = GroupSheetTarget(id: group.id)
                } label: {
                    Label("多板播放", systemImage: "play.circle")
                }

                Button {
                    editingGroupTarget = GroupSheetTarget(id: group.id)
                } label: {
                    Label("编辑组", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    controlTargetGroupIDStorage = ControlTarget.single.storedGroupIDString
                } label: {
                    Label("切回单板", systemImage: "rectangle")
                }
            }
        }
    }

    private var boardName: String {
        if let id = boardSwitcher?.connectingSavedBoardID,
           let board = boardStore.boards.first(where: { $0.id == id }) {
            return board.name
        }
        return connection.deviceName
            ?? boardStore.boards.first(where: { $0.id == currentBoardID })?.name
            ?? bleTransport.connectedPeripheralName
            ?? connection.wifi?.hostname
            ?? (sessions.active.boardID != nil ? sessions.active.name : nil)
            ?? "Rina-Chan Board"
    }

    private var currentBoardID: String? {
        switch connection.transportKind {
        case .bluetooth: return bleTransport.connectedPeripheralID?.uuidString
        case .wifi(let host, _):
            return boardStore.boards.first(where: { $0.lastHost == host || $0.id == host })?.id
        case .hotspot:
            // No apIP fallback: an unresolved/stale SSID must not silently
            // resolve to some other board's legacy shared-IP record. Prefer
            // this session's own expected SSID over the process-global
            // `lastJoinedSSID`, which a second board's session could have
            // overwritten since this one connected.
            let ssid = connection.expectedHotspotSSID ?? HotspotJoiner.lastJoinedSSID
            return ssid.map(KnownBoard.hotspotStorageID)
        case nil: return nil
        }
    }

    /// Only a switch this menu started locks it. The selected board being
    /// out of range and retrying must not trap the user there: every other
    /// board keeps its own connection and stays one pick away.
    private var isSwitchingBoard: Bool {
        boardSwitcher?.connectingSavedBoardID != nil
    }

    private func switchBoard(to board: KnownBoard) {
        guard !isSwitchingBoard else { return }
        let switcher = boardSwitcher ?? ConnectionViewModel()
        boardSwitcher = switcher
        Task {
            await switcher.connectSavedBoard(board, sessions: sessions, boardStore: boardStore)
        }
    }

    private var connectionStateText: String {
        switch connection.connectionState {
        case .connected: return NSLocalizedString("已连接", comment: "connection state connected")
        case .connecting: return NSLocalizedString("连接中", comment: "connection state connecting")
        case .reconnecting(let attempt):
            return String(format: NSLocalizedString("重连中（第 %lld 次）", comment: "connection state reconnecting"), attempt)
        case .disconnected: return NSLocalizedString("未连接", comment: "connection state disconnected")
        case .failed(let message): return String(format: NSLocalizedString("连接失败：%@", comment: "connection state failed"), message)
        }
    }

    private var connectionStateSymbol: String {
        switch connection.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "circle.slash"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var connectionStateTint: Color {
        switch connection.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    // MARK: §8 Brightness

    private var brightnessSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("亮度") {
                    Text("\(BoardControlCenterModel.percent(forRaw: model.draftBrightness))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { model.brightnessDraft },
                        set: { model.setBrightness(Int($0), connection: connection) }
                    ),
                    // No `step:` — on iOS 26 a stepped Slider draws a tick
                    // per step, and ~255 ticks fuse into a grey bar under the
                    // track. The setter already snaps to whole raw values.
                    in: Double(RinaLinkConstants.brightnessMin)...Double(RinaLinkConstants.brightnessMax)
                ) {
                    Text("亮度")
                } minimumValueLabel: {
                    Image(systemName: "sun.min")
                } maximumValueLabel: {
                    Image(systemName: "sun.max")
                }
                .disabled(!isConnected)
                .accessibilityValue(Text("\(BoardControlCenterModel.percent(forRaw: model.draftBrightness))%"))
            }
        }
    }

    // MARK: §9 Previous / Next / Auto

    @ViewBuilder
    private var modeSection: some View {
        Section("切换表情") {
            // A transport row: step back, the mode switch, step forward — the
            // same three controls the collapsed accessory offers, in the same
            // order, so the two surfaces read as one control set (§51).
            HStack(spacing: 10) {
                Button {
                    controlTicks += 1
                    Task { await stepFace(direction: -1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .accessibilityLabel("上一个表情")

                Toggle(isOn: Binding(
                    get: { isAutoModeOn },
                    set: { _ in
                        controlTicks += 1
                        Task { await toggleAutoMode() }
                    }
                )) {
                    // Glyph + title, so the state never rests on the fill
                    // colour alone (§41).
                    Label(isAutoModeOn ? "自动" : "手动",
                          systemImage: isAutoModeOn
                                       ? "arrow.triangle.2.circlepath"
                                       : "hand.tap.fill")
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .toggleStyle(.pill)
                .accessibilityLabel("自动模式")

                Button {
                    controlTicks += 1
                    Task { await stepFace(direction: 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .accessibilityLabel("下一个表情")
            }
            .buttonStyle(.pill)
            .labelStyle(.titleAndIcon)
            .pillButtonRow()
            .listRowSeparator(.hidden)
            .disabled(!isConnected)
            .sensoryFeedback(.selection, trigger: controlTicks) { _, _ in hapticsEnabled }
        }

        // Separate section: the pill row clears its cell background, so
        // sharing a section with the slider left a broken card under it.
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("自动切换间隔") {
                    Text(String(format: "%.1fs", model.autoIntervalDraft))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { model.autoIntervalDraft },
                        set: { model.setAutoInterval($0, connection: connection) }
                    ),
                    in: Double(RinaLinkConstants.autoIntervalMinMs) / 1000...Double(RinaLinkConstants.autoIntervalMaxMs) / 1000,
                    step: 0.1
                )
                .disabled(!isConnected)
                .accessibilityLabel("自动切换间隔")
                .accessibilityValue(Text(String(format: NSLocalizedString("%.1f 秒", comment: "auto interval seconds"),
                                                model.autoIntervalDraft)))
            }
        }
    }

    // MARK: §10 Colour

    private var colorSection: some View {
        Section {
            ColorPicker(selection: Binding(
                get: { model.draftColor },
                set: { newColor in
                    Task { await model.setColor(hex: newColor.hexString, connection: connection) }
                }
            ), supportsOpacity: false) {
                Label("面板颜色", systemImage: "paintpalette")
            }
            .disabled(!isConnected)

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("十六进制") {
                    TextField("#RRGGBB", text: Binding(
                        get: { model.hexFieldText },
                        set: { model.hexFieldChanged($0) }
                    ))
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await model.commitHexField(connection: connection) } }
                    .disabled(!isConnected)
                }
                if !model.hexFieldIsValid {
                    // Inline validation: editing stays possible and nothing is
                    // transmitted until the value parses (§10, §59).
                    Text("格式应为 #RRGGBB")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let presets = model.colorPresets {
                colorPresetPicker(presets)
            }
        }
    }

    @ViewBuilder
    private func colorPresetPicker(_ presets: ColorPresets) -> some View {
        let parentId = model.selectedParentId ?? presets.parents.first.map { String($0.id) }
        Picker("配色组", selection: Binding(
            get: { parentId ?? "" },
            set: { parentId in
                guard let parent = presets.parents.first(where: { String($0.id) == parentId }) else { return }
                model.selectedParentId = parentId
                Task { await model.setColor(hex: parent.color, connection: connection) }
            }
        )) {
            ForEach(presets.parents) { parent in
                Text(ColorPresets.displayName(parent.name)).tag(String(parent.id))
            }
        }
        .disabled(!isConnected)

        if let parent = presets.parents.first(where: { String($0.id) == parentId }) {
            let swatches = presets.swatches(of: parent)
            if !swatches.isEmpty {
                // Same menu Picker as the group above. The tag is the swatch's
                // own hex spelling; a board colour outside this group shows
                // as 自定义 until a preset is chosen.
                let selectedHex = swatches.first { isSelectedColor($0.hex) }?.hex
                Picker("颜色", selection: Binding(
                    get: { selectedHex ?? "" },
                    set: { hex in
                        guard !hex.isEmpty else { return }
                        Task { await model.setColor(hex: hex, connection: connection) }
                    }
                )) {
                    if selectedHex == nil {
                        Text("自定义").tag("")
                    }
                    ForEach(swatches, id: \.hex) { swatch in
                        Text(ColorPresets.displayName(swatch.name)).tag(swatch.hex)
                    }
                }
                .disabled(!isConnected)
            }
        }
    }

    private func isSelectedColor(_ hex: String) -> Bool {
        guard let candidate = RGBHex.parseHex(hex), let current = RGBHex.parseHex(model.colorHexDraft) else {
            return false
        }
        return candidate == current
    }
}

/// A 完成 button for the group sheets opened from the Control Center, so
/// they close without a swipe (pointer and keyboard on iPad, VoiceOver).
private struct SheetDoneButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }
}

private extension View {
    func sheetDoneButton() -> some View { modifier(SheetDoneButton()) }
}
