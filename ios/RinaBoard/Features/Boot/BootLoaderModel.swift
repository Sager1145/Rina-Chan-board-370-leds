import SwiftUI
import Observation

/// Drives the legacy WebUI boot-loader animation (see docs/BOOT_ANIMATION_SPEC.md).
/// Time/asset based only: never waits on the board.
@Observable
@MainActor
final class BootLoaderModel {
    enum Phase {
        case idle, breathing, aligning, contracting, hold, releasing, done
    }

    // MARK: Constants (docs/BOOT_ANIMATION_SPEC.md)
    private static let minDisplayMs: Double = 400
    private static let haloBreathMs: Double = 1620
    private static let haloBreathReducedMs: Double = 2600
    private static let haloToleranceMs: Double = 24
    private static let haloContractMs: Double = 520
    private static let avatarPopMs: Double = 620
    private static let holdMs: Double = 260
    private static let releaseMs: Double = 2100
    private static let imgShrinkMs: Double = 378 // round(2100 * 0.18)
    private static let blurDurationMs: Double = 850
    private static let extraMs: Double = 180
    private static let waterfallStaggerMs: Double = 115
    private static let waterfallSettleMs: Double = 260

    // MARK: Public state
    private(set) var phase: Phase = .idle
    var isVisible: Bool { phase != .done }

    // Halo
    var haloOpacity: Double = 0.28
    var haloScale: CGFloat = 0.965
    var haloVisible: Bool = true

    // Avatar
    var avatarScale: CGFloat = 1.0
    var avatarOpacity: Double = 1.0
    var iconDefaultOpacity: Double = 1.0
    var iconHoverOpacity: Double = 0.0

    // Text
    var textOpacity: Double = 1.0
    var textOffsetY: CGFloat = 0

    // Reveal mask (0...1), driven by a 60 Hz task loop.
    var revealProgress: Double = 0
    var hitTestingEnabled: Bool = true

    // Waterfall
    private(set) var revealedCount: Int = 0

    var reduceMotion: Bool = false

    private var startTime: Date?
    private var breathStart: Date?
    private var finishRequested = false
    private var doneContinuations: [CheckedContinuation<Void, Never>] = []
    private var breathTask: Task<Void, Never>?

    private var breathPeriodMs: Double {
        reduceMotion ? Self.haloBreathReducedMs : Self.haloBreathMs
    }

    // MARK: Lifecycle

    func start() {
        guard phase == .idle else { return }
        startTime = Date()
        breathStart = startTime
        phase = .breathing
        startBreathing()
    }

    private func startBreathing() {
        breathTask?.cancel()
        let period = breathPeriodMs / 1000.0
        withAnimation(
            .timingCurve(0.42, 0, 0.58, 1, duration: period / 2)
                .repeatForever(autoreverses: true)
        ) {
            haloOpacity = 1.0
            haloScale = 1.075
        }
    }

    /// Waterfall reveal of the first-page cards. Starts on `.onAppear` of
    /// the first screen; after it settles it requests the loader finish.
    func beginWaterfall(count: Int) {
        guard revealedCount == 0, count > 0 else { return }
        Task {
            if reduceMotion {
                revealedCount = count
            } else {
                for i in 0..<count {
                    revealedCount = i + 1
                    if i < count - 1 {
                        try? await Task.sleep(nanoseconds: UInt64(Self.waterfallStaggerMs * 1_000_000))
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.waterfallSettleMs * 1_000_000))
            await requestFinish()
        }
    }

    /// Called once the first screen has laid out (and the waterfall has
    /// settled). Aligns to the next halo-breath peak, then runs P2-P5.
    func requestFinish() async {
        guard !finishRequested, phase == .breathing else { return }
        finishRequested = true
        phase = .aligning

        let elapsedMs = Date().timeIntervalSince(startTime ?? Date()) * 1000
        let minWaitMs = max(0, Self.minDisplayMs - elapsedMs)
        if minWaitMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(minWaitMs * 1_000_000))
        }

        await alignToHaloPeak()
        await runContractAndPop()
        await runHold()
        await runReleaseAndReveal()
        finish()
    }

    private func alignToHaloPeak() async {
        let period = breathPeriodMs
        let peakOffset = period / 2
        let since = Date().timeIntervalSince(breathStart ?? Date()) * 1000
        let cycle = since.truncatingRemainder(dividingBy: period)
        var wait = peakOffset - cycle
        if wait < 0 { wait += period }
        if wait <= Self.haloToleranceMs { wait += period }
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000))
        }
    }

    // MARK: P2 contract + pop

    private func runContractAndPop() async {
        phase = .contracting
        breathTask?.cancel()

        withAnimation(.timingCurve(0.55, 0.085, 0.68, 0.53, duration: Self.haloContractMs / 1000)) {
            haloScale = 0.65
            haloOpacity = 0
        }
        withAnimation(.timingCurve(0.16, 1.25, 0.3, 1, duration: Self.avatarPopMs / 1000)) {
            avatarScale = 1.22
        }
        withAnimation(.linear(duration: 0.001)) {
            iconDefaultOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.22)) {
            textOpacity = 0
            textOffsetY = -6
        }

        // Default icon holds 180ms then snaps off while hover fades in over 180ms.
        try? await Task.sleep(nanoseconds: UInt64(180 * 1_000_000))
        iconDefaultOpacity = 0
        withAnimation(.easeInOut(duration: 0.18)) {
            iconHoverOpacity = 1
        }

        let remaining = Self.haloContractMs - 180
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000))
        }
        haloVisible = false
    }

    // MARK: P3 hold

    private func runHold() async {
        phase = .hold
        try? await Task.sleep(nanoseconds: UInt64(Self.holdMs * 1_000_000))
    }

    // MARK: P4 release + P4b reveal

    private func runReleaseAndReveal() async {
        phase = .releasing

        // Avatar release keyframes: 0% -> 18% (378ms) -> 100% (2100ms).
        withAnimation(.timingCurve(0.34, 0, 0.2, 1, duration: Self.imgShrinkMs / 1000)) {
            avatarScale = 1.12
        }

        async let releaseTail: Void = { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.imgShrinkMs * 1_000_000))
            withAnimation(.timingCurve(0.12, 0.88, 0.18, 1, duration: (Self.releaseMs - Self.imgShrinkMs) / 1000)) {
                self.avatarScale = 2.35
                self.avatarOpacity = 0
            }
        }()

        async let reveal: Void = { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.imgShrinkMs * 1_000_000))
            self.hitTestingEnabled = false
            await self.runRevealMask()
        }()

        _ = await (releaseTail, reveal)

        let elapsedInPhase = max(Self.releaseMs, Self.imgShrinkMs + Self.blurDurationMs)
        // Ensure phase-4 total time has elapsed before P5.
        _ = elapsedInPhase
    }

    private func runRevealMask() async {
        let durationMs = Self.blurDurationMs
        let start = Date()
        while true {
            let t = min(1, Date().timeIntervalSince(start) * 1000 / durationMs)
            revealProgress = Self.easeInCubic(t)
            if t >= 1 { break }
            try? await Task.sleep(nanoseconds: 16_000_000) // ~60Hz
        }
    }

    private static func easeInCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func finish() {
        withAnimation(.easeOut(duration: Self.extraMs / 1000)) {
            // overlay opacity handled by BootLoaderOverlay observing `isVisible`.
        }
        phase = .done
        let continuations = doneContinuations
        doneContinuations.removeAll()
        for c in continuations { c.resume() }
    }

    /// Await until the loader has fully finished (P5 complete). Used to
    /// gate work that must not start while the loader is showing, e.g. the
    /// board status auto-reconnect fetch.
    func waitUntilDone() async {
        if phase == .done { return }
        await withCheckedContinuation { continuation in
            doneContinuations.append(continuation)
        }
    }
}
