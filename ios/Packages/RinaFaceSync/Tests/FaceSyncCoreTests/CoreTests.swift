import Foundation
import Testing
@testable import FaceSyncCore

private let scope = StoreScope(container: "iCloud.test.rina", environment: "Development", account: "user1",
                               database: "private", zoneOwner: "owner", zoneName: "Faces", libraryID: "lib")
private func repo(_ actor: String = UUID().uuidString.lowercased(), path: String = ":memory:") throws -> FaceRepository {
    try FaceRepository(path: path, scope: scope, writerID: actor)
}
private func preset(_ id: String = "preset") -> BoardFace {
    BoardFace(id: id, name: "Preset", artwork: Artwork(), order: 1, preset: true)
}
private func projection(_ vector: VersionVector = VersionVector(["a":1]), name: String = "Preset") -> Projection {
    var p = preset(); p.name = name
    return Projection(vector: vector, policyID: "board-policy-v1", document: BoardDocument(startupDefaultId: "preset", faces: [p]))
}
private func error(_ expected: FaceSyncError? = nil, _ action: () async throws -> Void) async {
    do { try await action(); Issue.record("Expected an error") }
    catch { if let expected { #expect((error as? FaceSyncError) == expected) } }
}
private func path() -> String { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path }

@Test func sha256KnownVectors() {
    #expect(sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(sha256(Data(repeating: 97, count: 1000)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
}
@Test func versionVectorsComparePrefixesNotSums() {
    #expect(!VersionVector(["a":2]).covers(VersionVector(["b":1])))
    #expect(!VersionVector(["a":1,"b":1]).covers(VersionVector(["a":2])))
    #expect(VersionVector(["a":2,"b":1]).covers(VersionVector(["a":2])))
}
@Test func transactionPersistsContentAndOutboxAcrossReopen() async throws {
    let file = path(); defer { try? FileManager.default.removeItem(atPath: file) }
    let a = try repo("a", path: file); let op = try await a.create(name: "Saved", entityID: "face")
    let reopened = try repo("a", path: file)
    #expect(try await reopened.pending() == [op])
    #expect(try await reopened.checkout("face").fields["name"]?.selected == .name("Saved"))
}
@Test func accountNamespaceCannotBeReused() async throws {
    let file = path(); defer { try? FileManager.default.removeItem(atPath: file) }
    _ = try repo("a", path: file)
    var other = scope; other.account = "user2"
    await error(.scopeMismatch) { _ = try FaceRepository(path: file, scope: other, writerID: "a") }
}
@Test func sharedZoneOwnerIsPartOfNamespace() async throws {
    let file = path(); defer { try? FileManager.default.removeItem(atPath: file) }
    _ = try repo("a", path: file)
    var other = scope; other.zoneOwner = "different-owner"
    await error(.scopeMismatch) { _ = try FaceRepository(path: file, scope: other, writerID: "a") }
}
@Test func corruptDatabaseIsNotReset() async throws {
    let file = path(); let bytes = Data("not a sqlite database; recover me".utf8)
    defer { try? FileManager.default.removeItem(atPath: file) }
    try bytes.write(to: URL(fileURLWithPath: file))
    await error { _ = try repo("a", path: file) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == bytes)
}
@Test func inboundAndCheckpointRollbackTogether() async throws {
    let a = try repo("a"), b = try repo("b")
    let op = try await a.create(name: "A")
    try await b.persistCloudState(Data("old".utf8))
    await error { try await b.ingest([op], checkpoint: Data("new".utf8), failBeforeCommit: true) }
    #expect(try await b.operations().isEmpty)
    #expect(try await b.cloudState() == Data("old".utf8))
}
@Test func uploadAcknowledgmentDoesNotMoveFetchCheckpoint() async throws {
    let a = try repo("a"); let op = try await a.create(name: "A")
    try await a.persistCloudState(Data("fetch-only".utf8))
    try await a.acknowledge([op])
    #expect(try await a.pending().isEmpty)
    #expect(try await a.cloudState() == Data("fetch-only".utf8))
}
@Test func peerEchoDoesNotAcknowledgeCloudUpload() async throws {
    let a = try repo("a"); let op = try await a.create(name: "A")
    try await a.ingest([op], viaPeer: true)
    #expect(try await a.pending() == [op])
    try await a.ingest([op])
    #expect(try await a.pending().isEmpty)
}
@Test func tokenResetPreservesContentTombstoneAndOutbox() async throws {
    let a = try repo("a"); _ = try await a.create(name: "A", entityID: "f")
    _ = try await a.delete(base: a.checkout("f"))
    let before = try await a.operations(); try await a.persistCloudState(Data([1,2]))
    try await a.resetCloudState()
    #expect(try await a.cloudState() == nil)
    #expect(try await a.operations() == before)
    #expect(try await a.pending().count == 2)
    #expect(try await a.state().faces["f"]?.deleted == true)
}
@Test func childOnEarlierCloudPageWaitsForParent() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f")
    let change = try await a.update(base: a.checkout("f"), values: [.name("B")])
    try await b.ingest([change], checkpoint: Data([1]))
    #expect(try await b.state().unresolvedOperations == 1)
    #expect(try await b.state().vector == VersionVector())
    // A stuck inbox op belonging to another actor must never block this
    // actor's own local writes (see FaceRepository.unresolved()).
    let sideCreate = try await b.create(name: "No longer blocked by an orphan inbox op")
    #expect(try await b.pending().contains(sideCreate))
    try await b.ingest([root], checkpoint: Data([2]))
    #expect(try await b.state().unresolvedOperations == 0)
    #expect(try await b.checkout("f").fields["name"]?.selected == .name("B"))
}
@Test func sequenceGapDoesNotBecomeMaximumSeenPrefix() async throws {
    let a = try repo("a"), b = try repo("b")
    let first = try await a.create(name: "1", entityID: "one")
    _ = try await a.create(name: "2", entityID: "two")
    let third = try await a.create(name: "3", entityID: "three")
    try await b.ingest([third,first])
    #expect(try await b.state().vector == VersionVector(["a":1]))
    #expect(try await b.state().unresolvedOperations == 1)
}
@Test func immutableCollisionRollsBackBatch() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f")
    try await b.ingest([root])
    var bad = root; bad.writes["name"] = .init(parents: [], value: .name("Tampered"))
    let second = try await a.create(name: "B", entityID: "g")
    await error(.immutableCollision) { try await b.ingest([second,bad]) }
    #expect(try await b.operations() == [root])
}
@Test func independentFieldsMerge() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f"); try await b.ingest([root])
    let name = try await a.update(base: a.checkout("f"), values: [.name("New")])
    let frame = Artwork(frameHex: "01" + String(repeating: "00", count: 46))
    let art = try await b.update(base: b.checkout("f"), values: [.artwork(frame)])
    try await a.ingest([art]); try await b.ingest([name])
    #expect(try await a.state() == b.state())
    #expect(try await a.state().conflict == false)
    #expect(try await a.checkout("f").fields["artwork"]?.selected == .artwork(frame))
}
@Test func frozenEditorBaselineDoesNotClaimToHaveSeenRemoteEdit() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f"); try await b.ingest([root])
    let editorBaseline = try await a.checkout("f")
    let remote = try await b.update(base: b.checkout("f"), values: [.name("B")])
    try await a.ingest([remote])
    let local = try await a.update(base: editorBaseline, values: [.name("C")])
    #expect(local.context["b"] == 1) // delivery knowledge is newer than the edit baseline
    #expect(local.writes["name"]?.parents == [root.id])
    #expect(try await a.checkout("f").fields["name"]?.conflict == true)
    #expect(try await a.checkout("f").fields["name"]?.heads.count == 2)
}
@Test func conflictResolutionConsumesAllObservedHeads() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f"); try await b.ingest([root])
    _ = try await a.update(base: a.checkout("f"), values: [.name("left")])
    let r = try await b.update(base: b.checkout("f"), values: [.name("right")]); try await a.ingest([r])
    let merged = try await a.update(base: a.checkout("f"), values: [.name("chosen")])
    #expect(merged.writes["name"]?.parents.count == 2)
    #expect(try await a.state().conflict == false)
}
@Test func identicalConcurrentValuesNeedNoUserConflict() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f"); try await b.ingest([root])
    _ = try await a.update(base: a.checkout("f"), values: [.name("same")])
    let r = try await b.update(base: b.checkout("f"), values: [.name("same")]); try await a.ingest([r])
    #expect(try await a.state().conflict == false)
    #expect(try await a.checkout("f").fields["name"]?.heads.count == 2)
}
@Test func tombstoneDominatesOfflineEditAndRestoreUsesNewIdentity() async throws {
    let a = try repo("a"), b = try repo("b")
    let root = try await a.create(name: "A", entityID: "f"); try await b.ingest([root])
    let deletion = try await a.delete(base: a.checkout("f"))
    let edit = try await b.update(base: b.checkout("f"), values: [.name("Offline")])
    try await a.ingest([edit]); try await b.ingest([deletion])
    #expect(try await a.state().faces["f"]?.deleted == true)
    #expect(try await b.state().order.isEmpty == true)
    _ = try await a.create(name: "Recovered", entityID: "restored", restoredFrom: "f")
    #expect(try await a.state().faces["f"]?.deleted == true)
    #expect(try await a.state().order == ["restored"])
}
@Test func fullOrderNeverDropsConcurrentAdditions() async throws {
    let a = try repo("a"), b = try repo("b")
    let first = try await a.create(name: "A", entityID: "f"); try await b.ingest([first])
    _ = try await a.reorder(["f"], base: nil)
    let extra = try await b.create(name: "B", entityID: "g"); try await a.ingest([extra])
    #expect(try await a.state().order == ["f","g"])
}
@Test func artworkPartsAreValidatedAsOneUnit() async {
    await error { try Artwork(kind: "parts", call: ["leye":"eye"]).validate() }
    await error { try Artwork(frameHex: String(repeating:"00",count:46)).validate() }
    await error { try Artwork(call: ["leye":"not-parts"]).validate() }
}
@Test func nameLimitUsesUTF8Bytes() async throws {
    let a = try repo("a")
    await error { _ = try await a.create(name: String(repeating:"汉",count:22)) }
    #expect(try await a.pending().isEmpty)
    _ = try await a.create(name: String(repeating:"汉",count:21))
}
@Test func randomOrderingAndDuplicatesConverge() async throws {
    let a = try repo("a"), b = try repo("b")
    let r = try await a.create(name:"A",entityID:"f"); try await b.ingest([r])
    _ = try await a.update(base:a.checkout("f"),values:[.name("A2")])
    _ = try await b.update(base:b.checkout("f"),values:[.artwork(Artwork(frameHex:String(repeating:"01",count:47)))])
    let all = try await a.operations() + b.operations()
    let expected = try FaceReducer.reduce(all)
    for _ in 0..<100 { #expect(try FaceReducer.reduce((all+all).shuffled()) == expected) }
}
@Test func boardLimitIncludesPresets() async throws {
    var faces = [preset()]
    for i in 0..<127 { faces.append(BoardFace(id:"u\(i)",name:"User",artwork:Artwork(),order:i+2)) }
    var document = BoardDocument(faces:faces); try document.validate()
    document.faces.append(BoardFace(id:"overflow",name:"Overflow",artwork:Artwork(),order:129))
    await error(.capacity) { try document.validate() }
}
@Test func boardRequiresProtectedPresetAndValidFrame() async {
    await error { try BoardDocument(faces:[]).validate() }
    var unprotected = preset(); unprotected.editable = true
    await error { try BoardDocument(faces:[unprotected]).validate() }
    var invalid = preset(); invalid.frameBytes = [999]
    await error { try BoardDocument(faces:[invalid]).validate() }
}
@Test func presetUserInterleavingSurvivesProjection() async throws {
    let a = try repo("a"); _ = try await a.create(name:"One",entityID:"u1"); _ = try await a.create(name:"Two",entityID:"u2")
    _ = try await a.reorder(["u2","u1"],base:nil)
    let p = try await Projection.buildProjection(state:a.state(),presets:[preset()],policyID:"p",
                                       confirmedInterleaving:["u1","preset","u2"],settingsVersion:0)
    #expect(p.document.faces.map(\.id) == ["u2","preset","u1"])
}
@Test func unresolvedCloudDependenciesAreExcludedNotBlocking() async throws {
    let a = try repo("a"), b = try repo("b")
    _ = try await a.create(name:"A",entityID:"f")
    let child = try await a.update(base:a.checkout("f"),values:[.name("B")]); try await b.ingest([child])
    // The update's parent create was never ingested, so entity "f" is not yet
    // causally closed for b: it simply doesn't appear in b's order/faces, and
    // the projection still succeeds with just the presets.
    let p = try await Projection.buildProjection(state:b.state(),presets:[preset()],policyID:"p",settingsVersion:0)
    #expect(p.document.faces.map(\.id) == ["preset"])
}
@Test func boardCASRejectsTwoPhonesUsingSameRevision() async throws {
    let board = try DurableBoardModel(path:":memory:",initial:.init(boardID:"board",libraryID:"lib"))
    let baseline = try await board.state()
    _ = try await board.commit(.init(board:baseline,projection:projection()))
    await error(.staleBoard) { _ = try await board.commit(.init(board:baseline,projection:projection())) }
}
@Test func rereadingRevisionDoesNotAuthorizeCausalRollback() async throws {
    let board = try DurableBoardModel(path:":memory:",initial:.init(boardID:"board",libraryID:"lib"))
    _ = try await board.commit(.init(board:board.state(),projection:projection(VersionVector(["a":2]))))
    await error(.versionRollback) {
        _ = try await board.commit(.init(board:board.state(),projection:projection(VersionVector(["a":1,"b":1]))))
    }
}
@Test func equalVectorCannotRenderDifferentContents() async throws {
    let board = try DurableBoardModel(path:":memory:",initial:.init(boardID:"board",libraryID:"lib"))
    _ = try await board.commit(.init(board:board.state(),projection:projection()))
    await error(.ambiguousVersion) {
        _ = try await board.commit(.init(board:board.state(),projection:projection(name:"Unexpected")))
    }
}
@Test func boardAtomicCommitIncludesReceipt() async throws {
    let board = try DurableBoardModel(path:":memory:",initial:.init(boardID:"board",libraryID:"lib"))
    let job = try await DeploymentRequest(board:board.state(),projection:projection())
    await error { _ = try await board.commit(job,failBeforeCommit:true) }
    #expect(try await board.state().revision == 0)
    #expect(try await board.receipt(job.transactionID) == nil)
}
@Test func boardReceiptSurvivesRestart() async throws {
    let file = path(); defer { try? FileManager.default.removeItem(atPath:file) }
    let initial = BoardState(boardID:"board",libraryID:"lib")
    let a = try DurableBoardModel(path:file,initial:initial)
    let job = DeploymentRequest(board:initial,projection:projection()); let receipt = try await a.commit(job)
    let b = try DurableBoardModel(path:file,initial:.init(boardID:"board",libraryID:"lib"))
    #expect(try await b.state().dataEpoch == initial.dataEpoch)
    #expect(try await b.commit(job) == receipt)
    #expect(try await b.state().revision == 1)
}
@Test func reusedTransactionWithDifferentBodyIsRejected() async throws {
    let board = try DurableBoardModel(path:":memory:",initial:.init(boardID:"board",libraryID:"lib"))
    var job = try await DeploymentRequest(board:board.state(),projection:projection())
    _ = try await board.commit(job); job.projection = projection(name:"Changed")
    await error(.immutableCollision) { _ = try await board.commit(job) }
}
@Test func legacyMutationMakesAutomaticDeploymentUnsafe() async throws {
    let board = try DurableBoardModel(path:":memory:",initial:.init(boardID:"board",libraryID:"lib"))
    try await board.markLegacyDirty()
    await error { _ = try await board.commit(.init(board:board.state(),projection:projection())) }
    #expect(try await board.state().revision == 1)
}
@Test func pendingBoardJobCannotBeOverwritten() async throws {
    let a = try repo("a"); let state = BoardState(boardID:"board",libraryID:"lib")
    let first = DeploymentRequest(board:state,projection:projection())
    try await a.saveDeploymentJob(first)
    await error { try await a.saveDeploymentJob(.init(board:state,projection:projection())) }
    #expect(try await a.deploymentJob(boardID:"board") == first)
}

private actor Channel: BoardSyncChannel {
    nonisolated let carrier: BoardCarrier
    let board: DurableBoardModel
    var link = UUID(), dropReply = false, changeLinkOnCommit = false, supported = true
    init(_ carrier:BoardCarrier,_ board:DurableBoardModel) { self.carrier=carrier; self.board=board }
    func configure(drop:Bool=false,change:Bool=false,supported:Bool=true) { dropReply=drop; changeLinkOnCommit=change; self.supported=supported }
    func hello() async throws -> BoardHello { try await BoardHello(state:board.state(),linkID:link,supportsDurableSync:supported) }
    func currentLinkID() -> UUID { link }
    func receipt(transactionID:String) async throws -> BoardReceipt? { try await board.receipt(transactionID) }
    func commit(_ request:DeploymentRequest) async throws -> BoardReceipt {
        let receipt = try await board.commit(request)
        if changeLinkOnCommit { link=UUID() }
        if dropReply { throw URLError(.networkConnectionLost) }
        return receipt
    }
}
@Test func lostCommitReplyResumesAcrossAllNineRoutePairs() async throws {
    for from in BoardCarrier.allCases {
        for to in BoardCarrier.allCases {
            let a = try repo("a"); let initial = BoardState(boardID:"board",libraryID:"lib")
            let board = try DurableBoardModel(path:":memory:",initial:initial)
            let coordinator = BoardSyncCoordinator(boardID:"board",repository:a)
            let job = DeploymentRequest(board:initial,projection:projection())
            let first = Channel(from,board); await first.configure(drop:true)
            await error { _ = try await coordinator.deploy(job,over:first) }
            #expect(try await a.deploymentJob(boardID:"board") == job)
            let status = try await coordinator.deploy(job,over:Channel(to,board))
            #expect(status == .confirmed)
            #expect(try await board.state().revision == 1)
            #expect(try await a.deploymentJob(boardID:"board") == nil)
        }
    }
}
@Test func sameIPDifferentBoardMustNotReceiveJob() async throws {
    let a = try repo("a"); let wanted = BoardState(boardID:"wanted",libraryID:"lib")
    let wrong = try DurableBoardModel(path:":memory:",initial:.init(boardID:"other",libraryID:"lib"))
    let job = DeploymentRequest(board:wanted,projection:projection())
    await error(.wrongBoard) { _ = try await BoardSyncCoordinator(boardID:"wanted",repository:a).deploy(job,over:Channel(.tcpSoftAP,wrong)) }
    #expect(try await wrong.state().revision == 0)
}
@Test func staleLinkCallbackDoesNotClearPendingJob() async throws {
    let a = try repo("a"); let initial = BoardState(boardID:"board",libraryID:"lib")
    let board = try DurableBoardModel(path:":memory:",initial:initial), channel = Channel(.ble,board)
    await channel.configure(change:true)
    let job = DeploymentRequest(board:initial,projection:projection())
    await error(.staleSession) { _ = try await BoardSyncCoordinator(boardID:"board",repository:a).deploy(job,over:channel) }
    #expect(try await a.deploymentJob(boardID:"board") == job)
}
@Test func oldFirmwareIsNotSilentlyAutoOverwritten() async throws {
    let a = try repo("a"); let initial = BoardState(boardID:"board",libraryID:"lib")
    let board = try DurableBoardModel(path:":memory:",initial:initial), channel = Channel(.tcpLAN,board)
    await channel.configure(supported:false)
    await error { _ = try await BoardSyncCoordinator(boardID:"board",repository:a).deploy(.init(board:initial,projection:projection()),over:channel) }
    #expect(try await board.state().revision == 0)
}
@Test func oldReceiptIsNotReportedAsCurrentSync() async throws {
    let a = try repo("a"); let initial = BoardState(boardID:"board",libraryID:"lib")
    let board = try DurableBoardModel(path:":memory:",initial:initial)
    let old = DeploymentRequest(board:initial,projection:projection())
    _ = try await board.commit(old)
    _ = try await board.commit(.init(board:board.state(),projection:projection(VersionVector(["a":2]))))
    let status = try await BoardSyncCoordinator(boardID:"board",repository:a).deploy(old,over:Channel(.tcpLAN,board))
    #expect(status == .committedButSuperseded)
}

@Test func chunkBudgetIncludesOffsetAndNegotiatedMaximum() throws {
    let bytes = Data(repeating:0xA5,count:8191)
    let plan = try BlobChunkPlan(body:bytes,negotiatedChunkMax:4092)
    #expect(try plan.payload(offset:0).count==4096)
    #expect(try plan.payload(offset:4092).prefix(4)==Data([252,15,0,0]))
    #expect(try plan.payload(offset:8184).count==11)
    try plan.validateAcknowledgment(sentOffset:4092,nextOffset:8184)
}
@Test func badChunkAckCannotSkipBytes() async throws {
    let plan = try BlobChunkPlan(body:Data(repeating:0,count:100),negotiatedChunkMax:47)
    await error { try plan.validateAcknowledgment(sentOffset:0,nextOffset:94) }
    await error { _ = try plan.payload(offset:-1) }
    await error(.capacity) { _ = try BlobChunkPlan(body:Data([1]),negotiatedChunkMax:4096) }
}
@Test func peerArchivePreservesIDsButNeverClearsCloudOutbox() async throws {
    let a=try repo("a"), b=try repo("b")
    let op=try await a.create(name:"Shared",entityID:"f")
    let archive=try PeerArchive(libraryID:"lib",operations:[op])
    let decoded=try PeerArchive.decode(encoded(archive),expectedLibraryID:"lib")
    try await b.ingest(decoded.operations,viaPeer:true)
    #expect(try await b.pending()==[op])
    #expect(try await b.checkout("f").createID==op.id)
    await error(.scopeMismatch) { _ = try PeerArchive.decode(encoded(archive),expectedLibraryID:"other") }
}
