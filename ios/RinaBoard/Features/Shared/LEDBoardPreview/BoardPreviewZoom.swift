import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - Zoom mode

/// Whether a board preview can be magnified, and how the scroll view it sits
/// in learns to stand down while the board is being touched.
///
/// The mode is an explicit argument, like `LEDBoardInteraction`, so a call
/// site states in one word whether its board is a direct-manipulation surface
/// or a read-out. Only the Control tab's editable board is `.pinchable`: the
/// other previews are page content and a touch on them belongs to the page.
enum LEDBoardZoom {
    /// Fixed at 1×. Touches behave as before — the enclosing list may claim
    /// them for a scroll.
    case fixed
    /// Two fingers magnify the board, up to `BoardPreviewZoom.maxScale`,
    /// about the point they pinched, and — once it is magnified — drag it
    /// around under the frame.
    ///
    /// `isTouching` is true for as long as *any* finger is on the board, so
    /// the owning `List` can `.scrollDisabled` itself for that stretch. That
    /// binding is what makes one finger on the board mean "paint" and never
    /// "scroll the page", while one finger on the commands below still
    /// scrolls normally.
    case pinchable(isTouching: Binding<Bool>)
}

extension View {
    @ViewBuilder
    func boardPreviewZoom(_ zoom: LEDBoardZoom) -> some View {
        switch zoom {
        case .fixed:
            self
        case .pinchable(let isTouching):
            modifier(BoardPreviewZoom(isTouching: isTouching))
        }
    }
}

// MARK: - Painting suspension

/// Tells the board's paint stroke to stop while two fingers are down, so a
/// pinch or pan does not drag a line of LEDs along under the fingers.
///
/// A reference rather than an environment `Bool` on purpose: the paint
/// stroke reads it when a touch sample arrives, and the recognizer sets it in
/// the same touch event the second finger lands in. An environment value
/// would only reach the stroke after the next view update — one sample too
/// late, which is exactly the sample that jumps.
@MainActor
final class LEDBoardPaintSuspension {
    var isSuspended = false
}

private struct LEDBoardPaintSuspensionKey: EnvironmentKey {
    static let defaultValue: LEDBoardPaintSuspension? = nil
}

private struct LEDBoardPaintingSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Written by `BoardPreviewZoom`, read by `LEDBoardPreview`.
    var ledBoardPaintSuspension: LEDBoardPaintSuspension? {
        get { self[LEDBoardPaintSuspensionKey.self] }
        set { self[LEDBoardPaintSuspensionKey.self] = newValue }
    }

    /// The same suspension as a value, for decisions made when a stroke
    /// *ends* (a tap only counts if no second finger joined it), where
    /// arriving with the next view update is soon enough.
    var ledBoardPaintingSuspended: Bool {
        get { self[LEDBoardPaintingSuspendedKey.self] }
        set { self[LEDBoardPaintingSuspendedKey.self] = newValue }
    }
}

// MARK: - Pinch to zoom

/// Pinch-to-zoom and two-finger panning for the board preview, with the
/// magnified board held inside a native rounded-rectangle frame whose edges
/// dissolve inward into the page.
///
/// Three things are deliberately coupled to the magnification:
///
/// - **The frame.** At 1× there is no frame at all — the board sits on the
///   page exactly as it did before. The rounded rectangle (continuous corners,
///   the system's own rounded-rect curve) fades in as the board grows, because
///   only a magnified board has anything to hold: it is what tells the eye
///   that the board now extends past what is on screen.
/// - **The edge gradient.** Inside that frame the board fades out toward its
///   border. Nothing is painted over the board to do it — the edges are masked
///   away, so what shows through *is* the page background, in whatever it
///   happens to be (grouped background, light or dark).
/// - **The gradient's length**, which grows with the magnification up to
///   `fadeCeilingScale` (1.4×) and then stops. Past that point the board is
///   zoomed far enough that a longer fade would start eating LEDs the user
///   zoomed in to see.
///
/// Two fingers are one continuous transform, not a pinch and a pan taking
/// turns: the board point that was under the fingers when they landed stays
/// under their midpoint, at the scale their spread asks for. Spreading zooms,
/// sliding pans, and doing both at once does both.
struct BoardPreviewZoom: ViewModifier {
    @Binding var isTouching: Bool

    /// Committed magnification and pan. The transform is `scale` about the
    /// centre, then `offset` in screen points.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// The transform, and the fingers' midpoint, when the current two-finger
    /// segment began. Samples are relative to the start of a segment, so the
    /// transform is rebuilt from this baseline every time rather than
    /// accumulated — accumulation drifts.
    @State private var baseline = TransformBaseline()
    /// The scale the fingers are asking for, before the rubber band at the
    /// limits resists it. Re-anchoring mid-gesture has to continue from this,
    /// not from the resisted `scale`, or lifting a finger while stretched
    /// past a limit would make the board jump.
    @State private var requestedScale: CGFloat = 1
    /// Where the fingers last were, so a board released past a limit springs
    /// back about that point instead of about the frame's centre.
    @State private var lastFingers: CGPoint = .zero
    /// The segment the baseline belongs to. A new one starts whenever the set
    /// of fingers on the board changes, so lifting or adding a finger
    /// re-anchors instead of making the board jump.
    @State private var baselineSegment = -1
    /// Two fingers are (or were, in this touch sequence) on the board. Stays
    /// set until every finger has lifted, so the one finger left behind after
    /// a pinch cannot suddenly start painting — and the page cannot scroll.
    @State private var isTransforming = false
    @State private var paintSuspension = LEDBoardPaintSuspension()
    /// The board's own size — the window the magnified board is seen through.
    @State private var viewport: CGSize = .zero
    /// True from the first finger down until it lifts. `@GestureState` resets
    /// itself when the gesture ends *or is cancelled*, which is what makes it
    /// the honest signal here.
    @GestureState private var isTouchingBoard = false

    /// How far in the board can be magnified. Three times is about where a
    /// single LED becomes a comfortable target; beyond it the board photo is
    /// only being enlarged, not resolved.
    static let maxScale: CGFloat = 3
    /// How far past either limit (1× and `maxScale`) the board can be
    /// stretched: the rubber band approaches this ratio but never reaches
    /// it, however far the fingers keep going.
    private static let overshootRatio: CGFloat = 1.3
    /// The magnification at which the edge gradient stops growing.
    private let fadeCeilingScale: CGFloat = 1.4
    /// The gradient's length there, in points.
    private let maxFadeLength: CGFloat = 28
    /// The frame's corner radius at `fadeCeilingScale` and beyond.
    private let maxCornerRadius: CGFloat = 22

    private struct TransformBaseline {
        var scale: CGFloat = 1
        var requestedScale: CGFloat = 1
        var offset: CGSize = .zero
        var fingers: CGPoint = .zero
    }

    /// 0 at rest, 1 from `fadeCeilingScale` on: the one value the frame and
    /// the gradient are both derived from, so they grow together.
    private var zoomProgress: CGFloat {
        min(max((scale - 1) / (fadeCeilingScale - 1), 0), 1)
    }

    private var fadeLength: CGFloat { maxFadeLength * zoomProgress }
    private var cornerRadius: CGFloat { maxCornerRadius * zoomProgress }

    func body(content: Content) -> some View {
        // The transform is applied *inside* this stack; the touch tracking is
        // attached *outside* it. Measured past the scale and offset, the
        // fingers' midpoint would be in board space, which moves every time
        // the board does — a feedback loop that makes a pan chase its tail.
        ZStack {
            content
                .environment(\.ledBoardPaintSuspension, paintSuspension)
                .environment(\.ledBoardPaintingSuspended, isTransforming)
                .scaleEffect(scale, anchor: .center)
                .offset(x: offset.width, y: offset.height)
        }
        .background {
            ZStack {
                // Measured in the background, never in the layout: the row
                // above sizes the board from its own aspect ratio in a single
                // pass (§13 — the board must never appear to breathe), and a
                // `GeometryReader` in the content would answer the row's
                // proposal instead.
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewport = geo.size }
                        .onChange(of: geo.size) { _, size in
                            viewport = size
                            // A rotation or split-view resize changes how much
                            // slack a magnified board has.
                            offset = clampedOffset(offset, scale: scale)
                        }
                }
                TwoFingerTransformTracker(suspension: paintSuspension,
                                          onChange: transform,
                                          onEnd: endTransform)
            }
        }
        // One mask, not a mask plus a clip: the fade's own hard outer edge
        // is what keeps the magnified board inside the frame.
        .mask { frameMask }
        // A mask does not clip hit testing. Without this the magnified
        // board would still take touches where it hangs, invisible, over
        // the status bar and the command section below.
        .contentShape(Rectangle())
        .simultaneousGesture(touchGesture)
        .onChange(of: isTouchingBoard) { _, touching in
            // Backstop: every finger is up and no recognizer still holds the
            // suspension, yet the transform never heard an end — it must not
            // leave the page unscrollable.
            if !touching, isTransforming, !paintSuspension.isSuspended { endTransform() }
            syncTouching()
        }
        .onChange(of: isTransforming) { _, _ in syncTouching() }
        .onDisappear {
            // A tab switch mid-gesture can take the view away before the
            // recognizer's end reaches it; left set, these would keep
            // painting suspended and the page unscrollable on return.
            isTransforming = false
            paintSuspension.isSuspended = false
            isTouching = false
        }
    }

    private func syncTouching() {
        isTouching = isTouchingBoard || isTransforming
    }

    // MARK: The frame

    /// An opaque core that ramps to nothing over the outermost `fadeLength`
    /// points, inside the system's continuous rounded rectangle.
    ///
    /// Built by blurring an inset rounded rectangle rather than by stacking
    /// four linear gradients: the falloff then follows the rounded corners
    /// instead of crossing them, which is the whole point of using the
    /// native curve. The core is inset by half the fade and blurred by a
    /// quarter of it, so the ramp is centred on the inset edge and has fully
    /// run out by the frame — a wider blur leaves the board faintly visible
    /// right at the border, which reads as a hard edge. At rest, where
    /// `fadeLength` is zero, this collapses to a plain opaque rectangle.
    private var frameMask: some View {
        RoundedRectangle(cornerRadius: max(cornerRadius - fadeLength / 2, 0), style: .continuous)
            .fill(.white)
            .padding(fadeLength / 2)
            .blur(radius: fadeLength / 4)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: The gestures

    /// A zero-distance drag whose only job is to hold `isTouchingBoard` from
    /// the very first finger down — including the single-finger strokes that
    /// paint — so the page cannot scroll out from under a board the user is
    /// working on.
    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouchingBoard) { _, touching, _ in touching = true }
    }

    /// Applies one two-finger sample.
    ///
    /// - Parameters:
    ///   - segment: Changes whenever the fingers on the board change; a new
    ///     value re-anchors on the transform as it stands.
    ///   - fingers: The fingers' midpoint, in the board's untransformed space.
    ///   - spread: Magnification since the segment began.
    private func transform(segment: Int, fingers: CGPoint, spread: CGFloat) {
        if segment != baselineSegment || !isTransforming {
            baselineSegment = segment
            baseline = TransformBaseline(scale: scale,
                                         // A fresh gesture starts from what is on
                                         // screen; a re-anchor mid-gesture from
                                         // what the fingers were asking for.
                                         requestedScale: isTransforming ? requestedScale : scale,
                                         offset: offset,
                                         fingers: fingers)
            isTransforming = true
        }
        guard baseline.scale > 0 else { return }

        let requested = max(baseline.requestedScale * spread, 0.01)
        let newScale = Self.rubberBanded(requested)
        // The magnification actually applied, which is what the pan has to be
        // solved against once the rubber band resists — otherwise the board
        // slides under fingers it is no longer following.
        let applied = newScale / baseline.scale
        let centre = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        // Solved from "the board point under the fingers when they landed
        // stays under them": offset = now − (then − offset₀)·m, with both
        // midpoints taken from the centre the scale is applied about.
        let panned = CGSize(
            width: (fingers.x - centre.x) - (baseline.fingers.x - centre.x - baseline.offset.width) * applied,
            height: (fingers.y - centre.y) - (baseline.fingers.y - centre.y - baseline.offset.height) * applied
        )

        requestedScale = requested
        lastFingers = fingers
        scale = newScale
        offset = clampedOffset(panned, scale: newScale)
    }

    /// Inside 1…`maxScale` the scale follows the fingers exactly; past either
    /// limit it keeps following, but with growing resistance, the way a
    /// scroll view stretches past its end.
    ///
    /// The curve is `UIScrollView`'s rubber band, `(1 − 1 / (x·c / d + 1))·d`
    /// with c = 0.55, applied to the *logarithm* of the scale so the stretch
    /// feels the same whether it is past 1× or past 3×. Right at the limit
    /// the board follows the fingers at 0.55× their rate — the same step into
    /// resistance a scroll view has at its end — and slower from there.
    private static func rubberBanded(_ requested: CGFloat) -> CGFloat {
        let reach = log(overshootRatio)
        func resisted(_ excess: CGFloat) -> CGFloat {
            (1 - 1 / (excess * 0.55 / reach + 1)) * reach
        }
        if requested > maxScale {
            return maxScale * exp(resisted(log(requested / maxScale)))
        }
        if requested < 1 {
            return 1 / exp(resisted(log(1 / requested)))
        }
        return requested
    }

    /// Keeps the magnified board covering the frame: it can be dragged around
    /// inside it, but never far enough to expose an empty edge. At 1× there
    /// is no slack at all, so two fingers only pan a board that is zoomed.
    private func clampedOffset(_ offset: CGSize, scale: CGFloat) -> CGSize {
        let slack = CGSize(width: max((scale - 1) * viewport.width / 2, 0),
                           height: max((scale - 1) * viewport.height / 2, 0))
        return CGSize(width: min(max(offset.width, -slack.width), slack.width),
                      height: min(max(offset.height, -slack.height), slack.height))
    }

    /// Every finger has lifted: release the transform. A board stretched
    /// past either limit springs back to it — about where the fingers let go,
    /// so the part the user was looking at stays put — with a little
    /// bounce, so the limit reads as elastic rather than as a wall.
    private func endTransform() {
        isTransforming = false
        let target = min(max(scale, 1), Self.maxScale)
        requestedScale = target
        guard target != scale, scale > 0 else { return }

        let centre = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let ratio = target / scale
        let settled = CGSize(
            width: (lastFingers.x - centre.x) - (lastFingers.x - centre.x - offset.width) * ratio,
            height: (lastFingers.y - centre.y) - (lastFingers.y - centre.y - offset.height) * ratio
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            scale = target
            offset = clampedOffset(settled, scale: target)
        }
    }
}

// MARK: - Two-finger tracking

/// Watches the fingers on the board from UIKit, outside SwiftUI's gesture
/// system.
///
/// SwiftUI has no two-finger drag, and a UIKit recognizer attached to this
/// view through SwiftUI would sit on an *ancestor* of the board's paint
/// gesture — where SwiftUI's rule that a child's gesture wins could keep it
/// from ever recognizing while a finger is painting. Instead an invisible
/// view marks the board's frame and installs a purely observing recognizer on
/// its window, which only accepts touches that land on this board. It never
/// cancels, delays or competes with anything, so the paint stroke, the
/// touch-down drag that holds the page still, and the list all keep
/// receiving their touches exactly as before; and it works on every
/// supported iOS version. A second, touch-less pinch recognizer beside it
/// keeps trackpad and Mac pinches zooming.
private struct TwoFingerTransformTracker: UIViewRepresentable {
    var suspension: LEDBoardPaintSuspension
    var onChange: (_ segment: Int, _ fingers: CGPoint, _ spread: CGFloat) -> Void
    var onEnd: () -> Void

    func makeUIView(context: Context) -> TrackerView {
        TrackerView()
    }

    func updateUIView(_ view: TrackerView, context: Context) {
        view.suspension = suspension
        view.onChange = onChange
        view.onEnd = onEnd
    }

    static func dismantleUIView(_ view: TrackerView, coordinator: ()) {
        view.detach()
    }

    final class TrackerView: UIView, UIGestureRecognizerDelegate {
        var suspension: LEDBoardPaintSuspension?
        var onChange: ((Int, CGPoint, CGFloat) -> Void)?
        var onEnd: (() -> Void)?

        /// Segments as reported to the modifier, shared by both recognizers.
        private var segment = 0
        private var lastFingerSegment = -1
        private var pendingDetach = false

        private lazy var fingers: TwoFingerTransformRecognizer = {
            let recognizer = TwoFingerTransformRecognizer(target: self, action: #selector(handleFingers(_:)))
            recognizer.referenceView = self
            // Set while UIKit is still delivering the second finger's touch,
            // ahead of any action message: the paint stroke may be fed from
            // that same event.
            recognizer.onEngage = { [weak self] in self?.suspension?.isSuspended = true }
            observe(recognizer)
            return recognizer
        }()

        /// Trackpad, Magic Keyboard and Mac pinches arrive as transform
        /// events with no touches at all, which the finger recognizer never
        /// sees.
        private lazy var indirectPinch: UIPinchGestureRecognizer = {
            let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handleIndirectPinch(_:)))
            recognizer.allowedTouchTypes = []
            observe(recognizer)
            return recognizer
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            // A marker only: every touch must fall through to SwiftUI.
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        private func observe(_ recognizer: UIGestureRecognizer) {
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else {
                // SwiftUI re-hosts platform views by moving them out of the
                // window and straight back in. Removing a recognizer resets
                // it without an end action, so detaching here would strand a
                // gesture in progress; wait a run-loop turn to see whether
                // the view really left.
                pendingDetach = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pendingDetach, self.window == nil else { return }
                    self.detach()
                }
                return
            }
            pendingDetach = false
            guard fingers.view !== window else { return }
            detach()
            window.addGestureRecognizer(fingers)
            window.addGestureRecognizer(indirectPinch)
        }

        func detach() {
            pendingDetach = false
            let wasLive = Self.isLive(fingers) || Self.isLive(indirectPinch)
            fingers.view?.removeGestureRecognizer(fingers)
            indirectPinch.view?.removeGestureRecognizer(indirectPinch)
            guard wasLive else { return }
            // Removal reset the gesture without an end, so finish it here —
            // otherwise painting stays suspended and the page unscrollable.
            // Off the current turn: dismantling runs inside a view update.
            suspension?.isSuspended = false
            let onEnd = onEnd
            DispatchQueue.main.async { onEnd?() }
        }

        private static func isLive(_ recognizer: UIGestureRecognizer) -> Bool {
            recognizer.state == .began || recognizer.state == .changed
        }

        @objc private func handleFingers(_ recognizer: TwoFingerTransformRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                if recognizer.segment != lastFingerSegment {
                    lastFingerSegment = recognizer.segment
                    segment += 1
                }
                suspension?.isSuspended = true
                onChange?(segment, recognizer.midpoint, recognizer.spread)
            case .ended, .cancelled:
                finish(unless: indirectPinch)
            default:
                break
            }
        }

        @objc private func handleIndirectPinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                segment += 1
                fallthrough
            case .changed:
                suspension?.isSuspended = true
                onChange?(segment, recognizer.location(in: self), recognizer.scale)
            case .ended, .cancelled:
                finish(unless: fingers)
            default:
                break
            }
        }

        private func finish(unless other: UIGestureRecognizer) {
            guard !Self.isLive(other) else { return }
            onEnd?()
            // Cleared a run-loop turn later, not now: the lift that ends the
            // pinch is also the event the paint stroke's `onEnded` runs in,
            // and depending on delivery order it may read the flag after
            // this action. It must still see "suspended" there, or a pinch
            // could end by painting its last point or counting as a tap.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !Self.isLive(self.fingers),
                      !Self.isLive(self.indirectPinch) else { return }
                self.suspension?.isSuspended = false
            }
        }

        // MARK: UIGestureRecognizerDelegate

        /// Only fingers that land on this board, and only when what they hit
        /// is inside this board's own container: the same rectangle on
        /// another tab, under a presented sheet, or under the tab bar floating
        /// over a scrolled list belongs to something else.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            accepts(hit: touch.view, at: touch.location(in: self))
        }

        /// An indirect pinch has no touch to vet, so the same test is run on
        /// what sits under the pointer when it starts.
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === indirectPinch else { return true }
            guard let window else { return false }
            let point = gestureRecognizer.location(in: self)
            return accepts(hit: window.hitTest(convert(point, to: window), with: nil), at: point)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        private func accepts(hit: UIView?, at point: CGPoint) -> Bool {
            guard window != nil,
                  bounds.contains(point),
                  let hit,
                  let container = touchContainer else { return false }
            return hit.isDescendant(of: container)
        }

        /// The list cell the board is hosted in; outside a list, the root
        /// view of the nearest view controller — never the whole window,
        /// where a sheet or popover over the board would count as the board.
        private var touchContainer: UIView? {
            var ancestor = superview
            var controllerRoot: UIView?
            while let view = ancestor {
                if view is UICollectionViewCell || view is UITableViewCell { return view }
                if controllerRoot == nil, view.next is UIViewController { controllerRoot = view }
                ancestor = view.superview
            }
            return controllerRoot
        }
    }
}

/// Recognizes as soon as two fingers are down — no movement threshold, so the
/// paint stroke is suspended the moment the second finger lands — and reports
/// their midpoint and how far they have spread since the current segment
/// began.
///
/// `UIPinchGestureRecognizer` and a two-touch `UIPanGestureRecognizer` would
/// each need their own hysteresis before recognizing, and a two-finger slide
/// with no change in spread never recognizes a pinch at all; tracking the
/// touches directly gives one recognizer with one lifetime for both.
final class TwoFingerTransformRecognizer: UIGestureRecognizer {
    /// The space `midpoint` is reported in: the board's untransformed frame.
    weak var referenceView: UIView?
    /// Midpoint of the fingers on the board.
    private(set) var midpoint: CGPoint = .zero
    /// Fingers' spread relative to the start of the current segment.
    private(set) var spread: CGFloat = 1
    /// Advances whenever the reported samples re-anchor.
    private(set) var segment = 0
    /// Called the moment a second finger joins, during touch delivery.
    var onEngage: (() -> Void)?

    private var trackedTouches: [UITouch] = []
    private var baselineSpread: CGFloat = 0
    private var needsBaseline = true

    /// Fingers only. An Apple Pencil on the glass is drawing: counted here,
    /// pencil plus one finger would read as a pinch and suspend the stroke.
    static let acceptedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = Self.acceptedTouchTypes
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        trackedTouches.append(contentsOf: touches)
        needsBaseline = true
        guard trackedTouches.count >= 2 else { return }
        onEngage?()
        report()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouches.count >= 2 else { return }
        report()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
    }

    override func reset() {
        super.reset()
        trackedTouches.removeAll()
        spread = 1
        needsBaseline = true
    }

    private func lift(_ lifted: Set<UITouch>) {
        trackedTouches.removeAll { lifted.contains($0) }
        // Re-anchor on the remaining fingers at their next movement, so a
        // lifted finger never drags the midpoint (and the board) with it.
        needsBaseline = true
        guard trackedTouches.isEmpty else { return }
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    private func report() {
        let points = trackedTouches.map { $0.location(in: referenceView) }
        let count = CGFloat(points.count)
        let mid = CGPoint(x: points.map(\.x).reduce(0, +) / count,
                          y: points.map(\.y).reduce(0, +) / count)
        // Mean distance from the midpoint: for two fingers, half their
        // separation; for more, still a stable measure of size.
        let currentSpread = points.reduce(CGFloat(0)) { $0 + hypot($1.x - mid.x, $1.y - mid.y) } / count

        if needsBaseline {
            baselineSpread = currentSpread
            segment += 1
            needsBaseline = false
        }
        midpoint = mid
        spread = baselineSpread > 0 ? currentSpread / baselineSpread : 1
        state = state == .possible ? .began : .changed
    }
}
