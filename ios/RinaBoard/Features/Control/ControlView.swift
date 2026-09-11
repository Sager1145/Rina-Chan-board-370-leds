import SwiftUI
import RinaCore

/// Control tab (FEATURE_INVENTORY §A): live preview, brightness, mode/face,
/// auto-interval, colour, and the scroll-text pipeline.
struct ControlView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(BootLoaderModel.self) private var bootLoader
    @State private var viewModel = ControlViewModel()

    @State private var brightnessFieldText = "50"
    @State private var colorFieldText = "#ec3fc7"

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let error = connection.lastError ?? viewModel.errorMessage {
                        errorBanner(error)
                    }
                    if viewModel.restoreConflict {
                        warningBanner("检测到未发送的本地修改，已保留输入框内容而不是恢复板上的滚动文字。")
                    }
                    previewCard.bootReveal(index: 0)
                    brightnessCard.bootReveal(index: 1)
                    modeFaceCard.bootReveal(index: 2)
                    autoIntervalCard.bootReveal(index: 3)
                    colorCard.bootReveal(index: 4)
                    scrollCard.bootReveal(index: 5)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("控制")
        }
        .onAppear {
            viewModel.loadDefaultsIfNeeded()
            brightnessFieldText = String(Int(viewModel.brightnessDraft))
            colorFieldText = viewModel.colorHexDraft
            bootLoader.beginWaterfall(count: 6)
        }
        .onChange(of: connection.status) { _, status in
            viewModel.syncBrightness(from: status)
            viewModel.syncAutoInterval(from: status)
            viewModel.syncColor(from: status)
            viewModel.syncMode(from: status)
            brightnessFieldText = String(Int(viewModel.brightnessDraft))
            colorFieldText = viewModel.colorHexDraft
        }
        .onChange(of: connection.preview) { _, preview in
            viewModel.observe(preview: preview)
        }
        .onChange(of: connection.connectionState) { _, state in
            if state == .connected {
                Task { await viewModel.restoreOnConnect(connection: connection) }
            }
        }
    }

    // MARK: Banners

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.footnote)
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.15))
        .foregroundStyle(.red)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func warningBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message).font(.footnote)
            Spacer()
        }
        .padding(10)
        .background(Color.yellow.opacity(0.2))
        .foregroundStyle(.orange)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: A1 Live preview

    private var previewCard: some View {
        card {
            LEDMatrixView(
                frame: connection.currentFrame,
                color: Color(hex: viewModel.colorHexDraft) ?? Color(hex: "#f971d4") ?? .pink,
                brightness: Int(viewModel.brightnessDraft)
            )
            .frame(maxHeight: 220)

            HStack {
                Label(viewModel.effectiveMode(status: connection.status) == "auto" ? "自动" : "手动",
                      systemImage: viewModel.effectiveMode(status: connection.status) == "auto" ? "arrow.triangle.2.circlepath" : "hand.tap")
                    .font(.footnote)
                Spacer()
                Text("播放: \(connection.status?.renderer?.playback ?? "—")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("点亮 \(connection.currentFrame.litCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Circle()
                    .fill(isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(isConnected ? "在线" : "离线").font(.footnote)
                if let power = connection.power {
                    Spacer()
                    if let pct = power.batteryPercent {
                        Label("\(pct)%", systemImage: power.charging == true ? "battery.100.bolt" : "battery.100")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: A2 Brightness

    private var brightnessCard: some View {
        card {
            Text("亮度").font(.headline)
            HStack {
                Slider(
                    value: Binding(
                        get: { viewModel.brightnessDraft },
                        set: { newValue in
                            brightnessFieldText = String(Int(newValue))
                            Task { await viewModel.setBrightness(Int(newValue), connection: connection) }
                        }
                    ),
                    in: 10...200,
                    step: 1
                )
                .disabled(!isConnected)
                TextField("亮度", text: $brightnessFieldText)
                    .keyboardType(.numberPad)
                    .frame(width: 52)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitBrightnessField() }
                    .disabled(!isConnected)
            }
            HStack(spacing: 8) {
                Button("−8") { adjustBrightness(-8) }
                Button("+8") { adjustBrightness(8) }
                Button("默认(50)") { Task { await viewModel.setBrightness(50, connection: connection) } }
                Spacer()
            }
            .disabled(!isConnected)
            presetChips([10, 25, 50, 80, 128, 160, 200]) { value in
                Task { await viewModel.setBrightness(value, connection: connection) }
            }
        }
    }

    private func adjustBrightness(_ delta: Int) {
        let next = Int(viewModel.brightnessDraft) + delta
        Task { await viewModel.setBrightness(next, connection: connection) }
    }

    private func commitBrightnessField() {
        guard let value = Int(brightnessFieldText) else {
            brightnessFieldText = String(Int(viewModel.brightnessDraft))
            return
        }
        Task { await viewModel.setBrightness(value, connection: connection) }
    }

    // MARK: A3/A4/A5 Mode, face, auto interval

    private var modeFaceCard: some View {
        card {
            Text("模式与表情").font(.headline)
            HStack {
                Button {
                    Task { await viewModel.toggleMode(connection: connection) }
                } label: {
                    Label(viewModel.effectiveMode(status: connection.status) == "auto" ? "切换为手动" : "切换为自动",
                          systemImage: "arrow.left.arrow.right")
                }
                Spacer()
                Button {
                    Task { await viewModel.step(face: -1, connection: connection) }
                } label: {
                    Image(systemName: "chevron.left.circle")
                }
                Button {
                    Task { await viewModel.step(face: 1, connection: connection) }
                } label: {
                    Image(systemName: "chevron.right.circle")
                }
            }
            .disabled(!isConnected)
        }
    }

    private var autoIntervalCard: some View {
        card {
            Text("自动切换间隔").font(.headline)
            HStack {
                Slider(
                    value: Binding(
                        get: { viewModel.autoIntervalDraft },
                        set: { newValue in Task { await viewModel.setAutoInterval(newValue, connection: connection) } }
                    ),
                    in: 0.5...10,
                    step: 0.1
                )
                Text(String(format: "%.1fs", viewModel.autoIntervalDraft))
                    .font(.footnote.monospacedDigit())
                    .frame(width: 48)
            }
            HStack(spacing: 8) {
                Button("−0.5") { Task { await viewModel.setAutoInterval(viewModel.autoIntervalDraft - 0.5, connection: connection) } }
                Button("+0.5") { Task { await viewModel.setAutoInterval(viewModel.autoIntervalDraft + 0.5, connection: connection) } }
                Spacer()
            }
            presetChips([0.5, 1, 2, 3, 5, 7.5, 10].map { $0 }, format: { String(format: "%.1gs", $0) }) { value in
                Task { await viewModel.setAutoInterval(value, connection: connection) }
            }
            .disabled(!isConnected)
        }
        .disabled(!isConnected)
    }

    // MARK: A6/A7 Colour

    private var colorCard: some View {
        card {
            Text("颜色").font(.headline)
            HStack {
                TextField("#RRGGBB", text: $colorFieldText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitColorField() }
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: viewModel.colorHexDraft) ?? .pink)
                    .frame(width: 32, height: 32)
                ColorPicker("", selection: Binding(
                    get: { Color(hex: viewModel.colorHexDraft) ?? .pink },
                    set: { newColor in
                        let hex = newColor.hexString
                        colorFieldText = hex
                        Task { await viewModel.setColor(hex: hex, connection: connection) }
                    }
                ), supportsOpacity: false)
                .labelsHidden()
            }
            .disabled(!isConnected)

            if let presets = viewModel.colorPresets {
                Menu {
                    ForEach(presets.parents) { parent in
                        Button(parent.name) { viewModel.selectedParentId = String(parent.id) }
                    }
                } label: {
                    Label(currentParentName(presets), systemImage: "paintpalette")
                }
                .disabled(!isConnected)

                if let parentId = viewModel.selectedParentId ?? presets.parents.first.map({ String($0.id) }) {
                    let children = presets.children(of: parentId)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(children, id: \.hex) { child in
                                Button {
                                    colorFieldText = child.hex
                                    Task { await viewModel.setColor(hex: child.hex, connection: connection) }
                                } label: {
                                    VStack(spacing: 4) {
                                        Circle()
                                            .fill(Color(hex: child.hex) ?? .pink)
                                            .frame(width: 28, height: 28)
                                            .overlay(
                                                Circle().stroke(Color.primary, lineWidth: isSelected(child.hex) ? 2 : 0)
                                            )
                                        Text(child.name).font(.caption2).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .disabled(!isConnected)
                }
            }
        }
    }

    private func currentParentName(_ presets: ColorPresets) -> String {
        let id = viewModel.selectedParentId ?? presets.parents.first.map { String($0.id) }
        return presets.parents.first(where: { String($0.id) == id })?.name ?? "颜色分组"
    }

    private func isSelected(_ hex: String) -> Bool {
        RGBHex.parseHex(hex).map { RGBHex.formatHex(r: $0.r, g: $0.g, b: $0.b) } == RGBHex.parseHex(viewModel.colorHexDraft).map { RGBHex.formatHex(r: $0.r, g: $0.g, b: $0.b) }
    }

    private func commitColorField() {
        Task { await viewModel.setColor(hex: colorFieldText, connection: connection) }
    }

    // MARK: A8-A15 Scroll text

    private var scrollCard: some View {
        card {
            Text("滚动文字").font(.headline)
            TextEditor(text: Binding(
                get: { viewModel.scrollText },
                set: { newValue in
                    viewModel.userEditedText = true
                    viewModel.scrollText = ScrollText.truncate(newValue)
                }
            ))
            .frame(minHeight: 80)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            .disabled(!isConnected)

            let visibleChars = ScrollText.visibleCharCount(viewModel.scrollText)
            let byteCount = ScrollText.utf8ByteCount(viewModel.scrollText)
            HStack {
                Text("\(visibleChars)/1000 字符")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(byteCount) 字节")
                    .font(.caption)
                    .foregroundStyle(byteCount > 4096 ? .red : .secondary)
            }
            if byteCount > 4096 {
                warningBanner("文本超过 4096 字节限制，将无法发送")
            }

            HStack {
                Button {
                    Task { await viewModel.sendScroll(connection: connection) }
                } label: {
                    if viewModel.isGeneratingFont {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("发送")
                    }
                }
                .disabled(!isConnected || viewModel.isUploading)

                Button("暂停") { Task { await viewModel.pauseScroll(connection: connection) } }
                    .disabled(!isConnected)
                Button("继续") { Task { await viewModel.resumeScroll(connection: connection) } }
                    .disabled(!isConnected)
                Button("停止/清屏") { Task { await viewModel.stopScroll(connection: connection) } }
                    .disabled(!isConnected)
            }
            .buttonStyle(.bordered)

            HStack {
                Button { Task { await viewModel.stepFrame(direction: -1, connection: connection) } } label: {
                    Image(systemName: "arrow.left")
                }
                Button { Task { await viewModel.stepFrame(direction: 1, connection: connection) } } label: {
                    Image(systemName: "arrow.right")
                }
                Spacer()
            }
            .disabled(!isConnected)

            if viewModel.isUploading {
                ProgressView(value: viewModel.uploadProgress)
            }

            Divider()

            Text("速度 (fps)").font(.subheadline)
            HStack {
                Slider(
                    value: Binding(
                        get: { viewModel.scrollFps },
                        set: { newValue in Task { await viewModel.setScrollFps(newValue, connection: connection) } }
                    ),
                    in: 1...60,
                    step: 1
                )
                Text("\(Int(viewModel.scrollFps))")
                    .font(.footnote.monospacedDigit())
                    .frame(width: 32)
            }
            HStack(spacing: 8) {
                Button("−5") { Task { await viewModel.setScrollFps(viewModel.scrollFps - 5, connection: connection) } }
                Button("+5") { Task { await viewModel.setScrollFps(viewModel.scrollFps + 5, connection: connection) } }
                Button("默认10") { Task { await viewModel.setScrollFps(10, connection: connection) } }
                Spacer()
            }
            presetChips([1, 10, 20, 30, 40, 50, 60].map { Double($0) }, format: { String(Int($0)) }) { value in
                Task { await viewModel.setScrollFps(value, connection: connection) }
            }
            .disabled(!isConnected)

            Divider()

            if let timeline = viewModel.timeline {
                LEDMatrixView(frame: viewModel.previewFrame, showBoardImage: false)
                    .frame(height: 90)
                Text("本地预览 · \(timeline.frameCount) 帧").font(.caption2).foregroundStyle(.secondary)
            }

            let phase = viewModel.localPhase ?? ControlViewModel.phaseLabel(connection.preview.map { $0.firmwareScrollActive == true ? ($0.firmwareScrollPaused == true ? "STEPPING" : "ACTIVE") : "IDLE" })
            HStack {
                Text("状态: \(phase)").font(.footnote)
                Spacer()
                Text("帧 \(viewModel.displayIndex)/\(viewModel.timeline?.frameCount ?? connection.preview?.frameCount ?? 0)")
                    .font(.footnote.monospacedDigit())
            }
            HStack {
                Text(String(format: "实测 %.1f fps", viewModel.measuredFps))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("PLL: \(ControlViewModel.lockStateLabel(viewModel.lockState))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Shared helpers

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func presetChips(_ values: [Int], onSelect: @escaping (Int) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Button("\(value)") { onSelect(value) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func presetChips(_ values: [Double], format: @escaping (Double) -> String, onSelect: @escaping (Double) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Button(format(value)) { onSelect(value) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

#Preview {
    ControlView()
        .environment(BoardConnection())
        .environment(BootLoaderModel())
}
