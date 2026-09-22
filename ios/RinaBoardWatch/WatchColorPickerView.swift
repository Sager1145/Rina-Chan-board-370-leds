import SwiftUI

/// The board colour: the phone's parent preset swatches (the same set the
/// phone's Control Center offers), on a crown-scrollable grid.
struct WatchColorPickerView: View {
    @Environment(WatchSessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.snapshot?.controls.presets ?? []) { swatch in
                    let selected = swatch.hex.lowercased() == model.snapshot?.controls.colorHex.lowercased()
                    Button {
                        model.setColor(hex: swatch.hex)
                        dismiss()
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch.hex) ?? .pink)
                            .frame(width: 44, height: 44)
                            .overlay {
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("颜色")
    }
}
