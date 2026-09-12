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

    /// Optional on purpose. A non-optional `@Environment` object traps during
    /// `DynamicProperty.update()` — before `body` ever reads it — so declaring
    /// it non-optional would crash every `#Preview` and test host that does
    /// not inject the Control Center, even though both call sites that need a
    /// colour could have passed one explicitly.
    @Environment(BoardControlCenterModel.self) private var controlCenter: BoardControlCenterModel?
    @AppStorage(AppSettingsKey.showBoardPhoto) private var showBoardPhoto = true

    private var resolvedColor: Color {
        if let color { return color }
        guard let controlCenter else { return .rinaPink }
        return controlCenter.draftColor
    }

    private var resolvedBrightness: Int {
        brightness ?? controlCenter.map(\.draftBrightness) ?? RinaLinkConstants.brightnessDefault
    }

    var body: some View {
        LEDBoardPreview(frame: frame,
                        color: resolvedColor,
                        brightness: resolvedBrightness,
                        showBoardImage: showBoardPhoto,
                        interaction: interaction,
                        accessibilityDescription: accessibilityDescription)
            .boardPreviewRow(showBoardImage: showBoardPhoto, maxHeight: maxHeight)
            // Zero insets: the row must not bleed past the cell, or the cell
            // clips the board photo at the left and right edges.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

// MARK: - Row sizing

extension View {
    /// Sizes a whole-board `LEDBoardPreview` that sits in a `List` row so the
    /// board is never clipped.
    ///
    /// Width comes from the row, height from that measured width. Deriving the
    /// height any other way (a `maxHeight` cap, or a guess at the container
    /// width) lets the row be *measured* shorter than the board is *drawn* —
    /// the aspect-fit preview then lays out taller than its cell and the photo
    /// is cut off top and bottom. `maxHeight` only binds on very wide layouts
    /// (iPad); there it adds side margins and can never clip the board.
    func boardPreviewRow(showBoardImage: Bool, maxHeight: CGFloat = 420) -> some View {
        modifier(BoardPreviewRowModifier(
            aspectRatio: LEDBoardPreview.wholeBoardAspectRatio(showBoardImage: showBoardImage),
            maxHeight: maxHeight))
    }
}

private struct BoardPreviewRowModifier: ViewModifier {
    let aspectRatio: CGFloat
    let maxHeight: CGFloat
    @State private var width: CGFloat = 0

    private var height: CGFloat? {
        guard width > 0, aspectRatio > 0 else { return nil }
        return min(width / aspectRatio, maxHeight)
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .frame(height: height)
    }
}
