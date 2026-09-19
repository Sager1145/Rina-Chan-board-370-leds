import SwiftUI
import RinaCore

// MARK: - The shared full-board row

/// The whole-board preview that sits at the top of the Control, Text and Live
/// Video tabs (and in Debug): one component, one place, one set of arguments.
///
/// It owns everything those call sites used to repeat — the board-photo
/// setting, the board-global colour and brightness, the row sizing, and the
/// zero list-row insets that keep the photo from being clipped at the cell
/// edges — so a tab only says *what frame* it is showing and *whether that
/// board can be tapped*.
///
/// Must be used directly as a `Section`'s content: it applies `listRow*`
/// modifiers, which only bind on a real row. The caller keeps its own header
/// and footer, since those differ per tab.
struct BoardPreviewRow: View {
    /// The frame to draw.
    var frame: PackedFrame
    /// Tap handling. `.inert` (the default) is a pure display.
    var interaction: LEDBoardInteraction = .inert
    /// Pinch-to-zoom. `.fixed` (the default) leaves the board at 1× and lets
    /// the enclosing list claim touches for a scroll as usual.
    var zoom: LEDBoardZoom = .fixed
    /// Board-global colour. `nil` follows the Control Center's current draft,
    /// which is what the physical board is set to (§16).
    var color: Color? = nil
    /// Raw firmware brightness, 10…200. `nil` follows the Control Center draft.
    var brightness: Int? = nil
    /// Only binds on very wide layouts (iPad); on a phone the width wins, so
    /// raising or lowering it merely changes the side margins there.
    var maxHeight: CGFloat = 420
    /// Overrides the VoiceOver summary; defaults to a lit-count description.
    var accessibilityDescription: String? = nil
    /// Whether this row holds a blank frame while `AppRouter.launchPreviewPending`
    /// is true (user requirement: "刚打开app同步时，完成同步再显示预览画面，不要让预览画面闪一下").
    /// `true` by default; Debug's live-editing preview opts out, since it is
    /// never showing a stale draft/default frame the board is about to
    /// override.
    var holdsForLaunchSync = true

    /// Optional on purpose. A non-optional `@Environment` object traps during
    /// `DynamicProperty.update()` — before `body` ever reads it — so declaring
    /// it non-optional would crash every `#Preview` and test host that does
    /// not inject the Control Center, even though both call sites that need a
    /// colour could have passed one explicitly.
    @Environment(BoardControlCenterModel.self) private var controlCenter: BoardControlCenterModel?
    /// Same reasoning as `controlCenter` above: optional so `#Preview`s and
    /// test hosts that don't inject `AppRouter` don't crash.
    @Environment(AppRouter.self) private var router: AppRouter?
    @AppStorage(AppSettingsKey.showBoardPhoto) private var showBoardPhoto = true

    /// True while the launch gate is holding this row blank.
    private var isHoldingForLaunch: Bool {
        holdsForLaunchSync && (router?.launchPreviewPending ?? false)
    }

    private var resolvedColor: Color {
        if let color { return color }
        guard let controlCenter else { return .rinaPink }
        return controlCenter.draftColor
    }

    private var resolvedBrightness: Int {
        brightness ?? controlCenter.map(\.draftBrightness) ?? RinaLinkConstants.brightnessDefault
    }

    var body: some View {
        let holding = isHoldingForLaunch
        LEDBoardPreview(frame: holding ? PackedFrame() : frame,
                        color: resolvedColor,
                        brightness: resolvedBrightness,
                        showBoardImage: showBoardPhoto,
                        // Always asked for; the preview itself draws the grid
                        // only when no photo is behind the matrix. Without the
                        // photo there is otherwise nothing to show which part
                        // of the board an unlit LED sits in — the face would
                        // float on a blank page.
                        showsUnlitCells: true,
                        // Blank during the launch hold: nothing to tap or
                        // drag on a frame that isn't the board's own yet.
                        interaction: holding ? .inert : interaction,
                        accessibilityDescription: holding ? String(localized: "正在连接") : accessibilityDescription)
            .overlay {
                if holding {
                    ProgressView()
                }
            }
            // Inside the row sizing, so the frame the magnified board is
            // clipped and faded against is the board's own box.
            .boardPreviewZoom(zoom)
            .boardPreviewRow(showBoardImage: showBoardPhoto, maxHeight: maxHeight)
            // Zero insets: the row must not bleed past the cell, or the cell
            // clips the board photo at the left and right edges.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

// MARK: - The shared status line

enum BoardPreviewStatusTone {
    /// Nothing is pending and nothing is live: idle, stopped, disconnected.
    case neutral
    /// What the preview shows is not (yet) what the board shows.
    case pending
    /// The preview is what the board is showing right now.
    case live

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .pending: .orange
        case .live: .green
        }
    }
}

/// The status line that stays under the board preview on the Control, Text,
/// 口型 and 演出 tabs: whether the preview is actually on the physical board,
/// and on the trailing edge the one live number that tab is about.
///
/// Used as the preview `Section`'s footer, and always present — a tab picks
/// *which* state to show, never whether to show one, so the board above it
/// does not shift when the state changes.
struct BoardPreviewStatus<Detail: View>: View {
    private let title: Text
    private let systemImage: String
    private let tone: BoardPreviewStatusTone
    private let detail: Detail

    init(_ title: Text, systemImage: String, tone: BoardPreviewStatusTone,
         @ViewBuilder detail: () -> Detail) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.detail = detail()
    }

    init(_ title: LocalizedStringKey, systemImage: String, tone: BoardPreviewStatusTone,
         @ViewBuilder detail: () -> Detail) {
        self.init(Text(title), systemImage: systemImage, tone: tone, detail: detail)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// One line, or the detail under the state at the accessibility sizes.
    /// Squeezing both into one line there wrapped the state one character per
    /// line and cut the detail to "…".
    ///
    /// Chosen by text size, never by measuring the content: the detail is
    /// live (a frame counter, a mic level), and a layout picked from its
    /// current width would flip between one and two lines as it ticks, making
    /// everything below the footer jump.
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Label { title } icon: { Image(systemName: systemImage) }
                .foregroundStyle(tone.color)
                // The state never wraps mid-word; the detail gives way.
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            detail
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}

extension BoardPreviewStatus where Detail == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, tone: BoardPreviewStatusTone) {
        self.init(title, systemImage: systemImage, tone: tone) { EmptyView() }
    }
}

// MARK: - Whole-board owner status

/// The status line under the preview, driven by whichever feature currently
/// owns board output (`BoardOutputSource`) — not by the tab that happens to
/// be showing it.
///
/// A tab's own status branch still wins while *it* is the owner (it knows
/// more detail than this generic view does); this is only for the case where
/// some other feature owns output, so a tab like 口型同步 stops claiming
/// "未启动" while 演出 is actually playing on the board.
struct BoardOwnerStatus: View {
    var source: BoardOutputSource

    @Environment(BoardConnection.self) private var connection
    @Environment(PresetLiveModel.self) private var presetLiveModel
    @Environment(VideoPlayerModel.self) private var videoModel
    @Environment(LipSyncModel.self) private var lipSyncModel
    @Environment(TextViewModel.self) private var textModel

    var body: some View {
        switch source {
        case .performance:
            let playing = presetLiveModel.isPlaying
            BoardPreviewStatus(titledState(playing ? livePlayingLabel : pausedLabel),
                               systemImage: playing ? "play.circle" : "pause.circle",
                               tone: playing ? .live : .neutral) {
                PresetLiveKeyframeCounterView()
            }
        case .video:
            let playing = videoModel.isPlaying
            BoardPreviewStatus(titledState(playing ? livePlayingLabel : pausedLabel),
                               systemImage: playing ? "play.circle" : "pause.circle",
                               tone: playing ? .live : .neutral) {
                VideoPositionCounterView()
            }
        case .lipSync:
            let running = lipSyncModel.isRunning
            BoardPreviewStatus(titledState(running ? livePlayingLabel : pausedLabel),
                               systemImage: running ? "play.circle" : "pause.circle",
                               tone: running ? .live : .neutral) {
                EmptyView()
            }
        case .text:
            let phase = textModel.phaseKey(connection: connection)
            let (systemImage, tone): (String, BoardPreviewStatusTone) = switch phase {
            case "ACTIVE": ("play.circle", .live)
            case "PAUSED": ("pause.circle", .neutral)
            case "IDLE": ("stop.circle", .neutral)
            default: ("arrow.triangle.2.circlepath.circle", .pending)
            }
            BoardPreviewStatus(titledState(TextViewModel.phaseLabel(phase)), systemImage: systemImage, tone: tone) {
                if textModel.frameCount > 0 {
                    Text("帧 \(textModel.displayIndex + 1) / \(textModel.frameCount)")
                }
            }
        case .automatic:
            BoardPreviewStatus(Text(verbatim: source.title), systemImage: "face.smiling", tone: .live) { EmptyView() }
        case .manual:
            BoardPreviewStatus(Text(verbatim: source.title), systemImage: "face.smiling", tone: .neutral) { EmptyView() }
        case .group, .groupControl, .debug:
            BoardPreviewStatus(Text(verbatim: source.title), systemImage: "rectangle.on.rectangle", tone: .live) { EmptyView() }
        }
    }

    /// `"<owner> · <state>"`, e.g. "演出 · 播放中".
    private func titledState(_ state: String) -> Text {
        Text(verbatim: "\(source.title) · \(state)")
    }

    /// Reuses the Text tab's own "播放中" scroll-phase key (TextViewModel.swift)
    /// so this adds no new localized strings.
    private var livePlayingLabel: String { TextViewModel.phaseLabel("ACTIVE") }
    /// Reuses the Text tab's own "已暂停" scroll-phase key.
    private var pausedLabel: String { TextViewModel.phaseLabel("PAUSED") }
}

// MARK: - Row sizing

extension View {
    /// Sizes a whole-board `LEDBoardPreview` that sits in a `List` row so the
    /// board is never clipped.
    ///
    /// Width comes from the row, height from that same width, in one layout
    /// pass. Both halves matter:
    ///
    /// - The height must be derived from the row's *actual* width. A
    ///   `maxHeight` cap or a guess at the container width lets the row be
    ///   measured shorter than the board is drawn — the aspect-fit preview
    ///   then lays out taller than its cell and the photo is cut off top and
    ///   bottom.
    /// - It must be derived in the same pass, not measured and applied a pass
    ///   later. A late height change lands inside whatever transaction is in
    ///   flight — on a tab switch, the system's — and SwiftUI animates it, so
    ///   the board visibly inflates for a few frames every time a tab appears
    ///   (§13: the board is a physical panel; it must never appear to
    ///   breathe).
    ///
    /// `maxHeight` only binds on very wide layouts (iPad); there it adds side
    /// margins and can never clip the board.
    func boardPreviewRow(showBoardImage: Bool, maxHeight: CGFloat = 420) -> some View {
        BoardPreviewRowLayout(
            aspectRatio: LEDBoardPreview.wholeBoardAspectRatio(showBoardImage: showBoardImage),
            maxHeight: maxHeight
        ) {
            self
        }
    }
}

/// Answers the row's proposal directly instead of measuring itself.
///
/// A `List` row proposes a definite width and no height, which is all this
/// needs: the height *is* the width over the board's aspect ratio. A plain
/// `.frame(maxHeight:)` cannot stand in for the cap — with no proposed height
/// it clamps the cell but still lets the preview lay itself out at its own
/// ideal size, which then overflows the cell.
private struct BoardPreviewRowLayout: Layout {
    let aspectRatio: CGFloat
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, width.isFinite, width > 0, aspectRatio > 0 else {
            // No width to work from (a sizing probe, never a real row): let
            // the preview answer for itself.
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        return CGSize(width: width, height: min(width / aspectRatio, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        // Centred, so the `maxHeight` cap on a wide layout becomes equal side
        // margins rather than a crop.
        subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY),
                      anchor: .center,
                      proposal: ProposedViewSize(bounds.size))
    }
}
