import Foundation
import Testing
@testable import FaceSyncCore

private let scope = StoreScope(container: "iCloud.test.rina", environment: "Development", account: "user1",
                               database: "private", zoneOwner: "owner", zoneName: "Faces", libraryID: "lib")
private func repo(_ actor: String = UUID().uuidString.lowercased(), path: String = ":memory:") throws -> FaceRepository {
    try FaceRepository(path: path, scope: scope, writerID: actor)
}

// MARK: - 1. Op-id ordering

@Test func opIDLessOrdersByCounterNotLexicographically() {
    #expect(opIDLess("a:9", "a:10"))
    #expect(!opIDLess("a:10", "a:9"))
    #expect(opIDLess("a:2", "b:1"))
}

@Test func registerHeadsSelectHighestCounterNotLexicographicMax() {
    let register = Register(versions: ["a:10": .name("ten"), "a:9": .name("nine")])
    #expect(register.heads == ["a:9", "a:10"])
    #expect(register.selected == .name("ten"))
}

// MARK: - 2. Concurrent creates of the same entityID merge

@Test func concurrentIdenticalCreatesMergeWithoutConflict() async throws {
    let a = try repo("a"), b = try repo("b")
    let opA = try await a.create(name: "Same", entityID: "f")
    let opB = try await b.create(name: "Same", entityID: "f")
    let state = try FaceReducer.reduce([opA, opB])
    #expect(state.unresolvedOperations == 0)
    let face = try #require(state.faces["f"])
    #expect(Set(face.createIDs) == Set([opA.id, opB.id]))
    #expect(face.conflict == false)
    #expect(face.fields["name"]?.heads.count == 2)
    #expect(face.fields["name"]?.selected == .name("Same"))
}

@Test func concurrentDifferentCreatesMergeButFieldConflicts() async throws {
    let a = try repo("a"), b = try repo("b")
    let opA = try await a.create(name: "Left", entityID: "f")
    let opB = try await b.create(name: "Right", entityID: "f")
    let state = try FaceReducer.reduce([opA, opB])
    #expect(state.unresolvedOperations == 0)
    let face = try #require(state.faces["f"])
    #expect(Set(face.createIDs) == Set([opA.id, opB.id]))
    #expect(face.conflict == true)
    #expect(face.fields["name"]?.heads.count == 2)
}

// MARK: - 3. Quarantine instead of throw

@Test func wrongCreateIdentityIsQuarantinedAndActorHistoryContinues() async throws {
    let createF = FaceOperation(libraryID: "lib", actorID: "a", counter: 1, context: VersionVector(),
                                entityID: "f", kind: "create",
                                writes: ["name": .init(parents: [], value: .name("F")),
                                        "artwork": .init(parents: [], value: .artwork(Artwork()))])
    let createG = FaceOperation(libraryID: "lib", actorID: "a", counter: 2, context: VersionVector(["a": 1]),
                                entityID: "g", kind: "create",
                                writes: ["name": .init(parents: [], value: .name("G")),
                                        "artwork": .init(parents: [], value: .artwork(Artwork()))])
    // References createG's id as the create identity for an update to "f" — wrong entity.
    let badUpdate = FaceOperation(libraryID: "lib", actorID: "a", counter: 3, context: VersionVector(["a": 2]),
                                  entityID: "f", kind: "update", createID: createG.id,
                                  writes: ["name": .init(parents: [createF.id], value: .name("Hijacked"))])
    // A later, well-formed op from the same actor must still apply.
    let goodUpdate = FaceOperation(libraryID: "lib", actorID: "a", counter: 4, context: VersionVector(["a": 3]),
                                   entityID: "g", kind: "update", createID: createG.id,
                                   writes: ["name": .init(parents: [createG.id], value: .name("G2"))])
    let state = try FaceReducer.reduce([createF, createG, badUpdate, goodUpdate])
    #expect(state.unresolvedOperations == 0)
    #expect(state.quarantined[badUpdate.id] != nil)
    #expect(state.faces["f"]?.fields["name"]?.selected == .name("F")) // hijack ignored
    #expect(state.faces["g"]?.fields["name"]?.selected == .name("G2")) // later valid op applied
    #expect(state.vector["a"] == 4)
}

@Test func childOfQuarantinedOpIsAlsoQuarantined() async throws {
    let createF = FaceOperation(libraryID: "lib", actorID: "a", counter: 1, context: VersionVector(),
                                entityID: "f", kind: "create",
                                writes: ["name": .init(parents: [], value: .name("F")),
                                        "artwork": .init(parents: [], value: .artwork(Artwork()))])
    let createG = FaceOperation(libraryID: "lib", actorID: "a", counter: 2, context: VersionVector(["a": 1]),
                                entityID: "g", kind: "create",
                                writes: ["name": .init(parents: [], value: .name("G")),
                                        "artwork": .init(parents: [], value: .artwork(Artwork()))])
    let badUpdate = FaceOperation(libraryID: "lib", actorID: "a", counter: 3, context: VersionVector(["a": 2]),
                                  entityID: "f", kind: "update", createID: createG.id,
                                  writes: ["name": .init(parents: [createF.id], value: .name("Hijacked"))])
    // Structurally valid (right create identity), but its field parent points at
    // the quarantined op — must be quarantined transitively, not applied.
    let child = FaceOperation(libraryID: "lib", actorID: "a", counter: 4, context: VersionVector(["a": 3]),
                              entityID: "f", kind: "update", createID: createF.id,
                              writes: ["name": .init(parents: [badUpdate.id], value: .name("Child"))])
    let state = try FaceReducer.reduce([createF, createG, badUpdate, child])
    #expect(state.unresolvedOperations == 0)
    #expect(state.quarantined[badUpdate.id] != nil)
    #expect(state.quarantined[child.id] != nil)
    #expect(state.faces["f"]?.fields["name"]?.selected == .name("F"))
}

@Test func reduceIsPureUnderReorderingWithAQuarantinedOpMixedIn() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f"); try await b.ingest([root])
    _ = try await a.update(base: a.checkout("f"), values: [.name("A2")])
    _ = try await b.update(base: b.checkout("f"), values: [.artwork(Artwork(frameHex: String(repeating: "01", count: 47)))])
    let createG = FaceOperation(libraryID: "lib", actorID: "a", counter: 3, context: VersionVector(["a": 2]),
                                entityID: "g", kind: "create",
                                writes: ["name": .init(parents: [], value: .name("G")),
                                        "artwork": .init(parents: [], value: .artwork(Artwork()))])
    let badUpdate = FaceOperation(libraryID: "lib", actorID: "a", counter: 4, context: VersionVector(["a": 3]),
                                  entityID: "f", kind: "update", createID: createG.id,
                                  writes: ["name": .init(parents: [root.id], value: .name("Hijacked"))])
    let all = try await a.operations() + b.operations() + [createG, badUpdate]
    let expected = try FaceReducer.reduce(all)
    #expect(expected.quarantined[badUpdate.id] != nil)
    for _ in 0..<100 { #expect(try FaceReducer.reduce((all + all).shuffled()) == expected) }
}

// MARK: - 4. Repository.local() never blocks on other actors' stuck inbox ops

@Test func localWriteSucceedsWhileAnOrphanChildSitsInTheInbox() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f")
    let orphan = try await a.update(base: a.checkout("f"), values: [.name("B")])
    try await b.ingest([orphan], checkpoint: Data([1]))
    #expect(try await b.state().unresolvedOperations == 1)
    let local = try await b.create(name: "Not blocked by an orphan")
    #expect(try await b.pending().contains(local))
    _ = root
}

@Test func abandonIsAFlagNotADeletionAndOnlyAppliesToUnresolvedOps() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f")
    let orphan = try await a.update(base: a.checkout("f"), values: [.name("B")])
    try await b.ingest([orphan], checkpoint: Data([1]))
    #expect(try await b.unresolved() == [orphan])
    // An applied op can never be abandoned: that would destroy history.
    let own = try await b.create(name: "Mine", entityID: "m")
    await #expect(throws: FaceSyncError.invalid("Only an unresolved operation can be abandoned")) {
        try await b.abandonUnresolved(own.id)
    }
    #expect(try await b.state().faces["m"]?.deleted == false)
    try await b.abandonUnresolved(orphan.id)
    // The row stays; it is still unresolved (its parent is missing) but flagged.
    #expect(try await b.operations().contains(orphan))
    #expect(try await b.state().unresolvedIDs == [orphan.id])
    // When the missing parent finally arrives, the abandoned op is consumed as a
    // quarantined no-op so the actor's later history is not wedged.
    let later = try await a.update(base: a.checkout("f"), values: [.name("C")])
    try await b.ingest([root, later])
    let state = try await b.state()
    #expect(state.unresolvedIDs.isEmpty)
    #expect(state.quarantined[orphan.id] != nil)
    #expect(state.vector["a"] == 3)
    // `later` cites the abandoned op as a parent, so it is quarantined transitively
    // and the entity keeps the create's value.
    #expect(state.quarantined[later.id] != nil)
    #expect(state.faces["f"]?.fields["name"]?.selected == .name("A"))
    // A cloud re-fetch of the abandoned op is a silent no-op.
    try await b.ingest([orphan])
    #expect(try await b.state().unresolvedIDs.isEmpty)
}

@Test func unabandonRestoresNormalReduction() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f")
    let orphan = try await a.update(base: a.checkout("f"), values: [.name("B")])
    try await b.ingest([orphan])
    try await b.abandonUnresolved(orphan.id)
    try await b.unabandon(orphan.id)
    try await b.ingest([root])
    let state = try await b.state()
    #expect(state.quarantined.isEmpty)
    #expect(state.faces["f"]?.fields["name"]?.selected == .name("B"))
}

@Test func reduceIsPureWithAnAbandonedSet() throws {
    let scope = "lib"
    let c1 = FaceOperation(libraryID: scope, actorID: "a", counter: 1, context: VersionVector(), entityID: "f", kind: "create",
                           writes: ["name": .init(parents: [], value: .name("A")), "artwork": .init(parents: [], value: .artwork(Artwork()))])
    let u2 = FaceOperation(libraryID: scope, actorID: "a", counter: 2, context: VersionVector(["a": 1]), entityID: "f", kind: "update",
                           createID: c1.id, writes: ["name": .init(parents: [c1.id], value: .name("B"))])
    let u3 = FaceOperation(libraryID: scope, actorID: "a", counter: 3, context: VersionVector(["a": 2]), entityID: "f", kind: "update",
                           createID: c1.id, writes: ["name": .init(parents: [u2.id], value: .name("C"))])
    let ops = [c1, u2, u3]
    let reference = try FaceReducer.reduce(ops, abandoned: [u2.id])
    for _ in 0..<20 {
        #expect(try FaceReducer.reduce(ops.shuffled(), abandoned: [u2.id]) == reference)
    }
    #expect(reference.quarantined.keys.sorted() == [u2.id, u3.id])
    #expect(reference.vector["a"] == 3)
}

// MARK: - 5. Transfer.swift slice-safe chunking

@Test func blobChunkPlanWorksOnANonZeroBasedDataSlice() throws {
    let full = Data((0..<20).map { UInt8($0) })
    let slice = full.dropFirst(6) // startIndex == 6, not 0
    let plan = try BlobChunkPlan(body: slice, negotiatedChunkMax: 5)
    let first = try plan.payload(offset: 0)
    #expect(Array(first.dropFirst(4)) == [6, 7, 8, 9, 10])
    let lastOffset = slice.count - 1 // last chunk starts one byte before the end
    let last = try plan.payload(offset: lastOffset)
    #expect(Array(last.dropFirst(4)) == [Array(slice)[lastOffset]])
}
