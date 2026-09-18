import Foundation

/// Which board(s) the board-wide controls act on: the Control Center's board
/// summary/brightness/mode/colour sections, its accessory, and the Text
/// tab's send/stop (BOARD_GROUP_SPEC.md §3's "多板组" menu requirement).
/// Persisted as a single `@AppStorage(ControlTargetKey.groupID)` string —
/// empty means `.single`, anything else is a `BoardGroup.id`.
enum ControlTarget: Equatable, Sendable {
    case single
    case group(UUID)

    /// Parses the persisted `@AppStorage` string form. Does not validate
    /// against a `BoardGroupStore` — see `resolved(storedGroupIDString:in:)`
    /// for the validated read used everywhere the target is displayed/acted
    /// on.
    init(storedGroupIDString: String) {
        if let id = UUID(uuidString: storedGroupIDString) {
            self = .group(id)
        } else {
            self = .single
        }
    }

    /// The `@AppStorage`-backed string form to persist.
    var storedGroupIDString: String {
        switch self {
        case .single: return ""
        case .group(let id): return id.uuidString
        }
    }

    /// The validated read: a stored group id that no longer exists in
    /// `store` (deleted, or never valid) reads back as `.single`. Pure — does
    /// not touch the persisted value; call `validate(_:in:)` from a
    /// non-view-body context (`.task`, `.onChange`, a delete action) to reset
    /// the stale storage itself.
    @MainActor
    static func resolved(storedGroupIDString: String, in store: BoardGroupStore) -> ControlTarget {
        let target = ControlTarget(storedGroupIDString: storedGroupIDString)
        guard case .group(let id) = target else { return .single }
        return store.groups.contains(where: { $0.id == id }) ? target : .single
    }

    /// Resets `stored` to `.single`'s empty string if it currently names a
    /// group that no longer exists in `store`. Safe to call from `.task`/
    /// `.onChange`/a delete action; must not be called from inside a view's
    /// `body`.
    @MainActor
    static func validate(_ stored: inout String, in store: BoardGroupStore) {
        guard case .group(let id) = ControlTarget(storedGroupIDString: stored),
              !store.groups.contains(where: { $0.id == id }) else { return }
        stored = ""
    }
}

/// The `@AppStorage` key that persists the current `ControlTarget`.
enum ControlTargetKey {
    static let groupID = "controlTarget.groupID"
}
