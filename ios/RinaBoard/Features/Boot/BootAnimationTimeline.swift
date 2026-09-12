import CoreGraphics
import Foundation
import QuartzCore

/// The boot-loader animation's numbers and curves, in one place.
///
/// The overlay hands every phase to Core Animation as explicit animations
/// built from these constants, so the render server interpolates each frame
/// with the same `cubic-bezier` curves the WebUI used and nothing is sampled
/// on the main thread: a launch-time hitch (list layout, a transport starting,
/// an image decode) delays the *scheduling* of a phase by a frame at most and
/// never drops frames inside one.
///
/// See docs/BOOT_ANIMATION_SPEC.md — the legacy sources are the contract and
/// its two trailing sections list where the table was wrong and where the
/// port deliberately departs; the constants below are those numbers in seconds.
enum BootTimeline {

    // MARK: Constants

    static let minDisplay: TimeInterval = 0.400
    static let breath: TimeInterval = 1.620
    static let breathReduced: TimeInterval = 2.600
    static let peakRatio: Double = 0.5
    static let peakTolerance: TimeInterval = 0.024
    /// The legacy always waits for the next breath peak so its P2 keyframes,
    /// which snap the halo to the peak values, start seamlessly — up to a
    /// full 1.62 s. On iOS the first-page waterfall plus the launch-to-first-
    /// frame delay lands the finish request ≈0.8–1.0 s after `start`, right
    /// on the first peak, so launches alternated between a 0.8 s and a 2.4 s
    /// loader. The port instead contracts the halo from wherever the breath
    /// *is* (no snap, so no alignment is needed for continuity) and keeps the
    /// pop-on-the-peak beat only when the peak is this close.
    /// Slightly above `minDisplay`, so a request arriving before 400 ms
    /// (the first peak is at 810 ms) still keeps the beat.
    static let maxPeakWait: TimeInterval = 0.450

    static let haloContract: TimeInterval = 0.520
    static let avatarPop: TimeInterval = 0.620
    static let iconSwap: TimeInterval = 0.180
    static let textFade: TimeInterval = 0.220
    static let hold: TimeInterval = 0.260
    static let release: TimeInterval = 2.100
    /// round(2100 × 0.18) — the 18 % keyframe of the release track.
    static let imgShrink: TimeInterval = 0.378
    static let reveal: TimeInterval = 0.850
    /// The reveal mask's feather lies *outside* the hole, so installing the
    /// mask at hole radius 0 — as the legacy does — makes a 100 pt soft dent
    /// appear around the avatar in a single frame. Measured on a 60 Hz capture
    /// of the replay, that one frame delivered as much un-blurring in the
    /// 60–110 pt annulus as the next 150 ms of the reveal combined, and the
    /// hole's own `r = R·t²` start is far too slow to cover it. The port
    /// widens the feather from 0 to its full width over this long instead,
    /// *finishing* at `revealStart` so the hole still travels for the spec's
    /// 850 ms. Deliberate departure; see the spec's deviations section.
    static let revealFeatherIn: TimeInterval = 0.120
    static let extra: TimeInterval = 0.180

    static let waterfallStagger: TimeInterval = 0.115
    static let waterfallSettle: TimeInterval = 0.260

    /// `--rina-reveal-edge`: the mask's feather, outside the hole.
    static let revealEdge: CGFloat = 100
    /// The hole grows to the farthest corner plus this, so the feather has
    /// fully left the screen at progress 1 (`getMaxR`, app.js).
    static let revealOvershoot: CGFloat = 90

    /// Offsets from the start of the outro (P2 t0).
    ///
    /// The hold runs *concurrently* with the halo contraction, not after it:
    /// `app.js:6262-6268` schedules `is-halo-hidden` fire-and-forget at
    /// 520 ms, awaits only `HOLD_MS`, and adds `is-final-release` at t0+260.
    /// The spec table's "t0+520 … t0+780" is wrong by one contraction.
    static let releaseStart = hold                         // 0.260
    static let revealStart = releaseStart + imgShrink      // 0.638
    /// P5: opacity → 0 at P4start + max(2100, 378+850) + 180 …
    static let overlayFadeStart = releaseStart + release + extra  // 2.540
    /// … then removed a further 180 ms later (legacy app.js:6271-6274).
    static let outroDuration = overlayFadeStart + extra           // 2.720

    // MARK: Geometry (points)

    static let avatarDiameter: CGFloat = 106
    static let haloDiameter: CGFloat = 142
    /// The halo's `radial-gradient(circle …)` has no explicit size, so CSS
    /// sizes it `farthest-corner`: its colour-stop percentages resolve against
    /// the ray to the 142 px box's corner, 71·√2 ≈ 100.4 px, not against the
    /// 71 px radius the box is then clipped to by `border-radius: 50%`. That
    /// puts the bright band *under* the avatar and leaves only a faint tail
    /// showing — the soft haze the WebUI actually renders.
    static let haloGradientRay: CGFloat = 71 * 2.0.squareRoot()
    /// Room around the halo for its blur and drop shadow.
    static let haloPadding: CGFloat = 24
    /// `.loading-box` is a grid: the 142 pt stage, a 20 pt gap, then the
    /// label — so the label's centre sits ≈100 pt below the avatar's.
    static let textOffset: CGFloat = 100

    // MARK: Easing (CSS `cubic-bezier` parity)

    enum Curve {
        static let breath = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
        /// `.flash-halo` declares per-property transitions, but adding
        /// `.is-ring-contracting` changes only `animation`, so no transition
        /// ever fires; scale and opacity both ride the keyframes' single curve
        /// (styles.css:2851-2853).
        static let haloContract = CAMediaTimingFunction(controlPoints: 0.55, 0.085, 0.68, 0.53)
        /// CSS keyword `ease`.
        static let ease = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        /// y1 > 1: an overshooting pop. Core Animation allows out-of-range
        /// y control points, so the overshoot is reproduced, not clamped.
        static let avatarPop = CAMediaTimingFunction(controlPoints: 0.16, 1.25, 0.3, 1)
        static let releaseIn = CAMediaTimingFunction(controlPoints: 0.34, 0, 0.2, 1)
        static let releaseOut = CAMediaTimingFunction(controlPoints: 0.12, 0.88, 0.18, 1)
        /// The hole's radius grows with *constant acceleration* — a slow start
        /// that keeps speeding up until the mask has left the screen. These
        /// control points make the bezier exactly y = x² (x(t) = t, y(t) = t²),
        /// not an approximation. Deliberate departure from the WebUI's
        /// ease-in-out cubic; see the spec's "Deliberate iOS deviations".
        static let reveal = CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1 / 3)
        /// The mirror of `reveal`: these control points make the bezier exactly
        /// y = 2x − x², constant *de*celeration. The feather widens into place
        /// and arrives with zero velocity — which is the velocity the hole then
        /// leaves with — so the mask's outer edge has no kink at `revealStart`.
        static let featherIn = CAMediaTimingFunction(controlPoints: 1 / 3, 2 / 3, 2 / 3, 1)
    }

    // MARK: Peak alignment

    /// Seconds to wait before starting the outro so it lands on a halo peak:
    /// 0 when already within `peakTolerance` of one (`app.js:6233-6239`) or
    /// when the next one is further than `maxPeakWait` away.
    static func delayToHaloPeak(elapsed: TimeInterval, period: TimeInterval) -> TimeInterval {
        guard period > 0 else { return 0 }
        let phase = (elapsed.truncatingRemainder(dividingBy: period) + period)
            .truncatingRemainder(dividingBy: period)
        var delta = period * peakRatio - phase
        if abs(delta) <= peakTolerance { return 0 }
        if delta < 0 { delta += period }
        return delta <= maxPeakWait ? delta : 0
    }
}
