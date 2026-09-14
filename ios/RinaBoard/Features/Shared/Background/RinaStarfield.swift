import SwiftUI

// MARK: - Configuration

struct RinaStarfieldConfiguration: Equatable {
    var particleCount: Int
    var minimumSize: Double
    var maximumSize: Double
    /// Seconds for one bottom-to-top pass; foreground stars use the shorter end.
    var minimumDuration: TimeInterval
    var maximumDuration: TimeInterval
    var maximumHorizontalSway: Double
    var maximumLinearDrift: Double
    /// Points below and above the screen where a star is born and wraps.
    var verticalMargin: Double
    var frameInterval: TimeInterval
    var seed: UInt64

    static let appBackground = RinaStarfieldConfiguration(
        particleCount: 28,
        minimumSize: 4.5,
        maximumSize: 18,
        minimumDuration: 8.5,
        maximumDuration: 17.5,
        maximumHorizontalSway: 30,
        maximumLinearDrift: 24,
        verticalMargin: 36,
        // The stars move slowly; 30 fps looks smooth and halves the redraws.
        frameInterval: 1.0 / 30.0,
        seed: 0x5249_4E41_5354_4152 // "RINASTAR"
    )
}

// MARK: - Particle model

struct RinaStarParticle: Equatable {
    /// Horizontal position, 0...1 of the width.
    let x: Double
    let size: Double
    let duration: TimeInterval
    /// Where in its pass the star is at time 0 — the equivalent of a negative
    /// CSS `animation-delay`, so the screen is already populated on appear.
    let initialPhase: Double
    let horizontalSway: Double
    let linearDrift: Double
    let wavePhase: Double
    let rotation: Double
    let rotationTravel: Double
    let twinkleSpeed: Double
    let maximumOpacity: Double
    let tone: Tone

    enum Tone: CaseIterable { case white, pink, lavender }
}

/// Particles come from a fixed seed, so every body re-evaluation yields the
/// same stars and only the time-derived progress moves them. Random values in
/// view state would make stars jump whenever SwiftUI rebuilds the view.
enum RinaStarfieldModel {
    static func makeParticles(configuration: RinaStarfieldConfiguration) -> [RinaStarParticle] {
        guard configuration.particleCount > 0 else { return [] }
        return (0..<configuration.particleCount).map { index in
            var generator = SplitMix64(state: configuration.seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            // Depth correlates size, speed and brightness for a mild parallax.
            let depth = pow(generator.unitInterval(), 1.35)
            let reach = lerp(0.45, 1.0, depth)
            return RinaStarParticle(
                x: lerp(0.035, 0.965, generator.unitInterval()),
                size: lerp(configuration.minimumSize, configuration.maximumSize, depth),
                duration: lerp(configuration.maximumDuration, configuration.minimumDuration, depth),
                initialPhase: generator.unitInterval(),
                horizontalSway: generator.signedUnit() * configuration.maximumHorizontalSway * reach,
                linearDrift: generator.signedUnit() * configuration.maximumLinearDrift * reach,
                wavePhase: generator.unitInterval() * .pi * 2,
                // Subtle on purpose: the motion must read as rising, not confetti.
                rotation: generator.signedUnit() * 0.32,
                rotationTravel: generator.signedUnit() * 0.46,
                twinkleSpeed: lerp(0.55, 1.35, generator.unitInterval()),
                maximumOpacity: lerp(0.32, 0.88, depth),
                tone: RinaStarParticle.Tone.allCases[Int(generator.next() % 3)]
            )
        }
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}

// MARK: - View

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

/// Stars drifting up from below the screen, drawn by one `Canvas` per frame
/// rather than one animated view per star.
struct RinaStarfield: View {
    let palette: RinaPalette
    /// Holds the stars where they are (e.g. while the boot loader animates).
    var isPaused = false
    /// Draws the time-zero layout without ever animating — for pixel-stable
    /// screenshots (`-disableStarAnimation YES`).
    var isFrozen = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let configuration = RinaStarfieldConfiguration.appBackground
    private static let particles = RinaStarfieldModel.makeParticles(configuration: configuration)

    var body: some View {
        // Reduce Motion keeps the stars but holds them still.
        let isStatic = isFrozen || reduceMotion
        let isRunning = !isStatic && !isPaused && scenePhase == .active
        TimelineView(.animation(minimumInterval: Self.configuration.frameInterval, paused: !isRunning)) { timeline in
            let time = isStatic ? 0 : RinaStarClock.shared.time(at: timeline.date)
            Canvas(rendersAsynchronously: true) { context, size in
                draw(in: &context, size: size, time: time)
            }
        }
        .onChange(of: isRunning, initial: true) { _, running in
            RinaStarClock.shared.setRunning(running)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Drawing

extension RinaStarfield {
    /// Unit-radius four-point sparkle.
    private static let sparklePath: Path = {
        let inner: CGFloat = 0.18
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -1))
        path.addLine(to: CGPoint(x: inner, y: -inner))
        path.addLine(to: CGPoint(x: 1, y: 0))
        path.addLine(to: CGPoint(x: inner, y: inner))
        path.addLine(to: CGPoint(x: 0, y: 1))
        path.addLine(to: CGPoint(x: -inner, y: inner))
        path.addLine(to: CGPoint(x: -1, y: 0))
        path.addLine(to: CGPoint(x: -inner, y: -inner))
        path.closeSubpath()
        return path
    }()

    private static let glowRadius: CGFloat = 1.55
    private static let glowPath = Path(ellipseIn: CGRect(x: -glowRadius, y: -glowRadius,
                                                         width: glowRadius * 2, height: glowRadius * 2))
    private static let corePath = Path(ellipseIn: CGRect(x: -0.15, y: -0.15, width: 0.3, height: 0.3))

    /// Position and opacity of one star at `time`; nil when it is invisible.
    static func placement(of particle: RinaStarParticle, in size: CGSize, time: TimeInterval,
                          margin: Double) -> (center: CGPoint, progress: Double, opacity: Double)? {
        let progress = wrap(time / particle.duration + particle.initialPhase)
        let height = Double(size.height)
        // progress 0 is just below the bottom edge, 1 just above the top.
        let y = height + margin - progress * (height + margin * 2)
        let x = particle.x * Double(size.width)
            + sin(progress * .pi * 2 + particle.wavePhase) * particle.horizontalSway
            + (progress - 0.5) * particle.linearDrift
        let fade = smoothstep(0, 0.11, progress) * (1 - smoothstep(0.8, 1, progress))
        let twinkle = 0.82 + 0.18 * sin(time * particle.twinkleSpeed + particle.wavePhase)
        let opacity = min(1, particle.maximumOpacity * fade * twinkle)
        guard opacity > 0.005 else { return nil }
        return (CGPoint(x: x, y: y), progress, opacity)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }
        let intensity = palette.starIntensity * (reduceTransparency ? 0.62 : 1)

        for particle in Self.particles {
            guard let placement = Self.placement(of: particle, in: size, time: time,
                                                 margin: Self.configuration.verticalMargin) else { continue }
            let (fill, glow): (Color, Color) = switch particle.tone {
            case .white: (palette.starCore, palette.starGlow)
            case .pink: (palette.starPink, palette.starGlow)
            case .lavender: (palette.starLavender, palette.starLavender)
            }
            let scale = 0.84 + sin(placement.progress * .pi) * 0.16
            let radius = CGFloat(particle.size * scale * 0.5)

            // A copied context instead of `drawLayer`: no offscreen layer per
            // star, and a radial gradient stands in for a blur halo.
            var star = context
            star.opacity = placement.opacity * intensity
            star.translateBy(x: placement.center.x, y: placement.center.y)
            star.rotate(by: .radians(particle.rotation + particle.rotationTravel * placement.progress))
            star.scaleBy(x: radius, y: radius)
            star.fill(Self.glowPath, with: .radialGradient(
                Gradient(colors: [glow.opacity(0.30), glow.opacity(0.12), .clear]),
                center: .zero, startRadius: 0.05, endRadius: Self.glowRadius))
            star.fill(Self.sparklePath, with: .color(fill))
            star.fill(Self.corePath, with: .color(palette.starCore.opacity(0.92)))
        }
    }

    private static func wrap(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - PRNG

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func unitInterval() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func signedUnit() -> Double {
        unitInterval() * 2 - 1
    }
}
