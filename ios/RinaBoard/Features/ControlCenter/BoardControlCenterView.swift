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
    @State private var boardSwitcher: ConnectionViewModel?

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

    /// Read through the store rather than injected: `any BLEConnecting` cannot
    /// go in the environment (`@Environment(T.self)` needs a concrete
    /// observable type).
    private var bleTransport: any BLEConnecting { sessions.active.bleTransport }

    @ViewBuilder
    var body: some View {
        if isEmbedded {
            // A modifier on a `Group` of `Section`s is applied to every
            // section in it, so the lifecycle rides the first section alone:
            // one alert and one run of each task, not five.
            Group {
                statusSection
                    .errorAlert(errorMessage)
                    .task { await loadPanelContents() }
                    .task { await HotspotJoiner.revalidateLastJoinedSSID() }
                brightnessSection
                modeSection
                colorSection
            }
        } else {
            ownList
        }
    }

    private var ownList: some View {
        List {
            Group {
                statusSection
                brightnessSection
                modeSection
                colorSection
            }
            .rinaTranslucentRows(onDismiss == nil)
        }
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
            LabeledContent("面板") {
                Menu {
                    ForEach(boardStore.boards) { board in
                        Button {
                            switchBoard(to: board)
                        } label: {
                            if isConnected && board.id == currentBoardID {
                                Label(connection.deviceName ?? board.name, systemImage: "checkmark")
                            } else {
                                Text(board.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(boardName)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                }
                .disabled(boardStore.boards.isEmpty || isSwitchingBoard)
                .accessibilityLabel("面板")
                .accessibilityValue(boardName)
                .accessibilityIdentifier("controlCenter.boardSelector")
            }
            LabeledContent("连接状态") {
                // State is never communicated by colour alone (§7, §41).
                Label(connectionStateText, systemImage: connectionStateSymbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(connectionStateTint)
            }
            if let error = connection.lastError, !isConnected {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("connection.failureReason")
            }
            // Embedded (the iPad preview column) the bar is always there: that
            // column is the only place the battery shows on iPad, and a row
            // that appears with the first power report would shift the whole
            // panel. As its own screen it keeps to real readings.
            if isEmbedded || connection.batteryReading != nil {
                BoardBatteryRow()
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
        case .failed(let message): return NSLocalizedString("连接失败", comment: "connection state failed") + "：" + message
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
                    Task { await model.step(face: -1, connection: connection) }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .accessibilityLabel("上一个表情")

                Toggle(isOn: Binding(
                    get: { model.isAutoMode(status: connection.status) },
                    set: { _ in
                        controlTicks += 1
                        Task { await model.toggleAutoMode(connection: connection) }
                    }
                )) {
                    // Glyph + title, so the state never rests on the fill
                    // colour alone (§41).
                    Label(model.isAutoMode(status: connection.status) ? "自动" : "手动",
                          systemImage: model.isAutoMode(status: connection.status)
                                       ? "arrow.triangle.2.circlepath"
                                       : "hand.tap.fill")
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .toggleStyle(.pill)
                .accessibilityLabel("自动模式")

                Button {
                    controlTicks += 1
                    Task { await model.step(face: 1, connection: connection) }
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
                Text(parent.name).tag(String(parent.id))
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
                        Text(swatch.name).tag(swatch.hex)
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
