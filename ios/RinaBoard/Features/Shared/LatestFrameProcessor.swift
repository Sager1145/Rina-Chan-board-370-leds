import Foundation

/// A "latest input wins" off-main-actor processing pipeline: `submit` starts
/// `transform` immediately if idle, or replaces the single pending input if a
/// transform is already in flight (an older pending input is simply dropped,
/// never queued). Each result hops back to the main actor and is delivered
/// only if it is still current — i.e. `invalidate()` was not called after the
/// input that produced it was submitted, and `transform` did not return nil.
/// Modelled on `LatestValueSender`, but for CPU-bound work that must run off
/// the main actor rather than an async network/BLE send.
@MainActor
final class LatestFrameProcessor<Input: Sendable, Output: Sendable> {
    private let priority: TaskPriority
    private let transform: @Sendable (Input) -> Output?
    private let deliver: @MainActor (Output) -> Void
    private var pending: Input?
    private var generation = 0
    private(set) var isBusy = false

    init(priority: TaskPriority = .userInitiated,
         transform: @escaping @Sendable (Input) -> Output?,
         deliver: @escaping @MainActor (Output) -> Void) {
        self.priority = priority
        self.transform = transform
        self.deliver = deliver
    }

    /// Records `input` as the next thing to process. If nothing is currently
    /// running, starts immediately; otherwise becomes the single pending
    /// input, replacing any older one that had not started yet.
    func submit(_ input: Input) {
        guard !isBusy else {
            pending = input
            return
        }
        start(input)
    }

    /// Bumps the generation and drops any pending input. A transform already
    /// in flight keeps running, but its result is discarded on arrival.
    func invalidate() {
        generation += 1
        pending = nil
    }

    private func start(_ input: Input) {
        isBusy = true
        let generationAtStart = generation
        let transform = transform
        Task.detached(priority: priority) { [weak self] in
            let output = transform(input)
            await MainActor.run { [weak self] in
                self?.completed(output: output, generation: generationAtStart)
            }
        }
    }

    private func completed(output: Output?, generation completedGeneration: Int) {
        isBusy = false
        if completedGeneration == generation, let output {
            deliver(output)
        }
        if let next = pending {
            pending = nil
            start(next)
        }
    }
}
