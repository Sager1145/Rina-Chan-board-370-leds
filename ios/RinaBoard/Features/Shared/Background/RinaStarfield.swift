import SwiftUI
import UIKit

// MARK: - Layout (random, generated once per launch)

/// Generates the 16-element star layout once per app launch (the equivalent
/// of the source page's single page-load `for` loop), shared by every
/// backdrop on screen, and never regenerated on resize.
@MainActor
final class RinaStarLayout {
    static let shared = RinaStarLayout()

    private var randomElements: [RinaStarSourceElement]?
    private var seededElements: [RinaStarSourceElement]?

    /// - Parameter viewportWidth: `winw` in the source JS — the first
    ///   backdrop's width. Ignored once a layout has already been generated.
    /// - Parameter seeded: screenshot mode (`-disableStarAnimation YES`)
    ///   uses a fixed seed instead of true randomness.
    func elements(viewportWidth: CGFloat, seeded: Bool) -> [RinaStarSourceElement] {
        guard viewportWidth > 0 else { return [] }
        let winw = Int(viewportWidth.rounded())
        if seeded {
            if let seededElements { return seededElements }
            var generator = RinaSplitMix64(state: RinaStarfieldSourceSpec.snapshotSeed)
            let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: winw)
            seededElements = elements
            return elements
        }
        if let randomElements { return randomElements }
        var generator = SystemRandomNumberGenerator()
        let elements = RinaStarfieldSourceSpec.makeElements(using: &generator, viewportWidth: winw)
        randomElements = elements
        return elements
    }
}

// MARK: - Clock

/// The star animation's time base, shared by every backdrop on screen.
///
/// Counts only time spent running, so a pause (boot loader, an inactive
/// scene) resumes where the stars stopped instead of jumping them ahead by
/// the paused duration; being shared, a pushed screen's stars still line up
/// with the ones under it.
@MainActor
final class RinaStarClock {
    static let shared = RinaStarClock()

    private var accumulated: TimeInterval = 0
    private var runningSince: Date?

    /// Idempotent: every visible backdrop reports the same state.
    func setRunning(_ running: Bool, at now: Date = .now) {
        if running {
            if runningSince == nil { runningSince = now }
        } else if let since = runningSince {
            accumulated += max(0, now.timeIntervalSince(since))
            runningSince = nil
        }
    }

    func time(at date: Date) -> TimeInterval {
        guard let since = runningSince else { return accumulated }
        return accumulated + max(0, date.timeIntervalSince(since))
    }
}

// MARK: - View

/// An exact port of the background stars on
/// https://lovelive-as.bushimo.jp/member/rina/, drawn by one `Canvas` per
/// frame rather than one animated view per star.
struct RinaStarfield: View {
    /// Holds the stars where they are (e.g. while the boot loader animates).
    var isPaused = false
    /// Draws the fixed-seed, fixed-time layout instead of the live one — for
    /// pixel-stable screenshots (`-disableStarAnimation YES`).
    var isFrozen = false
    /// Whether the hosting page is actually on screen (not covered by a
    /// `NavigationStack` push). Only stops this instance's own frames — it
    /// does not feed into `RinaStarClock`, which stays governed by the
    /// existing `isRunning` conditions below (scenePhase, Reduce Motion,
    /// screenshot freeze) shared by every mounted instance alike. `true` by
    /// default so previews and other callers that do not track visibility
    /// keep drawing.
    var isPageVisible = true

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isRunning = !isFrozen && !reduceMotion && !isPaused && scenePhase == .active
        GeometryReader { proxy in
            let elements = RinaStarLayout.shared.elements(viewportWidth: proxy.size.width, seeded: isFrozen)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !(isRunning && isPageVisible))) { timeline in
                let time: TimeInterval = isFrozen
                    ? RinaStarfieldSourceSpec.snapshotTime
                    : (reduceMotion ? 0 : RinaStarClock.shared.time(at: timeline.date))
                // Energy investigation (PR-12): lets a signpost trace show
                // whether this instance's timeline content closure keeps
                // firing while its page is not visible (background tab,
                // covered NavigationStack push).
                let _ = RinaPerf.signposter.emitEvent("StarfieldFrame")
                Canvas(rendersAsynchronously: true) { context, size in
                    Self.draw(elements: elements, in: &context, size: size, time: time)
                }
            }
        }
        .onChange(of: isRunning, initial: true) { _, running in
            RinaStarClock.shared.setRunning(running)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Placement

/// One star's frame at a given time.
struct RinaStarPlacement: Equatable {
    let rect: CGRect
    let opacity: Double
    let rotation: Angle
}

extension RinaStarfield {
    /// Position, size, opacity and rotation of one element at `time`; `nil`
    /// when it has no CSS rule (`icon == 0`, appearance `nil`).
    ///
    /// - Parameter childIndex: 1-based `nth-child` position (DOM order + 1).
    nonisolated static func placement(of element: RinaStarSourceElement, childIndex: Int, in size: CGSize, time: TimeInterval) -> RinaStarPlacement? {
        guard let appearance = element.appearance else { return nil }
        let width = Double(size.width)
        let height = Double(size.height)
        let style = RinaStarAppearanceStyle.appearanceStyle(for: appearance, viewportWidth: width)
        let motion = RinaStarMotionStyle.motionStyle(for: element.movement)

        let x = width * Double(element.leftPercent) / 100
        let tau = time - motion.delay

        let top: Double
        let opacity: Double
        if tau < 0 {
            // The animation-delay has not elapsed yet: the base style's
            // `top: 105%` shows, with no opacity declared (so it is 1).
            top = RinaStarRiseKeyframes.baseTopFraction * height
            opacity = 1
        } else {
            let progress = frac(tau / motion.duration)
            let keyframes = RinaStarRiseKeyframes.riseKeyframes(forChildIndex: childIndex)
            let ease = RinaStarRiseKeyframes.timingFunction.solve
            let start = keyframes.startTopFraction * height
            top = start + (keyframes.endTop - start) * ease(progress)
            opacity = RinaStarRiseKeyframes.opacity(atProgress: progress)
        }

        // The span's `rotate` animation has no delay and keeps running from
        // t=0 regardless of the parent's animation-delay.
        let spinDuration = RinaStarRiseKeyframes.spinDuration(forChildIndex: childIndex)
        let rotation = Angle(degrees: -360 * frac(time / spinDuration))

        let rect = CGRect(x: x, y: top, width: style.width, height: style.height)
        return RinaStarPlacement(rect: rect, opacity: opacity, rotation: rotation)
    }

    nonisolated private static func frac(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    /// The shared visibility predicate for both the draw pass's culling and
    /// tests: invisible (opacity 0) elements are skipped, and elements whose
    /// rotated bounding box cannot possibly reach the canvas are skipped too.
    /// The rect is inflated by the rotated half-diagonal first so a spinning
    /// corner is never clipped away by a same-size intersects test.
    nonisolated static func isDrawn(_ placement: RinaStarPlacement, in bounds: CGRect) -> Bool {
        guard placement.opacity > 0 else { return false }
        let inflated = placement.rect.insetBy(dx: -placement.rect.width * 0.21, dy: -placement.rect.height * 0.21)
        return inflated.intersects(bounds)
    }
}

// MARK: - Drawing

extension RinaStarfield {
    /// The five source images, loaded at most once for the type's lifetime;
    /// indexed by `RinaStarAppearance.rawValue - 1`. `nil` entries (a clone
    /// checkout without the asset bundle) draw nothing for that star.
    /// `nonisolated`: an immutable `Sendable` constant, read by the
    /// asynchronous Canvas renderer off the main actor.
    nonisolated private static let cachedStarImages: [UIImage?] = RinaStarAppearance.allCases.map {
        UIImage(named: "RinaBackgroundStar\($0.rawValue)")
    }

    nonisolated private static func draw(elements: [RinaStarSourceElement], in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        context.clip(to: Path(bounds))

        // Resolved at most once per draw pass; a fixed 5-slot array avoids a
        // per-frame dictionary allocation.
        let resolvedImages: [GraphicsContext.ResolvedImage?] = cachedStarImages.map { uiImage in
            uiImage.map { context.resolve(Image(uiImage: $0)) }
        }

        for (index, element) in elements.enumerated() {
            guard let appearance = element.appearance else { continue }
            guard let placement = placement(of: element, childIndex: index + 1, in: size, time: time) else { continue }
            guard isDrawn(placement, in: bounds) else { continue }
            guard let image = resolvedImages[appearance.rawValue - 1] else { continue }

            var star = context
            star.opacity = placement.opacity
            star.translateBy(x: placement.rect.midX, y: placement.rect.midY)
            star.rotate(by: placement.rotation)

            // `background-size: contain` within the element's width/height box.
            let naturalSize = image.size
            let scale = min(placement.rect.width / naturalSize.width, placement.rect.height / naturalSize.height)
            let drawSize = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
            let drawRect = CGRect(x: -drawSize.width / 2, y: -drawSize.height / 2, width: drawSize.width, height: drawSize.height)
            star.draw(image, in: drawRect)
        }
    }
}
