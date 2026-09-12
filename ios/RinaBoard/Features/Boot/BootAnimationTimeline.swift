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
        /// The WebUI drives the mask from `requestAnimationFrame` with the
        /// closed-form ease-in-out cubic; this is its standard bezier fit
        /// (max deviation ≈1 %).
        static let reveal = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
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
