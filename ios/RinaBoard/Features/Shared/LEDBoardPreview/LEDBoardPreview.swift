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
    ///
    /// `onPencilHover`, when given, hears which LED an Apple Pencil is
    /// hovering over (Pencil 2 on M2+ iPads, Pencil Pro), and `nil` as soon as
    /// it hovers over none — including the moment it leaves hover range or
    /// touches down. The preview draws that LED at half brightness by itself;
    /// the handler is for mirroring it anywhere else. `pencilHoverMirror`,
    /// when it answers, names a second LED to draw at half brightness with it
    /// (its mirror, while the drawing 镜像 is on).
    ///
    /// With a hover handler, an Apple Pencil taps on touch-down rather than
    /// on lift: `onTap` fires the moment the tip lands, and a stroke that
    /// follows starts painting from the next LED it crosses.
    case editable(onTap: (Int) -> Void,
                  onDrag: (Int) -> Void,
                  onPencilHover: ((Int?) -> Void)? = nil,
                  pencilHoverMirror: ((Int) -> Int?)? = nil)

    var handlers: (onTap: (Int) -> Void, onDrag: (Int) -> Void)? {
        switch self {
        case .inert: nil
        case .editable(let onTap, let onDrag, _, _): (onTap, onDrag)
        }
    }

    var pencilHoverHandler: ((Int?) -> Void)? {
        switch self {
        case .inert: nil
        case .editable(_, _, let onPencilHover, _): onPencilHover
        }
    }

    var pencilHoverMirror: ((Int) -> Int?)? {
        switch self {
        case .inert: nil
        case .editable(_, _, _, let mirror): mirror
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
    /// The LED an Apple Pencil is hovering over, drawn at half brightness.
    @State private var pencilHoverLED: Int?
    /// Where an Apple Pencil now on the glass landed, as the window-level
    /// tracker saw it. On its own it edits nothing: only a stroke of this
    /// board's own drag that starts at the same point turns it into a tap, so
    /// a pencil landing outside what the board visibly shows (the clipped
    /// overflow of a zoomed board) never changes the drawing.
    @State private var pencilLanding: CGPoint?
    /// Where the stroke in progress started, once its first sample arrived.
    @State private var strokeStart: CGPoint?
    /// The stroke in progress is a pencil's, and its landing LED has been
    /// toggled already: it is not a tap again on lift, and its brush starts
    /// on the next LED.
    @State private var strokeIsPencil = false
    @State private var pencilLandingLED: Int?
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
                if let onPencilHover = interaction.pencilHoverHandler {
                    PencilHoverTracker(
                        onHover: { point in
                            let led = point.flatMap { layout.ledIndex(at: $0) }
                            guard led != pencilHoverLED else { return }
                            pencilHoverLED = led
                            onPencilHover(led)
                        },
                        onPencilDown: { point in
                            pencilLanding = point
                            applyPencilLanding(layout: layout)
                        },
                        onPencilUp: { pencilLanding = nil }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }
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

        let hoverLEDs = pencilHoverLEDs
        var lit = Path()
        for cell in LEDBoardGeometry.cells where frame[cell.id] && !hoverLEDs.contains(cell.id) {
            let rect = layout.ledRect(gridX: cell.gridX, gridY: cell.gridY, gapRatio: gapRatio)
            lit.addPath(Path(roundedRect: rect, cornerRadius: cornerRadius))
        }
        context.fill(lit, with: .color(litColor))

        // The LED under a hovering Apple Pencil glows at half the board's
        // brightness whether it is lit or not, so the pencil shows which LED a
        // touch would toggle without the drawing changing.
        var hover = Path()
        for cell in LEDBoardGeometry.cells where hoverLEDs.contains(cell.id) {
            let rect = layout.ledRect(gridX: cell.gridX, gridY: cell.gridY, gapRatio: gapRatio)
            hover.addPath(Path(roundedRect: rect, cornerRadius: cornerRadius))
        }
        context.fill(hover, with: .color(color.opacity((0.45 + 0.55 * intensity) * 0.5)))
    }

    /// The hovered LED and, while the drawing 镜像 is on, its mirror.
    private var pencilHoverLEDs: [Int] {
        guard let led = pencilHoverLED else { return [] }
        if let mirror = interaction.pencilHoverMirror?(led), mirror != led { return [led, mirror] }
        return [led]
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
                if strokeStart == nil {
                    strokeStart = value.startLocation
                    applyPencilLanding(layout: layout)
                }
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
                // A pencil tapped on touch-down already; its lift is not
                // another tap.
                guard !strokeIsPencil,
                      lastPaintPoint == nil,
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
                // The LED a pencil landed on was toggled at touch-down: the
                // brush starts on the next one.
                if led != pencilLandingLED { onDrag(led) }
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

    /// A pencil touch toggles the LED it lands on at once, not on lift. It
    /// takes both halves: the tracker saying a pencil landed here, and this
    /// board's drag starting here. They arrive in either order within the
    /// same touch event, so each calls this and the second one acts.
    private func applyPencilLanding(layout: LEDBoardLayout) {
        guard !strokeIsPencil,
              let start = strokeStart, let landing = pencilLanding,
              Self.distance(CGSize(width: start.x - landing.x, height: start.y - landing.y))
                < layout.cell * Self.tapSlopInCells,
              !strokeWasSuspended, !isPaintingSuspended,
              let onTap = interaction.handlers?.onTap else { return }
        strokeIsPencil = true
        guard let led = layout.ledIndex(at: start) else { return }
        pencilLandingLED = led
        onTap(led)
    }

    private func resetStroke() {
        paintedThisStroke.removeAll()
        strokeStart = nil
        strokeIsPencil = false
        pencilLandingLED = nil
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
