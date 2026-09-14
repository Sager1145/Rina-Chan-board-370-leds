import SwiftUI
import RinaCore

/// Face-part selector (design guide §19, §20).
///
/// One row per face region, read from the shipped part definitions — names and
/// counts are never invented here. Each option shows a small LED preview of
/// the actual LEDs it lights plus its number, and option 0 is always the
/// empty/disabled variant, matching WebUI semantics (§62).
struct FacePartSelectorView: View {
    let group: PartGroup
    let library: PartsLibrary
    let selectedId: String?
    let color: Color
    let brightness: Int
    let onSelect: (String) -> Void

    /// Side of every thumbnail's grid window, in LED cells. The standard part
    /// box is 8×8 (eyes, mouth); the cheeks are 4×4 and are centred in the same
    /// window rather than getting a smaller one, so all rows read alike.
    private static let windowSide = 8

    /// Thumbnails show only the part's own area of the board, taken from the
    /// group's layout boxes, instead of shrinking all 370 LEDs into 58 points.
    private var region: LEDBoardRegion {
        guard let box = library.layout[group.partType]?.first else { return .wholeBoard }
        return LEDBoardRegion.window(around: (x: box.x, y: box.y, w: box.w, h: box.h),
                                     side: Self.windowSide)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(library.ids(for: group).enumerated()), id: \.element) { index, id in
                        option(id: id, number: index)
                            .id(id)
                    }
                }
                .padding(.vertical, 6)
                // Callers inset the row 16pt on the leading side only; mirror
                // it at the end so the last option's selection border isn't
                // cut off by the row's trailing edge.
                .padding(.trailing, 16)
            }
            .scrollClipDisabled()
            .onChange(of: selectedId, initial: true) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func option(id: String, number: Int) -> some View {
        let part = library.resolvedPart(group: group, id: id)
        let isSelected = id == selectedId
        return Button {
            onSelect(id)
        } label: {
            VStack(spacing: 4) {
                LEDBoardPreview(frame: library.frame(for: part),
                                color: color,
                                brightness: brightness,
                                showBoardImage: false,
                                bloom: false,
                                showsUnlitCells: true,
                                region: region,
                                accessibilityDescription: "")
                    // The window is square, so the tile is too; padding the
                    // preview before the background makes the tile hug the
                    // grid and leaves the same margin on all four sides.
                    .padding(3)
                    .background {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.primary.opacity(0.05))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .frame(width: 52, height: 52)
                Text("\(number)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .padding(5)
            .background {
                RoundedRectangle(cornerRadius: 11)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(number == 0
                            ? Text("\(group.displayName)，空")
                            : Text("\(group.displayName) \(number)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
