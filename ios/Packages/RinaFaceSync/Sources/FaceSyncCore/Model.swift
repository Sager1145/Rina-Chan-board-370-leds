import Foundation

public enum FaceSyncError: Error, Equatable, Sendable {
    case invalid(String), scopeMismatch, immutableCollision, missingDependencies
    case recoveryRequired(String), conflict, deleted, capacity, staleBoard, wrongBoard
    case versionRollback, ambiguousVersion, staleSession, busy, sqlite(String)
}

/// This key is LOCAL ONLY. An operation carries libraryID, not another user's account key.
public struct StoreScope: Codable, Equatable, Sendable {
    public var container: String
    public var environment: String
    public var account: String
    public var database: String
    public var zoneOwner: String
    public var zoneName: String
    public var libraryID: String
    public init(container: String, environment: String, account: String,
                database: String, zoneOwner: String, zoneName: String, libraryID: String) {
        self.container = container; self.environment = environment; self.account = account
        self.database = database; self.zoneOwner = zoneOwner; self.zoneName = zoneName
        self.libraryID = libraryID
    }
}

public struct VersionVector: Codable, Equatable, Sendable {
    public var counters: [String: Int64]
    public init(_ counters: [String: Int64] = [:]) { self.counters = counters }
    public subscript(_ actor: String) -> Int64 { counters[actor, default: 0] }
    public func covers(_ other: Self) -> Bool {
        other.counters.allSatisfy { self[$0.key] >= $0.value }
    }
    public func validated(maxActors: Int = 64) throws {
        guard counters.count <= maxActors,
              counters.allSatisfy({ validID($0.key) && $0.value > 0 }) else {
            throw FaceSyncError.invalid("Version vector must contain positive contiguous prefixes; max 64 actors")
        }
    }
}

public struct Artwork: Codable, Equatable, Sendable {
    public var frameHex: String
    public var kind: String
    public var call: [String: String]?
    public init(frameHex: String = String(repeating: "00", count: 47),
                kind: String = "custom", call: [String: String]? = nil) {
        self.frameHex = frameHex; self.kind = kind; self.call = call
    }
    public func validate(allowPreset: Bool = false) throws {
        guard frameHex.utf8.count == 94, frameHex.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw FaceSyncError.invalid("Frame must contain 47 bytes in lowercase hex") }
        if kind == "parts" {
            guard let call, Set(call.keys) == ["leye", "reye", "mouth", "cheek"],
                  call.values.allSatisfy(validID) else { throw FaceSyncError.invalid("Invalid parts") }
        } else {
            guard (kind == "custom" || (allowPreset && kind == "default")), call == nil else {
                throw FaceSyncError.invalid("Invalid artwork kind/call")
            }
        }
    }
}

public enum FieldValue: Codable, Equatable, Sendable {
    case name(String), artwork(Artwork), order([String])
    public var field: String {
        switch self { case .name: "name"; case .artwork: "artwork"; case .order: "order" }
    }
    public func validate() throws {
        switch self {
        case .name(let value): try validateName(value)
        case .artwork(let value): try value.validate()
        case .order(let value):
            guard value.count <= 2048, value.allSatisfy(validID), Set(value).count == value.count,
                  !value.contains(orderEntity) else { throw FaceSyncError.invalid("Invalid ordering") }
        }
    }
}

public let orderEntity = "_library_order"
public struct FieldWrite: Codable, Equatable, Sendable {
    public var parents: [String]
    public var value: FieldValue
    public init(parents: [String], value: FieldValue) { self.parents = parents.sorted(by: opIDLess); self.value = value }
}

public struct FaceOperation: Codable, Equatable, Sendable {
    public var schema: Int = 2
    public var libraryID: String
    public var actorID: String
    public var counter: Int64
    /// Delivery knowledge, NOT an editor baseline. Field parents carry the latter.
    public var context: VersionVector
    public var entityID: String
    public var kind: String
    public var createID: String?
    public var writes: [String: FieldWrite]
    public var restoredFrom: String?
    public var id: String { "\(actorID):\(counter)" }
    public init(libraryID: String, actorID: String, counter: Int64, context: VersionVector,
                entityID: String, kind: String, createID: String? = nil,
                writes: [String: FieldWrite] = [:], restoredFrom: String? = nil) {
        self.libraryID = libraryID; self.actorID = actorID; self.counter = counter; self.context = context
        self.entityID = entityID; self.kind = kind; self.createID = createID
        self.writes = writes; self.restoredFrom = restoredFrom
    }
    public func validate() throws {
        guard schema == 2, [libraryID, actorID, entityID].allSatisfy(validID),
              !actorID.contains(":"), validID(id), counter > 0, counter < Int64.max,
              context[actorID] == counter - 1 else { throw FaceSyncError.invalid("Invalid operation identity/sequence") }
        try context.validated()
        guard Set(context.counters.keys).union([actorID]).count <= 64 else { throw FaceSyncError.capacity }
        let fields = Set(writes.keys)
        switch kind {
        case "create":
            guard createID == nil, fields == ["name", "artwork"], entityID != orderEntity else {
                throw FaceSyncError.invalid("Invalid create")
            }
        case "update":
            guard createID.map(validID) == true, !fields.isEmpty,
                  fields.isSubset(of: ["name", "artwork"]), entityID != orderEntity else {
                throw FaceSyncError.invalid("Invalid update")
            }
        case "delete":
            guard createID.map(validID) == true, writes.isEmpty, entityID != orderEntity else {
                throw FaceSyncError.invalid("Invalid delete")
            }
        case "order":
            guard entityID == orderEntity, fields == ["order"], createID == nil else {
                throw FaceSyncError.invalid("Invalid order")
            }
        default: throw FaceSyncError.invalid("Unknown operation")
        }
        if let restoredFrom {
            guard kind == "create", validID(restoredFrom), restoredFrom != entityID else {
                throw FaceSyncError.invalid("Invalid restore")
            }
        }
        for (field, write) in writes {
            guard write.value.field == field, write.parents.count <= 256,
                  write.parents.allSatisfy(validID), Set(write.parents).count == write.parents.count,
                  !write.parents.contains(id),
                  (kind != "create" || write.parents.isEmpty),
                  (kind != "update" || !write.parents.isEmpty) else {
                throw FaceSyncError.invalid("Invalid field parents")
            }
            try write.value.validate()
        }
        guard try encoded(self).count <= 65536 else { throw FaceSyncError.capacity }
    }
}

public struct Register: Equatable, Sendable {
    public var versions: [String: FieldValue]
    public var heads: [String] { versions.keys.sorted(by: opIDLess) }
    public var conflict: Bool {
        guard let first = versions.values.first else { return false }
        return versions.values.contains { $0 != first }
    }
    public var selected: FieldValue? { heads.last.flatMap { versions[$0] } }
}
public struct FaceState: Equatable, Sendable {
    public var id: String
    /// Concurrent creates of the same entityID merge rather than conflict; every
    /// contributing create id is kept (sorted, never empty for an existing entity).
    public var createIDs: [String]
    public var deleted: Bool
    public var fields: [String: Register]
    public var conflict: Bool { fields.values.contains(where: \.conflict) }
    /// Convenience for call sites that only need one create id (e.g. issuing a
    /// new op that cites the create it was based on).
    public var createID: String? { createIDs.first }
}
public struct LibraryState: Equatable, Sendable {
    public var faces: [String: FaceState]
    public var order: [String]
    public var orderRegister: Register?
    public var vector: VersionVector
    public var unresolvedOperations: Int
    /// Operation ids left in the durable inbox (causal dependency never arrived).
    public var unresolvedIDs: [String]
    /// Operation id -> reason. Semantically invalid ops apply as no-ops instead of
    /// corrupting the store; the vector still advances past them.
    public var quarantined: [String: String]
    public var conflict: Bool {
        faces.values.contains { !$0.deleted && $0.conflict } || (orderRegister?.conflict == true)
    }
}

/// Orders "actor:counter" operation ids by (actorID, counter as Int64) so that
/// e.g. "a:10" sorts after "a:9" — a plain string sort would not.
public func opIDLess(_ a: String, _ b: String) -> Bool {
    let (actorA, counterA) = splitOpID(a)
    let (actorB, counterB) = splitOpID(b)
    if actorA != actorB { return actorA < actorB }
    return counterA < counterB
}
private func splitOpID(_ id: String) -> (String, Int64) {
    guard let colon = id.firstIndex(of: ":") else { return (id, 0) }
    let actor = String(id[id.startIndex..<colon])
    let counter = Int64(id[id.index(after: colon)...]) ?? 0
    return (actor, counter)
}

func validID(_ text: String) -> Bool {
    (1...128).contains(text.utf8.count) && text.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [95, 45, 46, 58].contains($0)
    }
}
func validateName(_ name: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          name.utf8.count <= 64 else { throw FaceSyncError.invalid("Name must contain 1..64 UTF-8 bytes") }
}
public func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
