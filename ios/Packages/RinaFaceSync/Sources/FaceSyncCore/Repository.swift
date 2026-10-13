import Foundation

/// No network suspension inside a local transaction. Content + outbox and
/// inbound operations + an optional opaque cloud checkpoint commit together.
public actor FaceRepository {
    public nonisolated let scope: StoreScope
    public nonisolated let writerID: String
    private let db: SQLite
    public init(path: String, scope: StoreScope, writerID: String) throws {
        guard validID(writerID), !writerID.contains(":"), validID(scope.libraryID),
              [scope.container, scope.environment, scope.account, scope.database, scope.zoneOwner, scope.zoneName].allSatisfy({ !$0.isEmpty }) else {
            throw FaceSyncError.invalid("Missing storage/account identity")
        }
        self.scope = scope; self.writerID = writerID
        db = try SQLite(path)
        try db.transaction {
            let identity = try encoded(scope)
            if let old = try db.metadata("scope"), old != identity { throw FaceSyncError.scopeMismatch }
            if let schema = try db.metadata("schema"), schema != Data("2".utf8) {
                throw FaceSyncError.recoveryRequired("Unsupported database schema")
            }
            try db.setMetadata("scope", identity)
            try db.setMetadata("schema", Data("2".utf8))
        }
    }
    public func operations() throws -> [FaceOperation] {
        try db.rows("SELECT body FROM operations ORDER BY id")
            .map { try JSONDecoder().decode(FaceOperation.self, from: $0[0]) }
    }
    /// Operations present in the local DB whose causal dependency never arrived
    /// (still in `remaining` after reduction), e.g. an orphaned child op.
    public func unresolved() throws -> [FaceOperation] {
        let ids = Set(try state().unresolvedIDs)
        return try operations().filter { ids.contains($0.id) }
    }
    /// Flags a stuck operation as abandoned. This does NOT delete the row: an
    /// abandoned op stays in the DB and, once it becomes causally contiguous
    /// for its actor, is applied by the reducer as a quarantined no-op so the
    /// vector still advances and later ops from the same actor are never
    /// wedged behind it. Only an operation that is currently unresolved may be
    /// abandoned — abandoning an already-applied op would be destructive.
    public func abandonUnresolved(_ opID: String) throws {
        try db.transaction {
            guard try state().unresolvedIDs.contains(opID) else {
                throw FaceSyncError.invalid("Only an unresolved operation can be abandoned")
            }
            var ids = try abandonedIDs()
            ids.insert(opID)
            try db.setMetadata("abandoned", try encoded(ids.sorted()))
        }
    }
    /// Removes the abandoned flag, restoring normal reduction for this op.
    public func unabandon(_ opID: String) throws {
        try db.transaction {
            var ids = try abandonedIDs()
            ids.remove(opID)
            try db.setMetadata("abandoned", try encoded(ids.sorted()))
        }
    }
    private func abandonedIDs() throws -> Set<String> {
        guard let data = try db.metadata("abandoned") else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: data))
    }
    public func state() throws -> LibraryState { try FaceReducer.reduce(operations(), abandoned: abandonedIDs()) }
    public func checkout(_ id: String) throws -> FaceState {
        guard let face = try state().faces[id], !face.deleted else { throw FaceSyncError.deleted }
        return face
    }
    public func pending() throws -> [FaceOperation] {
        try db.rows("SELECT body FROM operations WHERE pending=1 ORDER BY id").map {
            try JSONDecoder().decode(FaceOperation.self, from: $0[0])
        }
    }
    public func cloudState() throws -> Data? { try db.metadata("cloudState") }
    public func persistCloudState(_ state: Data) throws { try db.setMetadata("cloudState", state) }
    /// Token expiry invalidates discovery state, never content, outbox or tombstones.
    public func resetCloudState() throws {
        try db.execute("DELETE FROM metadata WHERE key=?", [Data("cloudState".utf8)])
    }
    public func ingest(_ incoming: [FaceOperation], checkpoint: Data? = nil,
                       viaPeer: Bool = false, failBeforeCommit: Bool = false) throws {
        try db.transaction {
            for op in incoming { try insert(op, pending: viaPeer) }
            _ = try state() // Invalid ready dependency graphs roll back, missing dependencies stay in inbox.
            if let checkpoint { try db.setMetadata("cloudState", checkpoint) }
            if failBeforeCommit { throw FaceSyncError.sqlite("Injected pre-commit failure") }
        }
    }
    private func insert(_ op: FaceOperation, pending: Bool) throws {
        try op.validate()
        guard op.libraryID == scope.libraryID else { throw FaceSyncError.scopeMismatch }
        let key = Data(op.id.utf8)
        if let existing = try db.rows("SELECT body FROM operations WHERE id=?", [key]).first {
            guard try JSONDecoder().decode(FaceOperation.self, from: existing[0]) == op else {
                throw FaceSyncError.immutableCollision
            }
            // A peer echo is not cloud acknowledgment and cannot clear the outbox.
            if !pending { try db.execute("UPDATE operations SET pending=0 WHERE id=?", [key]) }
            return
        }
        try db.execute("INSERT INTO operations(id,body,pending) VALUES(?,?,\(pending ? 1 : 0))", [key, try encoded(op)])
    }
    public func acknowledge(_ confirmed: [FaceOperation]) throws {
        try db.transaction {
            for op in confirmed {
                guard let row = try db.rows("SELECT body FROM operations WHERE id=?", [Data(op.id.utf8)]).first,
                      try JSONDecoder().decode(FaceOperation.self, from: row[0]) == op else {
                    throw FaceSyncError.immutableCollision
                }
                try db.execute("UPDATE operations SET pending=0 WHERE id=?", [Data(op.id.utf8)])
            }
            // Upload acknowledgment must NEVER change cloudState / fetch token.
        }
    }
    @discardableResult public func create(name: String, artwork: Artwork = Artwork(),
                                          entityID: String = UUID().uuidString.lowercased(),
                                          restoredFrom: String? = nil) throws -> FaceOperation {
        try local(entityID: entityID, kind: "create", writes: [
            "name": .init(parents: [], value: .name(name)),
            "artwork": .init(parents: [], value: .artwork(artwork))
        ], restoredFrom: restoredFrom)
    }
    @discardableResult public func update(base: FaceState, values: [FieldValue]) throws -> FaceOperation {
        guard !values.isEmpty, Set(values.map(\.field)).count == values.count,
              !values.contains(where: { $0.field == "order" }) else { throw FaceSyncError.invalid("Invalid update fields") }
        var writes: [String: FieldWrite] = [:]
        for value in values {
            guard let register = base.fields[value.field] else { throw FaceSyncError.invalid("Missing editor baseline") }
            writes[value.field] = FieldWrite(parents: register.heads, value: value)
        }
        return try local(entityID: base.id, kind: "update", writes: writes, base: base)
    }
    @discardableResult public func delete(base: FaceState) throws -> FaceOperation {
        try local(entityID: base.id, kind: "delete", writes: [:], base: base)
    }
    @discardableResult public func reorder(_ ids: [String], base: Register?) throws -> FaceOperation {
        try local(entityID: orderEntity, kind: "order",
                  writes: ["order": .init(parents: base?.heads ?? [], value: .order(ids))])
    }
    private func local(entityID: String, kind: String, writes: [String: FieldWrite],
                       base: FaceState? = nil, restoredFrom: String? = nil) throws -> FaceOperation {
        try db.transaction {
            let before = try state()
            // A stuck inbox op belonging to another actor must never block this
            // actor's own local writes; see FaceRepository.unresolved().
            if let base {
                guard let current = before.faces[entityID], !current.deleted, !base.deleted,
                      let baseCreateID = base.createID,
                      current.createIDs.contains(baseCreateID) else { throw FaceSyncError.deleted }
            }
            let op = FaceOperation(libraryID: scope.libraryID, actorID: writerID,
                                   counter: before.vector[writerID] + 1, context: before.vector,
                                   entityID: entityID, kind: kind, createID: base?.createID,
                                   writes: writes, restoredFrom: restoredFrom)
            try insert(op, pending: true)
            return op
        }
    }
    public func saveDeploymentJob(_ job: DeploymentRequest) throws {
        guard job.libraryID == scope.libraryID else { throw FaceSyncError.scopeMismatch }
        try db.transaction {
            if let existing = try deploymentJob(boardID: job.boardID), existing != job {
                throw FaceSyncError.recoveryRequired("Unresolved deployment job must not be overwritten")
            }
            try db.setMetadata("job:\(job.boardID)", try encoded(job))
        }
    }
    public func deploymentJob(boardID: String) throws -> DeploymentRequest? {
        try db.metadata("job:\(boardID)").map { try JSONDecoder().decode(DeploymentRequest.self, from: $0) }
    }
    public func finishDeploymentJob(boardID: String, transactionID: String) throws {
        try db.transaction {
            guard let job = try deploymentJob(boardID: boardID), job.transactionID == transactionID else {
                throw FaceSyncError.staleBoard
            }
            try db.execute("DELETE FROM metadata WHERE key=?", [Data("job:\(boardID)".utf8)])
        }
    }
}
