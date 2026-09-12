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
    /// The board answers touch with two distinct reports, because a tap and a
    /// stroke mean different things to an editor (§16):
    ///
    /// - `onTap`: a finger lifted without leaving the LED it landed on.
    /// - `onDrag`: a finger moving across the board, once per LED it crosses
    ///   in that stroke — including the LED the stroke started on.
    ///
    /// A touch is exactly one of the two, never both. The preview only
    /// reports *where*; the Control tab decides that a tap toggles and a
    /// stroke paints its brush value.
    case editable(onTap: (Int) -> Void, onDrag: (Int) -> Void)

    var handlers: (onTap: (Int) -> Void, onDrag: (Int) -> Void)? {
        switch self {
        case .inert: nil
        case .editable(let onTap, let onDrag): (onTap, onDrag)
        }
    }

    var isInteractive: Bool { handlers != nil }
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
    /// Whether the matrix answers touch: `.editable` reports taps and drag
    /// strokes on physically valid LEDs separately, `.inert` (the default)
    /// leaves the preview a pure display.
    var interaction: LEDBoardInteraction = .inert
    /// Overrides the VoiceOver summary; defaults to a lit-count description.
    var accessibilityDescription: String? = nil

    /// LEDs already reported during the stroke in progress, so a finger that
    /// wanders back over a cell cannot report it twice — with a paint brush
    /// that is invisible, but the handler is free to count edits.
    @State private var paintedThisStroke: Set<Int> = []
    /// Where the previous touch sample of this stroke landed. `nil` until the
    /// touch has moved far enough to be a stroke — until then it may still be
    /// a tap, and nothing has been reported.
    @State private var lastPaintPoint: CGPoint?
    /// A pinch joined this touch at some point. The touch is then neither a
    /// stroke nor a tap for the rest of its life, even after the second
    /// finger lifts.
    @State private var strokeWasSuspended = false
    /// The newest touch sample, held back until the next one arrives (see
    /// `paintGesture`).
    @State private var pendingSample: StrokeSample?
    /// True only while a stroke is in flight. `@GestureState` resets itself
    /// when the gesture ends *or is cancelled* — the enclosing `List` can
    /// still claim the touch as a scroll — which is what makes it, rather
    /// than an `onEnded` that a cancelled stroke never reaches, the honest
    /// signal to forget the stroke.
    @GestureState private var isStroking = false
    /// True while two fingers are zooming or panning this preview
    /// (`BoardPreviewZoom`). A second finger landing on the board means
    /// "zoom", so the stroke that the first finger started must stop
    /// reporting LEDs rather than paint a line along under the moving fingers.
    @Environment(\.ledBoardPaintingSuspended) private var paintingSuspended
    /// The same signal by reference, set in the very touch event the second
    /// finger lands in. The environment value above only arrives with the
    /// next view update — one touch sample late, and that sample is the one
    /// that can jump across the board.
    @Environment(\.ledBoardPaintSuspension) private var paintSuspension

    private var isPaintingSuspended: Bool {
        paintingSuspended || paintSuspension?.isSuspended == true
    }

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
            .gesture(paintGesture(layout: layout), including: isInteractive ? .all : .subviews)
        }
        .aspectRatio(LEDBoardLayout.aspectRatio(usePhoto: usePhoto, region: region), contentMode: .fit)
        .onChange(of: isStroking) { _, stroking in
            guard !stroking else { return }
            resetStroke()
        }
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
            // A cropped window (a part thumbnail) fills its whole rectangle,
            // including grid positions where no LED physically exists: the
            // cheek window reaches into rows 13–14, which are two cells
            // narrower, so drawing only real LEDs would leave a notch in the
            // tile's corner. These filler squares are purely visual — they
            // carry no LED index, so hit testing and the frame are untouched.
            let region = layout.region
            let fillsWholeWindow = region != .wholeBoard
            var unlit = Path()
            for gridY in region.y..<(region.y + region.height) {
                for gridX in region.x..<(region.x + region.width) {
                    if let led = LEDBoardGeometry.ledIndex(gridX: gridX, gridY: gridY) {
                        guard !frame[led] else { continue }
                    } else {
                        guard fillsWholeWindow else { continue }
                    }
                    let rect = layout.ledRect(gridX: gridX, gridY: gridY, gapRatio: gapRatio)
                    unlit.addPath(Path(roundedRect: rect, cornerRadius: layout.cell * 0.12))
                }
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

    /// How far, in LED cells, a finger may wander and still count as a tap.
    /// Measured in cells rather than points so the threshold stays one LED's
    /// worth of jitter at any magnification.
    static let tapSlopInCells: CGFloat = 0.6

    /// One zero-distance drag carries both taps and strokes, so they can never
    /// both fire for the same touch.
    ///
    /// The touch stays a *possible tap* until it moves past
    /// `tapSlopInCells`. Crossing that line makes it a stroke: the LED it
    /// landed on is reported first, then every LED along the path — drawing a
    /// face is one stroke instead of 370 taps. A touch that lifts without
    /// ever crossing it is a tap on the LED it landed on. A cancelled touch
    /// (no `onEnded`) or one a pinch joined reports nothing further.
    ///
    /// Each sample is applied one touch event late. The pinch recognizer sits
    /// on the window, and UIKit can hand this drag the event a second finger
    /// lands in *before* that recognizer has flagged the suspension — and in
    /// that event the drag's location can already have moved toward the
    /// fingers' midpoint. By the time the next event arrives, the previous
    /// one has reached every recognizer, so a held sample is checked against
    /// a suspension flag that is known to be current and dropped if a pinch
    /// began in it. A distance cap would not do: a fast flick, or samples
    /// coalesced while the main thread draws, legitimately jump several
    /// cells, and a pinch's midpoint jump can be shorter than any cap.
    private func paintGesture(layout: LEDBoardLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isStroking) { _, stroking, _ in stroking = true }
            .onChanged { value in
                guard interaction.isInteractive else { return }
                if isPaintingSuspended {
                    strokeWasSuspended = true
                    pendingSample = nil
                }
                guard !strokeWasSuspended else { return }
                if let pendingSample { advanceStroke(to: pendingSample, layout: layout) }
                pendingSample = StrokeSample(value)
            }
            .onEnded { value in
                defer { resetStroke() }
                // The finger has lifted, so no later event is coming to vouch
                // for the held sample: the final location is applied now. It
                // covers the held sample's movement too — the path is
                // interpolated from the last applied point.
                if !strokeWasSuspended, !isPaintingSuspended {
                    advanceStroke(to: StrokeSample(value), layout: layout)
                }
                // Translation is checked as well as `lastPaintPoint` so the
                // decision rests on the gesture's own value, not only on
                // state a cleanup elsewhere might already have cleared.
                guard lastPaintPoint == nil,
                      !strokeWasSuspended, !isPaintingSuspended,
                      Self.distance(value.translation) < layout.cell * Self.tapSlopInCells,
                      let onTap = interaction.handlers?.onTap,
                      let led = layout.ledIndex(at: value.startLocation) else { return }
                onTap(led)
            }
    }

    /// One touch sample, reduced to what a stroke needs from it.
    private struct StrokeSample {
        var location: CGPoint
        var startLocation: CGPoint
        var translation: CGSize

        init(_ value: DragGesture.Value) {
            location = value.location
            startLocation = value.startLocation
            translation = value.translation
        }
    }

    /// Applies one sample: while the touch is still a possible tap it only
    /// checks the slop; once it is a stroke it reports every LED between the
    /// last applied point and this one.
    private func advanceStroke(to sample: StrokeSample, layout: LEDBoardLayout) {
        guard let onDrag = interaction.handlers?.onDrag else { return }
        let from: CGPoint
        if let lastPaintPoint {
            from = lastPaintPoint
        } else {
            guard Self.distance(sample.translation) >= layout.cell * Self.tapSlopInCells else { return }
            // Just became a stroke: it starts where the finger landed, not
            // where it was when the slop ran out.
            if let led = layout.ledIndex(at: sample.startLocation),
               paintedThisStroke.insert(led).inserted {
                onDrag(led)
            }
            from = sample.startLocation
        }
        for point in Self.strokeSamples(from: from, to: sample.location, step: layout.cell / 2) {
            guard let led = layout.ledIndex(at: point),
                  paintedThisStroke.insert(led).inserted else { continue }
            onDrag(led)
        }
        lastPaintPoint = sample.location
    }

    private func resetStroke() {
        paintedThisStroke.removeAll()
        lastPaintPoint = nil
        pendingSample = nil
        strokeWasSuspended = false
    }

    private static func distance(_ translation: CGSize) -> CGFloat {
        (translation.width * translation.width + translation.height * translation.height).squareRoot()
    }

    /// The points to test along one touch sample's movement: `from` exclusive
    /// (the previous sample already reported it) through `to` inclusive.
    ///
    /// Touch samples arrive several cells apart during a fast stroke, so
    /// testing only where the finger was *seen* would leave gaps in the line
    /// it visibly drew. A `nil` `from` is the finger-down sample, which is
    /// just the one point.
    static func strokeSamples(from: CGPoint?, to: CGPoint, step: CGFloat) -> [CGPoint] {
        guard let from, step > 0 else { return [to] }
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let count = max(1, Int((distance / step).rounded(.up)))
        return (1...count).map { index in
            let t = CGFloat(index) / CGFloat(count)
            return CGPoint(x: from.x + dx * t, y: from.y + dy * t)
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
    return LEDBoardPreview(frame: frame, brightness: 160, interaction: .editable(onTap: { _ in }, onDrag: { _ in }))
        .padding()
}
