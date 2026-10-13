import SwiftUI

/// The board colour: the phone's parent preset swatches (the same set the
/// phone's Control Center offers), on a crown-scrollable grid.
///
/// The current colour is marked by a ring *outside* the swatch rather than a
/// glyph on top of it — a checkmark alone disappears into a pale swatch, and
/// the ring reads at a glance without hunting.
struct WatchColorPickerView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 44

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: diameter + 8), spacing: 6)] }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(model.snapshot?.controls.presets ?? []) { swatch in
                    let selected = swatch.hex.lowercased() == model.snapshot?.controls.colorHex.lowercased()
                    Button {
                        watchPlaySelectionHaptic()
                        model.setColor(hex: swatch.hex)
                        dismiss()
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch.hex) ?? .accentColor)
                            // A dark swatch on a black screen needs an edge of
                            // its own, or it reads as a hole in the grid.
                            .overlay(Circle().strokeBorder(.white.opacity(0.22)))
                            .frame(width: diameter, height: diameter)
                            .padding(3)
                            .overlay {
                                if selected {
                                    // White, not the accent: the board's
                                    // default colour IS the accent, and an
                                    // accent ring around it vanishes.
                                    Circle().strokeBorder(.white, lineWidth: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("颜色")
    }
}
