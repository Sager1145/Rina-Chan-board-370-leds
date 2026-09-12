import SwiftUI
import RinaCore

// MARK: - Interaction

/// How an `LEDBoardPreview` answers touch.
///
/// The mode is an explicit argument rather than an inferred "is there a
/// handler?" so a call site states, in one readable word, whether its board
/// is an editor or a display. The Control tab is the only editable board;
/// Text, Live Video and Debug are all read-outs of state the board owns, and
/// a stray tap on them must fall through to the row underneath (§22.1).
enum LEDBoardInteraction {
    /// Display only: taps pass through to whatever is behind the preview.
    case inert
    /// Tapping a physically present LED calls the handler with its logical index.
    case editable((Int) -> Void)

    var onToggle: ((Int) -> Void)? {
        switch self {
        case .inert: nil
        case .editable(let handler): handler
        }
    }

    var isInteractive: Bool { onToggle != nil }
}

/// The one shared LED board renderer, used by the Control editor, the Text
/// preview, the Live Video placeholder, the face-part thumbnails and Debug
/// (design guide §12: one reusable board rendering module).
///
/// Rendering is a single `Canvas` surface for the whole matrix rather than 370
/// nested SwiftUI views, and a single pair of blur layers rather than 370
/// shadows (§44).
struct LEDBoardPreview: View {
    /// The frame to draw (logical LED index → lit).
    var frame: PackedFrame
    /// Current global board colour. The firmware stores one RGB value for the
    /// whole board, so every lit LED uses it — the UI never implies per-LED
    /// colour (§16).
    var color: Color = .rinaPink
    /// Raw firmware brightness, 10…200.
    var brightness: Int = 50
    /// Draw the photo of the physical board behind the matrix.
    var showBoardImage: Bool = true
    /// Perimeter bloom (§14). Off for small thumbnails, where it only smears.
    var bloom: Bool = true
    /// Draw the unlit LEDs as a faint grid behind the lit ones. Only makes
    /// sense without the board photo, where there is otherwise nothing to show
    /// the matrix an unlit part sits in — an empty thumbnail would read as a
    /// blank tile rather than as a dark board.
    var showsUnlitCells: Bool = false
    /// Draw only this window of the grid, e.g. one eye for a part thumbnail.
    var region: LEDBoardRegion = .wholeBoard
    /// Whether the matrix answers touch: `.editable` makes tapping a
    /// physically valid LED report its logical index, `.inert` (the default)
    /// leaves the preview a pure display.
    var interaction: LEDBoardInteraction = .inert
    /// Overrides the VoiceOver summary; defaults to a lit-count description.
    var accessibilityDescription: String? = nil

    private var usePhoto: Bool { showBoardImage && Self.boardImage != nil }
    private var isInteractive: Bool { interaction.isInteractive }

    /// Very small gap between neighbouring LEDs — the matrix must still read
    /// as a dense physical panel (§13).
    private let gapRatio: CGFloat = 0.16

    var body: some View {
        GeometryReader { geo in
            let layout = usePhoto
                ? LEDBoardLayout.make(in: geo.size, usePhoto: true)
                : LEDBoardLayout.make(in: geo.size, region: region)
            ZStack(alignment: .topLeading) {
                if usePhoto, let image = Self.boardImage {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: layout.stage.width, height: layout.stage.height)
                        .offset(x: layout.stage.minX, y: layout.stage.minY)
                }
                Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                    draw(in: &context, layout: layout)
                }
                .contentShape(Rectangle())
                .accessibilityHidden(true)
            }
            .gesture(tapGesture(layout: layout), including: isInteractive ? .all : .subviews)
        }
        .aspectRatio(LEDBoardLayout.aspectRatio(usePhoto: usePhoto, region: region), contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription ?? defaultAccessibilityLabel)
        .accessibilityAddTraits(isInteractive ? .isButton : [])
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, layout: LEDBoardLayout) {
        guard layout.cell > 0 else { return }
        let intensity = Self.intensity(forBrightness: brightness)

        if bloom {
            let contours = LEDBloomRenderer.contourPath(frame: frame, layout: layout)
            // Bloom keeps a visible floor across the brightness range: even a
            // dim board glows a little, it just never becomes a neon halo.
            LEDBloomRenderer.drawBloom(path: contours,
                                       in: &context,
                                       layout: layout,
                                       color: color,
                                       intensity: 0.35 + 0.65 * intensity)
        }

        // Unlit cells, when asked for: the same squares as the lit ones, in a
        // dim neutral tone so the thumbnail reads as a piece of the board.
        if showsUnlitCells, !usePhoto {
            var unlit = Path()
            for cell in LEDBoardGeometry.cells where !frame[cell.id] {
                guard cell.gridX >= layout.region.x,
                      cell.gridX < layout.region.x + layout.region.width,
                      cell.gridY >= layout.region.y,
                      cell.gridY < layout.region.y + layout.region.height else { continue }
                let rect = layout.ledRect(gridX: cell.gridX, gridY: cell.gridY, gapRatio: gapRatio)
                unlit.addPath(Path(roundedRect: rect, cornerRadius: layout.cell * 0.12))
            }
            context.fill(unlit, with: .color(.primary.opacity(0.10)))
        }

        // Only lit cores are drawn. An unlit LED is fully transparent: no
        // fill, no surface behind it, so the board photo (or whatever is
        // behind the preview) shows through unmodified and no bloom can be
        // mistaken for an unlit LED glowing.
        let litColor = color.opacity(0.45 + 0.55 * intensity)
        let cornerRadius = layout.cell * 0.12

        var lit = Path()
        for cell in LEDBoardGeometry.cells where frame[cell.id] {
            let rect = layout.ledRect(gridX: cell.gridX, gridY: cell.gridY, gapRatio: gapRatio)
            lit.addPath(Path(roundedRect: rect, cornerRadius: cornerRadius))
        }
        context.fill(lit, with: .color(litColor))
    }

    /// Approximate perceived brightness: the firmware's 10…200 range maps to
    /// 0…1, so the preview tracks the physical board without ever going fully
    /// dark at the minimum (§13).
    static func intensity(forBrightness raw: Int) -> Double {
        let clamped = Double(min(200, max(10, raw)))
        return (clamped - 10) / 190
    }

    // MARK: Interaction

    private func tapGesture(layout: LEDBoardLayout) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard let onToggle = interaction.onToggle,
                  let led = layout.ledIndex(at: value.location) else { return }
            onToggle(led)
        }
    }

    private var defaultAccessibilityLabel: String {
        String(format: NSLocalizedString("面板预览，%1$lld/%2$lld 颗 LED 点亮",
                                         comment: "LED board preview accessibility summary"),
               frame.litCount, PackedFrame.ledCount)
    }

    // MARK: Resources

    private static let boardImage: UIImage? = {
        guard let url = Bundle.main.url(forResource: "rinaboard", withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }()

    /// The aspect ratio a whole-board preview lays itself out at for the
    /// given photo setting, resolved the same way `body` does (a missing photo
    /// falls back to the bare grid), so callers can size a row to match.
    static func wholeBoardAspectRatio(showBoardImage: Bool) -> CGFloat {
        LEDBoardLayout.aspectRatio(usePhoto: showBoardImage && boardImage != nil, region: .wholeBoard)
    }
}

#Preview("Bloom over the board photo") {
    var frame = PackedFrame()
    // A filled block plus a ring, to show connected-region bloom and a hole.
    for y in 3...7 {
        for x in 3...8 {
            if let led = MatrixGeometry.ledIndex(x: x, y: y) { frame[led] = true }
        }
    }
    for y in 3...9 {
        for x in 13...18 where y == 3 || y == 9 || x == 13 || x == 18 {
            if let led = MatrixGeometry.ledIndex(x: x, y: y) { frame[led] = true }
        }
    }
    return LEDBoardPreview(frame: frame, brightness: 160, interaction: .editable { _ in })
        .padding()
}
