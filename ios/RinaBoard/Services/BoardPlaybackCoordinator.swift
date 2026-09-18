import Foundation

public enum BoardOutputSource: String, Sendable {
    case manual, automatic, text, lipSync, performance, video, debug
    /// A board acting as a member of a `BoardGroupCoordinator` playback
    /// (BOARD_GROUP_SPEC §3): held for the group upload + `group_start`
    /// sequence, and released the moment any single-board action claims a
    /// different source on that same board.
    case group

    public var title: String {
        switch self {
        case .manual: return NSLocalizedString("手动表情", comment: "output source")
        case .automatic: return NSLocalizedString("自动表情", comment: "output source")
        case .text: return NSLocalizedString("滚动文字", comment: "output source")
        case .lipSync: return NSLocalizedString("口型同步", comment: "output source")
        case .performance: return NSLocalizedString("演出", comment: "output source")
        case .video: return NSLocalizedString("视频", comment: "output source")
        case .debug: return NSLocalizedString("调试输出", comment: "output source")
        case .group: return NSLocalizedString("多板组", comment: "output source")
        }
    }
}

/// A lease is invalidated synchronously before old producers are stopped.
/// Wire operations also check it after waiting in the shared output queue.
@Observable @MainActor
public final class BoardPlaybackCoordinator {
    public private(set) var source: BoardOutputSource?
    public private(set) var session: UUID?
    @ObservationIgnored private var stopHandlers: [BoardOutputSource: () -> Void] = [:]
    @ObservationIgnored private var operations: [UUID: [UUID: () -> Void]] = [:]

    public init() {}

    public func register(_ source: BoardOutputSource, stop: @escaping () -> Void) {
        stopHandlers[source] = stop
    }

    @discardableResult
    public func begin(_ source: BoardOutputSource) -> UUID {
        let previous = self.source
        let next = UUID()
        session = next
        self.source = source
        cancelSupersededOperations(keeping: next)
        if let previous { stopHandlers[previous]?() }
        return next
    }

    public func claim(_ source: BoardOutputSource) -> UUID {
        if self.source == source, let session { return session }
        return begin(source)
    }

    public func isCurrent(_ token: UUID) -> Bool { session == token }

    public func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
    }

    /// Registers work that is actively using an output lease. Changing or
    /// invalidating the lease cancels the work immediately, so a request that
    /// is waiting for a board reply cannot hold the shared output queue until
    /// its timeout expires.
    func registerOperation(for token: UUID, cancel: @escaping () -> Void) -> UUID? {
        guard isCurrent(token) else {
            cancel()
            return nil
        }
        let id = UUID()
        operations[token, default: [:]][id] = cancel
        return id
    }

    func unregisterOperation(_ id: UUID, for token: UUID) {
        operations[token]?.removeValue(forKey: id)
        if operations[token]?.isEmpty == true {
            operations.removeValue(forKey: token)
        }
    }

    public func invalidate() {
        let previous = source
        session = nil
        source = nil
        cancelSupersededOperations(keeping: nil)
        if let previous { stopHandlers[previous]?() }
    }

    private func cancelSupersededOperations(keeping token: UUID?) {
        let superseded = operations.filter { $0.key != token }
        for oldToken in superseded.keys {
            operations.removeValue(forKey: oldToken)
        }
        for cancellation in superseded.values.flatMap(\.values) {
            cancellation()
        }
    }
}

enum BoardOutputContext {
    @TaskLocal static var session: UUID?
}
