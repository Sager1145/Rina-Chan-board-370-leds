import SwiftUI
import RinaCore

/// The small saved-face row thumbnail shared by the Faces list and the
/// Control Center's Saves section (§11, §63): one component owns the tile
/// size, corner radius and the board-global colour/brightness source, so a
/// caller only says which frame to draw and what VoiceOver should read.
struct SavedFaceThumbnail: View {
    /// The frame to draw. Callers keep their own handling of a face with
    /// no packed frame, because they differ on what to show instead.
    var frame: PackedFrame
    /// VoiceOver summary; differs per list.
    var accessibilityDescription: String

    /// The tile's size, exposed so a caller's empty-state placeholder can
    /// line up with a real thumbnail.
    static let size = CGSize(width: 44, height: 36)
    private static let cornerRadius: CGFloat = 6

    /// Optional for the same reason as `BoardPreviewRow`: a non-optional
    /// `@Environment` object traps during `DynamicProperty.update()`, before
    /// `body` runs, so it would crash any `#Preview` that does not inject the
    /// Control Center.
    @Environment(BoardControlCenterModel.self) private var controlCenter: BoardControlCenterModel?

    var body: some View {
        LEDBoardPreview(frame: frame,
                        color: controlCenter?.draftColor ?? .rinaPink,
                        brightness: controlCenter?.draftBrightness ?? RinaLinkConstants.brightnessDefault,
                        showBoardImage: false,
                        bloom: false,
                        accessibilityDescription: accessibilityDescription)
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }
}
