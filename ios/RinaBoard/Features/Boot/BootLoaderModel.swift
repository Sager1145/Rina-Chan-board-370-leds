import Foundation
import Observation

/// State machine for the boot loader (see docs/BOOT_ANIMATION_SPEC.md).
///
/// It owns *when* each phase begins and nothing else: the overlay turns each
/// phase into Core Animation animations built from `BootTimeline`, so there
/// is exactly one clock, no per-frame sampling on the main thread, and no
/// per-property state to drift out of sync.
///
/// Time/asset based only: it never waits on the board.
@Observable
@MainActor
final class BootLoaderModel {
    enum Phase: Equatable {
        case idle
        /// Halo breathing since `since`, waiting for the first screen.
        case breathing(since: Date)
        /// P2…P5 running since `since`.
        case outro(since: Date)
        case done
    }

    private(set) var phase: Phase = .idle
    /// How many first-page cards the waterfall has revealed so far.
    private(set) var revealedCount = 0
    private(set) var revealsAllCards = false

    private(set) var reduceMotion = false
    /// False from P4b on: the overlay stops intercepting touches while the
    /// mask opens and stays inert until it is removed.
    private(set) var interceptsTouches = true
    /// Bumped by `replay()`; the overlay keys its stage view on it.
    private(set) var runID = 0

    var isVisible: Bool { phase != .done }

    var breathPeriod: TimeInterval {
        reduceMotion ? BootTimeline.breathReduced : BootTimeline.breath
    }

    private var sequence: Task<Void, Never>?
    private var waterfall: Task<Void, Never>?
    private var safetyNet: Task<Void, Never>?
    /// A finish requested before `start` (legacy `finishQueued`): the first
    /// screen's `onAppear` can run ahead of the root's.
    private var finishQueued = false
    private var doneContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Card count of the last waterfall, so a replay can re-run it.
    private var waterfallCount = 3

    func isCardRevealed(index: Int) -> Bool {
        revealsAllCards || revealedCount > index
    }

    // MARK: Lifecycle

    /// Idempotent: `onAppear` can fire more than once for the same root view.
    func start(reduceMotion: Bool) {
        guard phase == .idle else { return }
        self.reduceMotion = reduceMotion
        phase = .breathing(since: Date())

        if finishQueued {
            finishQueued = false
            requestFinish()
            return
        }

        // The waterfall is kicked off by the first screen's `onAppear`. If the
        // app launches onto a tab that never calls it, finish anyway so the
        // overlay can't strand the user behind a permanently breathing halo.
        safetyNet = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard let self, case .breathing = self.phase else { return }
            // A waterfall already running owns the handoff; cutting in here
            // would truncate it on a slow launch.
            guard self.waterfall == nil else { return }
            self.revealsAllCards = true
            self.requestFinish()
        }
    }

    /// Waterfall reveal of the first page's cards; requests the outro once it
    /// settles. Runs while the loader still covers the screen — its reveal
    /// mask is what shows the result.
    func beginWaterfall(count: Int) {
        guard waterfall == nil, count > 0 else { return }
        waterfallCount = count
        waterfall = Task { [weak self] in
            guard let self else { return }
            if self.reduceMotion {
                self.revealedCount = count
            } else {
                // The legacy loop sleeps after *every* item, the last one
                // included, before the settle (app.js:13906-13910).
                for index in 0..<count {
                    self.revealedCount = index + 1
                    do { try await Task.sleep(for: .seconds(BootTimeline.waterfallStagger)) }
                    catch { return }
                }
            }
            do { try await Task.sleep(for: .seconds(BootTimeline.waterfallSettle)) }
            catch { return }
            self.requestFinish()
        }
    }

    /// Aligns to the next halo-breath peak when it is near, then runs P2…P5.
    /// Idempotent.
    func requestFinish() {
        if phase == .idle {
            finishQueued = true
            return
        }
        guard case .breathing(let since) = phase, sequence == nil else { return }
        safetyNet?.cancel()

        sequence = Task { [weak self] in
            guard let self else { return }
            let period = self.breathPeriod

            // Hold the loader for at least `minDisplay` so a fast launch does
            // not flash it, then land the outro on a halo peak if one is near.
            let shown = Date().timeIntervalSince(since)
            let minWait = max(0, BootTimeline.minDisplay - shown)
            let peakWait = BootTimeline.delayToHaloPeak(elapsed: shown + minWait, period: period)
            let wait = minWait + peakWait
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }

            self.phase = .outro(since: Date())
            do { try await Task.sleep(for: .seconds(BootTimeline.revealStart)) } catch { return }
            self.interceptsTouches = false
            do {
                try await Task.sleep(for: .seconds(BootTimeline.outroDuration - BootTimeline.revealStart))
            } catch { return }
            self.finish()
        }
    }

    /// Debug aid: run the whole loader again from P0 over whatever screen is
    /// showing. Anything still in flight is cancelled first.
    func replay() {
        sequence?.cancel(); sequence = nil
        waterfall?.cancel(); waterfall = nil
        safetyNet?.cancel(); safetyNet = nil
        finishQueued = false
        revealedCount = 0
        revealsAllCards = false
        interceptsTouches = true
        runID += 1
        phase = .idle
        start(reduceMotion: reduceMotion)
        beginWaterfall(count: waterfallCount)
    }

    private func finish() {
        guard phase != .done else { return }
        phase = .done
        revealsAllCards = true
        let continuations = doneContinuations.values
        doneContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    /// Await full completion of P5. Gates work that must not start while the
    /// loader is showing, e.g. the board status auto-reconnect fetch.
    func waitUntilDone() async {
        if phase == .done { return }
        let id = UUID()
        // Without a cancellation handler this suspends forever if the caller's
        // task is cancelled first — and the caller is the board auto-reconnect,
        // so that would strand the app disconnected with no diagnostic.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if phase == .done {
                    continuation.resume()
                } else {
                    doneContinuations[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.doneContinuations.removeValue(forKey: id)?.resume()
            }
        }
    }
}
