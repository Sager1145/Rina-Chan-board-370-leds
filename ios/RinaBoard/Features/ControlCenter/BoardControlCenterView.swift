import SwiftUI
import RinaCore

/// The global Control Center (design guide §5–§11).
///
/// Board-wide state only: status, brightness, previous/next, auto mode,
/// colour and saves. It never keeps its own copy of canonical board state —
/// everything is read from `BoardConnection` and `BoardControlCenterModel`,
/// so a change made here is immediately visible on every tab (§51).
///
/// The same view is used for both presentations: as the expanded sheet behind
/// the iOS 26 tab-bar accessory, and as a pushed screen under Settings on
/// earlier releases.
struct BoardControlCenterView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BoardControlCenterModel.self) private var model
    @Environment(FaceLibraryModel.self) private var faceLibrary
    @Environment(ControlViewModel.self) private var editor

    /// Non-nil when presented as a sheet, so it can offer a Done button.
    var onDismiss: (() -> Void)?

    @AppStorage(AppSettingsKey.hapticsEnabled) private var hapticsEnabled = true

    @State private var isSavingCurrent = false
    /// Bumped by the transport row's own taps. Board-driven state changes must
    /// not buzz the phone — only the user's presses do (§42).
    @State private var controlTicks = 0

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        List {
            statusSection
            brightnessSection
            modeSection
            colorSection
            savesSection
        }
        .navigationTitle("面板控制")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await saveCurrentState() }
                } label: {
                    if isSavingCurrent {
                        ProgressView()
                    } else {
                        Label("保存当前", systemImage: "plus")
                    }
                }
                .disabled(!isConnected || isSavingCurrent)
            }
            if let onDismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onDismiss)
                }
            }
        }
        .task {
            model.loadDefaultsIfNeeded()
            if faceLibrary.faceDocument.faces.isEmpty {
                await faceLibrary.reload(connection: connection)
            }
        }
        .alert("重命名", isPresented: renameBinding, presenting: faceLibrary.renamingFace) { face in
            TextField("名称", text: Bindable(faceLibrary).renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                Task { await faceLibrary.rename(face, to: faceLibrary.renameText, connection: connection) }
            }
        }
    }

    /// §11: saves the Control tab's current draft as a new/updated entry.
    private func saveCurrentState() async {
        isSavingCurrent = true
        defer { isSavingCurrent = false }
        let payload = editor.upsertPayload(using: faceLibrary)
        if case .saved(let id) = await faceLibrary.save(payload, connection: connection) {
            editor.didSave(as: id)
        }
    }

    // MARK: §7.1 Board summary

    private var statusSection: some View {
        Section {
            LabeledContent("面板") {
                Text(boardName).foregroundStyle(.secondary)
            }
            LabeledContent("连接状态") {
                // State is never communicated by colour alone (§7, §41).
                Label(connectionStateText, systemImage: connectionStateSymbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(connectionStateTint)
            }
            if let power = connection.power, let percent = power.batteryPercent {
                LabeledContent("电量") {
                    Label("\(percent)%",
                          systemImage: power.charging == true ? "battery.100percent.bolt" : "battery.100percent")
                        .foregroundStyle(.secondary)
                }
                .accessibilityValue(power.charging == true
                                    ? Text("\(percent)% 充电中")
                                    : Text("\(percent)%"))
            }
            LabeledContent("模式") {
                Text(model.isAutoMode(status: connection.status) ? "自动" : "手动")
                    .foregroundStyle(.secondary)
            }
            if let index = model.effectiveFaceIndex(status: connection.status),
               let count = connection.status?.renderer?.autoFaceCount, count > 0 {
                LabeledContent("当前表情") {
                    Text("\(index + 1) / \(count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let error = model.errorMessage ?? faceLibrary.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var boardName: String {
        connection.status?.device ?? connection.wifi?.hostname ?? "Rina-Chan Board"
    }

    private var connectionStateText: String {
        switch connection.connectionState {
        case .connected: return NSLocalizedString("已连接", comment: "connection state connected")
        case .connecting: return NSLocalizedString("连接中", comment: "connection state connecting")
        case .reconnecting(let attempt):
            return String(format: NSLocalizedString("重连中（第 %lld 次）", comment: "connection state reconnecting"), attempt)
        case .disconnected: return NSLocalizedString("未连接", comment: "connection state disconnected")
        case .failed: return NSLocalizedString("连接失败", comment: "connection state failed")
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
        Section("亮度") {
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
                    in: Double(RinaLinkConstants.brightnessMin)...Double(RinaLinkConstants.brightnessMax),
                    step: 1
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

    private var modeSection: some View {
        Section("面板模式") {
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
                .toggleStyle(.button)
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
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .labelStyle(.titleAndIcon)
            .listRowSeparator(.hidden)
            .disabled(!isConnected)
            .sensoryFeedback(.selection, trigger: controlTicks) { _, _ in hapticsEnabled }

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
        Section("颜色") {
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
            set: { model.selectedParentId = $0 }
        )) {
            ForEach(presets.parents) { parent in
                Text(parent.name).tag(String(parent.id))
            }
        }
        .disabled(!isConnected)

        if let parentId {
            let children = presets.children(of: parentId)
            if !children.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(children, id: \.hex) { child in
                            Button {
                                Task { await model.setColor(hex: child.hex, connection: connection) }
                            } label: {
                                Circle()
                                    .fill(Color(hex: child.hex) ?? .rinaPink)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if isSelectedColor(child.hex) {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                                .shadow(radius: 1)
                                        }
                                    }
                                    .overlay(Circle().strokeBorder(.primary.opacity(isSelectedColor(child.hex) ? 0.8 : 0.15)))
                                    // Inside the label, so the 44pt target is
                                    // the button's own interaction region.
                                    .frame(width: AppLayout.minimumTapTarget, height: AppLayout.minimumTapTarget)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(child.name)
                            .accessibilityAddTraits(isSelectedColor(child.hex) ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .padding(.vertical, 4)
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

    // MARK: §11 Saves

    private var savesSection: some View {
        Section {
            if faceLibrary.isLoading && faceLibrary.faceDocument.faces.isEmpty {
                ProgressView()
            } else if faceLibrary.faceDocument.faces.isEmpty {
                ContentUnavailableView("暂无表情",
                                       systemImage: "square.on.square",
                                       description: Text("连接面板后即可读取已保存的表情。"))
            } else {
                ForEach(faceLibrary.faceDocument.sortedFaces) { face in
                    saveRow(face)
                }
            }
            NavigationLink {
                FaceLibraryView()
            } label: {
                Label("管理表情", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("已保存的表情")
        } footer: {
            Text("轻点以应用到面板。")
        }
    }

    private func saveRow(_ face: SavedFace) -> some View {
        Button {
            Task { await faceLibrary.apply(face, connection: connection) }
        } label: {
            HStack(spacing: 12) {
                if let frame = face.packedFrame {
                    SavedFaceThumbnail(frame: frame, accessibilityDescription: face.name)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(face.name)
                    Text(kindLabel(face.type)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
        .swipeActions(edge: .trailing) {
            if face.type != .default {
                Button("删除", role: .destructive) {
                    Task { await faceLibrary.delete(face, connection: connection) }
                }
            }
        }
        .contextMenu {
            Button("编辑", systemImage: "pencil") { editor.loadForEditing(face) }
            Button("重命名", systemImage: "character.cursor.ibeam") {
                faceLibrary.renamingFace = face
                faceLibrary.renameText = face.name
            }
            if face.type != .default {
                Button("删除", systemImage: "trash", role: .destructive) {
                    Task { await faceLibrary.delete(face, connection: connection) }
                }
            }
        }
    }

    private func kindLabel(_ kind: SavedFace.Kind) -> String {
        switch kind {
        case .default: return NSLocalizedString("默认", comment: "saved face kind default")
        case .custom: return NSLocalizedString("自定义", comment: "saved face kind custom")
        case .parts: return NSLocalizedString("部件", comment: "saved face kind parts")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { faceLibrary.renamingFace != nil },
                set: { if !$0 { faceLibrary.renamingFace = nil } })
    }
}
