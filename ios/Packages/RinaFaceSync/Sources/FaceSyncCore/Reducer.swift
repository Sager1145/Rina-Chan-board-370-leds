import Foundation

/// A deterministic materializer. Only causally closed, contiguous operations are
/// applied. A child received before its parent remains in a durable inbox.
///
/// Semantically invalid operations (wrong create identity, a field parent that
/// does not belong, a create missing from the causal context) are never
/// discarded or thrown away: they are quarantined and applied as no-ops so the
/// vector still advances past them and a misbehaving actor cannot wedge the
/// rest of its own history. `immutableCollision` and `scopeMismatch` remain
/// hard errors — those indicate real corruption, not a stray peer operation.
///
/// `abandoned` ids (see `FaceRepository.abandonUnresolved`) are handled the
/// same way: once an abandoned op becomes causally contiguous for its actor
/// it is quarantined as a no-op WITHOUT requiring its createID/parents to be
/// known, so a permanently-missing dependency can never wedge the rest of
/// that actor's history. Its content is ignored; dependents are quarantined
/// transitively exactly like any other quarantined op.
public enum FaceReducer {
    public static func reduce(_ operations: [FaceOperation], abandoned: Set<String> = []) throws -> LibraryState {
        var remaining: [String: FaceOperation] = [:]
        var library: String?
        for op in operations {
            try op.validate()
            if let library, library != op.libraryID { throw FaceSyncError.scopeMismatch }
            library = op.libraryID
            if let old = remaining[op.id], old != op { throw FaceSyncError.immutableCollision }
            remaining[op.id] = op
        }
        var known: [String: FaceOperation] = [:]
        var quarantined: [String: String] = [:]
        var vector = VersionVector()
        while !remaining.isEmpty {
            var progressed = false
            for id in remaining.keys.sorted(by: opIDLess) {
                guard let op = remaining[id], vector.covers(op.context),
                      op.counter == vector[op.actorID] + 1 else { continue }
                if abandoned.contains(id) {
                    quarantined[id] = "Abandoned by user"
                    known[id] = op
                    remaining.removeValue(forKey: id)
                    vector.counters[op.actorID] = op.counter
                    try vector.validated()
                    progressed = true
                    continue
                }
                let parents = op.writes.values.flatMap(\.parents)
                guard parents.allSatisfy({ known[$0] != nil }),
                      op.createID == nil || known[op.createID!] != nil else { continue }

                var reason: String?
                // Transitivity: an op that cites a quarantined create, or that
                // carries a field parent pointing at a quarantined op, is itself
                // quarantined even though it is otherwise well formed.
                if let createID = op.createID, let ancestor = quarantined[createID] {
                    reason = "Create is quarantined: \(ancestor)"
                }
                if reason == nil {
                    outer: for write in op.writes.values {
                        for parentID in write.parents {
                            if let ancestor = quarantined[parentID] {
                                reason = "Field parent is quarantined: \(ancestor)"
                                break outer
                            }
                        }
                    }
                }
                // Concurrent creates of the same entityID MERGE: no check here.
                // Multiple "create" ops for one entityID simply both stay known;
                // their name/artwork writes become additional register heads.
                if reason == nil, let createID = op.createID {
                    if let create = known[createID], create.kind == "create", create.entityID == op.entityID {
                        // ok
                    } else {
                        reason = "Wrong create identity"
                    }
                }
                if reason == nil {
                    outer: for (field, write) in op.writes {
                        for parentID in write.parents {
                            guard let parent = known[parentID], parent.entityID == op.entityID,
                                  parent.writes[field] != nil,
                                  op.context[parent.actorID] >= parent.counter else {
                                reason = "Parent does not belong to this field/causal context"
                                break outer
                            }
                        }
                    }
                }
                if reason == nil, let createID = op.createID, let create = known[createID],
                   op.context[create.actorID] < create.counter {
                    reason = "Create missing from causal context"
                }

                if let reason { quarantined[id] = reason }
                known[id] = op
                remaining.removeValue(forKey: id)
                vector.counters[op.actorID] = op.counter
                try vector.validated()
                progressed = true
            }
            if !progressed { break }
        }
        var writes: [String: [String: [String: FieldValue]]] = [:]
        var consumed: [String: [String: Set<String>]] = [:]
        var creates: [String: [String]] = [:]
        var deleted = Set<String>()
        for op in known.values where quarantined[op.id] == nil {
            if op.kind == "create" { creates[op.entityID, default: []].append(op.id) }
            // Delete wins: a concurrent create merged into an entity that
            // another replica deleted stays deleted. This is a legitimate
            // causal outcome, not corruption, so it is surfaced via
            // FaceState.deleted rather than quarantined.
            if op.kind == "delete" { deleted.insert(op.entityID) }
            for (field, write) in op.writes {
                writes[op.entityID, default: [:]][field, default: [:]][op.id] = write.value
                consumed[op.entityID, default: [:]][field, default: []].formUnion(write.parents)
            }
        }
        var registers: [String: [String: Register]] = [:]
        for (entity, fields) in writes {
            for (field, values) in fields {
                let removed = consumed[entity]?[field] ?? []
                registers[entity, default: [:]][field] = Register(versions: values.filter { !removed.contains($0.key) })
            }
        }
        var faces: [String: FaceState] = [:]
        for (id, createIDs) in creates {
            faces[id] = FaceState(id: id, createIDs: createIDs.sorted(by: opIDLess),
                                  deleted: deleted.contains(id), fields: registers[id] ?? [:])
        }
        let visible = Set(faces.values.filter { !$0.deleted }.map(\.id))
        let orderRegister = registers[orderEntity]?["order"]
        var ordered: [String] = []
        if case .order(let ids) = orderRegister?.selected { ordered = ids.filter { visible.contains($0) } }
        ordered += visible.subtracting(ordered).sorted()
        let unresolvedIDs = remaining.keys.sorted(by: opIDLess)
        return LibraryState(faces: faces, order: ordered, orderRegister: orderRegister,
                            vector: vector, unresolvedOperations: remaining.count,
                            unresolvedIDs: unresolvedIDs, quarantined: quarantined)
    }
}
