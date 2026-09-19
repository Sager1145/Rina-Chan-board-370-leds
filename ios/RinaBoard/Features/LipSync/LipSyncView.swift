import SwiftUI
import RinaCore

/// 口型同步 tab: the microphone drives the board's mouth in real time.
///
/// Laid out the way upstream's 口型同步 page is — a live face, one big
/// start/stop control, then the recognition options and the calibration — and
/// the way every other tab in this app is: a `List` of `Section`s under a
/// hidden navigation bar, with the whole-board preview as the first row.
struct LipSyncView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(LipSyncModel.self) private var model
    @Environment(BoardControlCenterModel.self) private var controlCenter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isMouthMappingPresented = false

    private var isConnected: Bool { connection.connectionState == .connected }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            BoardSplitPage {
                previewBoard
            } status: {
                previewStatus
            } controls: {
                transportSection
                recognitionSection(model: $model)
                calibrationSection
                if let message = model.loadError {
                    loadErrorSection(message)
                }
                // Last on every layout: the editor is a detour off this page,
                // not one of its options.
                Section {
                    // Not gated like the options: the mapping can be edited
                    // while sync runs, and the preview reflects it immediately.
                    mouthMappingLink
                }
            }
            .listSectionSpacing(.compact)
            .rinaScrollBackground()
            .errorAlert($model.errorMessage)
            .navigationTitle("口型同步")
            .toolbar(.hidden, for: .navigationBar)
            .contentMargins(.top, 0, for: .scrollContent)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewBoard: some View {
        BoardPreviewRow(frame: model.previewFrame,
                        accessibilityDescription: previewAccessibilityDescription)
    }

    @ViewBuilder
    private var previewStatus: some View {
        // The mouth on the board and the level driving it, the two numbers the
        // sensitivity slider is tuned against.
        let level: Text? = model.isRunning
            ? Text(verbatim: "\(vowelLabel(model.vowel)) · ")
                + Text(String(format: NSLocalizedString("%.0f dB", comment: "microphone level in decibels"),
                              Double(model.volumeDb)))
                    .foregroundStyle(model.volumeDb >= model.sensitivityDb ? Color.accentColor : .secondary)
            : nil
        if model.isRunning && isConnected {
            BoardPreviewStatus("正在输出到面板", systemImage: "dot.radiowaves.left.and.right", tone: .live) {
                level
            }
        } else if model.isRunning {
            BoardPreviewStatus("仅本地预览", systemImage: "iphone", tone: .pending) {
                level
            }
        } else if isConnected, let source = connection.output.source, source != .lipSync {
            // Some other feature owns board output right now (e.g. 演出 is
            // playing): show the board's real mode instead of "未启动".
            BoardOwnerStatus(source: source)
        } else {
            // Idle: the threshold a voice has to clear, so it can be tuned
            // before starting.
            let threshold = Text(String(format: NSLocalizedString("灵敏度 %.0f dB",
                                                                  comment: "lip sync microphone threshold"),
                                        Double(model.sensitivityDb)))
            if !isConnected {
                BoardPreviewStatus("未连接", systemImage: "circle.slash", tone: .neutral) { threshold }
            } else {
                BoardPreviewStatus("未启动", systemImage: "stop.circle", tone: .neutral) { threshold }
            }
        }
    }

    private var previewAccessibilityDescription: String {
        String(format: NSLocalizedString("口型同步预览，当前口型 %@", comment: "lip sync preview accessibility summary"),
               vowelLabel(model.vowel))
    }

    /// Vowels are shown in kana, the alphabet upstream's phoneme set is named
    /// in, with the romaji beside it so the mapping to a/i/u/e/o is visible.
    private func vowelLabel(_ vowel: LipSyncVowel?) -> String {
        guard let vowel else { return NSLocalizedString("闭嘴", comment: "lip sync: mouth closed / silence") }
        switch vowel {
        case .a: return "あ (a)"
        case .i: return "い (i)"
        case .u: return "う (u)"
        case .e: return "え (e)"
        case .o: return "お (o)"
        }
    }

    // MARK: Transport

    @ViewBuilder
    private var transportSection: some View {
        Section {
            Button {
                if model.isRunning {
                    model.stop(connection: connection)
                } else {
                    Task { await model.start(connection: connection) }
                }
            } label: {
                Label(model.isRunning
                        ? NSLocalizedString("停止同步", comment: "stop lip sync")
                        : NSLocalizedString("开始同步", comment: "start lip sync"),
                      systemImage: model.isRunning ? "stop.circle.fill" : "mic.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill)
            .tint(model.isRunning ? .red : .accentColor)
            // Disconnection gates *starting*, never stopping. This one button
            // owns the microphone, so greying it out while the mic is open
            // would leave the user no way to close it — the board going away
            // is a reason to stop, not a reason to be unable to.
            .disabled(model.isRunning ? false : (!isConnected || model.isCalibrating || model.isStarting || model.library == nil))
            .pillButtonRow()
        }

        // Separate section: the pill row clears its cell background, so
        // sharing a section with ordinary rows left a broken card under it.
        Section {
            if model.isRunning || model.isCalibrating {
                levelMeter
                if model.isRunning { vowelReadout }
            }
        } footer: {
            if case .denied = model.permission {
                Text("麦克风权限已被拒绝，请在系统「设置」中允许 RinaBoard 使用麦克风。")
            }
        }
    }

    /// A plain bar from −60 dB to 0 dB with the sensitivity threshold marked,
    /// so "why is it not reacting" is answerable by looking at it.
    private var levelMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(model.volumeDb >= model.sensitivityDb ? Color.accentColor : Color.secondary)
                        .frame(width: width * meterFraction(model.volumeDb))
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2)
                        .offset(x: width * meterFraction(model.sensitivityDb))
                }
            }
            .frame(height: 10)
            Text("音量 / 灵敏度阈值")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("麦克风音量", comment: "microphone level meter"))
        .accessibilityValue(String(format: NSLocalizedString("%.0f dB", comment: "microphone level in decibels"),
                                   Double(model.volumeDb)))
    }

    private func meterFraction(_ db: Float) -> CGFloat {
        CGFloat(min(1, max(0, (Double(db) + 60) / 60)))
    }

    /// All five vowels at once, the current one filled in. Upstream shows the
    /// per-vowel ratios; this is the same information at a glance — which
    /// vowel won, and whether the raw read-out is fighting the debounce.
    private var vowelReadout: some View {
        HStack(spacing: 8) {
            ForEach(LipSyncVowel.allCases, id: \.self) { vowel in
                let isCurrent = model.vowel == vowel
                Text(vowelLabel(vowel))
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background {
                        Capsule().fill(isCurrent ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
                    }
                    .overlay {
                        // A hollow ring marks the pre-smoothing guess when it
                        // disagrees with what is actually on the board.
                        if model.rawVowel == vowel && !isCurrent {
                            Capsule().strokeBorder(Color.secondary, lineWidth: 1)
                        }
                    }
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            }
        }
        // Five chips in one line: past the largest standard size they no
        // longer fit a phone width, so the row stops growing there.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(maxWidth: .infinity)
    }

    // MARK: Recognition options

    private func recognitionSection(model: Bindable<LipSyncModel>) -> some View {
        Section {
            recognitionOptions(model: model)
                .disabled(!self.model.canEditOptions)
        }
    }

    private func recognitionOptions(model: Bindable<LipSyncModel>) -> some View {
        Group {
            Picker("识别模型", selection: model.preset) {
                ForEach(LipSyncVoicePreset.allCases, id: \.self) { preset in
                    Text(presetName(preset)).tag(preset)
                }
            }

            VStack(alignment: .leading) {
                LabeledContent("麦克风灵敏度") {
                    Text(String(format: NSLocalizedString("%.0f dB", comment: "microphone level in decibels"),
                                Double(self.model.sensitivityDb)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(self.model.sensitivityDb) },
                                      set: { self.model.sensitivityDb = Float($0) }),
                       in: -70...(-10), step: 1)
            }

            VStack(alignment: .leading) {
                LabeledContent("刷新速率") {
                    Text(String(format: NSLocalizedString("%.0f Hz", comment: "lip sync refresh rate"),
                                self.model.refreshRateHz))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: model.refreshRateHz, in: 10...60, step: 5)
            }

            Stepper(value: model.smoothing, in: 1...12) {
                LabeledContent("防抖帧数") {
                    Text("\(self.model.smoothing)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func presetName(_ preset: LipSyncVoicePreset) -> String {
        switch preset {
        case .standard: return NSLocalizedString("标准", comment: "lip sync preset: standard voice")
        case .male: return NSLocalizedString("男声", comment: "lip sync preset: male voice")
        case .female: return NSLocalizedString("女声", comment: "lip sync preset: female voice")
        case .anime: return NSLocalizedString("动画", comment: "lip sync preset: anime voice")
        }
    }

    // MARK: Calibration

    private var calibrationSection: some View {
        Section {
            ForEach(LipSyncVowel.allCases, id: \.self) { vowel in
                HStack {
                    Text(vowelLabel(vowel))
                    if model.profile.isCalibrated(vowel) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel(NSLocalizedString("已校准", comment: "vowel has been calibrated"))
                    }
                    Spacer()
                    if model.calibratingVowel == vowel {
                        ProgressView(value: model.calibrationProgress)
                            .frame(width: 80)
                        Button(NSLocalizedString("取消", comment: "cancel calibration")) {
                            model.cancelCalibration()
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button(NSLocalizedString("校准", comment: "calibrate one vowel")) {
                            model.calibrate(vowel)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.canEditOptions)
                    }
                }
            }

            Button(NSLocalizedString("恢复默认声音模型", comment: "reset lip sync calibration"), role: .destructive) {
                model.resetCalibration()
            }
            .disabled(!model.canEditOptions || model.profile.calibrated.isEmpty)
        } header: {
            Text("校准")
        }
    }

    // MARK: Mouth mapping

    /// On a phone the editor is pushed with its own board preview. On iPad the
    /// pinned board in the left column already shows the same frame, so the
    /// editor pops over the controls column without a second preview.
    @ViewBuilder
    private var mouthMappingLink: some View {
        if let library = model.library {
            if BoardPageColumns.isSplit(horizontalSizeClass) {
                Button {
                    isMouthMappingPresented = true
                } label: {
                    HStack {
                        Text("口型与造型")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                    .contentShape(Rectangle())
                }
                // The row is last on the page, so it opens upward over the
                // controls column; a sideways popover would cover the board
                // it relies on.
                .popover(isPresented: $isMouthMappingPresented, arrowEdge: .bottom) {
                    // Ideal, not fixed: in a short window the system shrinks
                    // the popover, and a fixed 600 pt list was clipped there
                    // instead of scrolling to its last rows.
                    mouthMappingView(library: library, showsPreview: false)
                        .frame(idealWidth: 400, maxWidth: 400, idealHeight: 600, maxHeight: 600)
                        .presentationCompactAdaptation(.popover)
                }
            } else {
                NavigationLink {
                    mouthMappingView(library: library, showsPreview: true)
                } label: {
                    Text("口型与造型")
                }
            }
        }
    }

    private func mouthMappingView(library: PartsLibrary, showsPreview: Bool) -> some View {
        LipSyncMouthMappingView(library: library,
                                color: controlCenter.draftColor,
                                brightness: controlCenter.draftBrightness,
                                showsPreview: showsPreview)
    }

    // MARK: Errors

    /// The parts library failing to load is permanent for this launch, so it
    /// stays on the page; transient errors are alerts.
    private func loadErrorSection(_ message: String) -> some View {
        Section {
            Text(message)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Mouth & costume editor

/// The per-vowel mouth picker plus the eyes/cheeks worn during sync.
///
/// Reuses `FacePartSelectorView`, the same row the Control tab composes faces
/// with, so a mouth is chosen here exactly the way it is chosen there.
struct LipSyncMouthMappingView: View {
    let library: PartsLibrary
    let color: Color
    let brightness: Int
    /// False in the iPad popover, where the pinned board beside it is the preview.
    var showsPreview = true

    @Environment(LipSyncModel.self) private var model

    var body: some View {
        @Bindable var model = model

        // The board stays pinned above the list, like the iPad preview
        // column, so it never scrolls away while the parts below are picked.
        VStack(spacing: 0) {
            if showsPreview {
                BoardPreviewRow(frame: model.previewFrame,
                                color: color,
                                brightness: brightness,
                                accessibilityDescription: NSLocalizedString("口型预览",
                                                                            comment: "mouth mapping preview"))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }
            partsList
        }
        .rinaScrollBackground()
        .navigationTitle("口型与造型")
        .toolbarTitleDisplayMode(.inline)
    }

    private var partsList: some View {
        List {
            Group {

                Section {
                    HStack(spacing: 8) {
                        Button {
                            model.randomize()
                        } label: {
                            CommandChip("随机", systemImage: "dice.fill")
                        }
                        .buttonStyle(.pill)

                        Toggle(isOn: Binding(
                            get: { model.syncEyes },
                            set: { model.setSyncEyes($0) }
                        )) {
                            CommandChip("镜像", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        }
                        .toggleStyle(.pill)

                        Button {
                            model.resetMappingAndCostume()
                        } label: {
                            CommandChip("恢复默认", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.pill)
                    }
                    .pillButtonRow()
                }

                Section(NSLocalizedString("闭嘴（静音）", comment: "silence mouth section")) {
                    selector(for: nil)
                }

                ForEach(LipSyncVowel.allCases, id: \.self) { vowel in
                    Section(vowelTitle(vowel)) {
                        selector(for: vowel)
                    }
                }

                Section(PartGroup.leye.displayName) {
                    costumeSelector(group: .leye)
                }
                Section(PartGroup.reye.displayName) {
                    costumeSelector(group: .reye)
                }
                Section(PartGroup.cheek.displayName) {
                    costumeSelector(group: .cheek)
                }
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .contentMargins(.top, showsPreview ? 4 : 12, for: .scrollContent)
    }

    private func vowelTitle(_ vowel: LipSyncVowel) -> String {
        switch vowel {
        case .a: return "あ (a)"
        case .i: return "い (i)"
        case .u: return "う (u)"
        case .e: return "え (e)"
        case .o: return "お (o)"
        }
    }

    private func selector(for vowel: LipSyncVowel?) -> some View {
        FacePartSelectorView(group: .mouth,
                             library: library,
                             selectedId: model.mapping.mouthId(for: vowel),
                             color: color,
                             brightness: brightness) { id in
            model.setMouthId(id, for: vowel)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
    }

    private func costumeSelector(group: PartGroup) -> some View {
        FacePartSelectorView(group: group,
                             library: library,
                             selectedId: model.baseCall[group],
                             color: color,
                             brightness: brightness) { id in
            model.setCostumePart(id, for: group)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
    }
}

// No #Preview: both views need a live `BoardConnection` and a `LipSyncModel`
// that opens the microphone, neither of which a canvas preview can supply.
