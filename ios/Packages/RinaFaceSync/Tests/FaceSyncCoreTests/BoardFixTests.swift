import Foundation
import Testing
@testable import FaceSyncCore

private func preset(_ id: String = "preset") -> BoardFace {
    BoardFace(id: id, name: "Preset", artwork: Artwork(), order: 1, preset: true)
}
private func liveFace(id: String, createID: String, name: String, artwork: Artwork = Artwork()) -> FaceState {
    FaceState(id: id, createIDs: [createID], deleted: false,
             fields: ["name": Register(versions: [createID: .name(name)]),
                      "artwork": Register(versions: [createID: .artwork(artwork)])])
}
private func libraryState(_ faces: [FaceState], order: [String]) -> LibraryState {
    LibraryState(faces: Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) }), order: order,
                orderRegister: nil, vector: VersionVector(), unresolvedOperations: 0,
                unresolvedIDs: [], quarantined: [:])
}

@Test func conflictedFaceReusesPreviousBoardVersion() throws {
    var conflicted = liveFace(id: "u1", createID: "a:1", name: "New Name")
    conflicted.fields["name"] = Register(versions: ["a:1": .name("New Name"), "b:1": .name("Other Name")])
    #expect(conflicted.conflict)
    let state = libraryState([conflicted], order: ["u1"])
    var previousFace = BoardFace(id: "u1", name: "Old Confirmed Name", artwork: Artwork(), order: 2)
    let previous = BoardDocument(startupDefaultId: "preset", faces: [preset(), previousFace])
    let result = try Projection.build(state: state, presets: [preset()], policyID: "p",
                                      startupDefaultId: "preset", settingsVersion: 0, previous: previous)
    #expect(result.heldBack.isEmpty)
    #expect(result.projection.document.faces.first(where: { $0.id == "u1" })?.name == "Old Confirmed Name")
    // Reused verbatim, only the order field is allowed to be renumbered.
    previousFace.order = result.projection.document.faces.first(where: { $0.id == "u1" })!.order
    #expect(result.projection.document.faces.first(where: { $0.id == "u1" }) == previousFace)
}

@Test func conflictedFaceWithNoPreviousIsHeldBackButOthersDeploy() throws {
    var conflicted = liveFace(id: "u1", createID: "a:1", name: "New Name")
    conflicted.fields["name"] = Register(versions: ["a:1": .name("New Name"), "b:1": .name("Other Name")])
    let fine = liveFace(id: "u2", createID: "a:2", name: "Fine")
    let state = libraryState([conflicted, fine], order: ["u1", "u2"])
    let result = try Projection.build(state: state, presets: [preset()], policyID: "p", settingsVersion: 0)
    #expect(result.heldBack == ["u1": .conflict])
    let ids = result.projection.document.faces.map(\.id)
    #expect(!ids.contains("u1"))
    #expect(ids.contains("u2"))
    #expect(ids.contains("preset"))
}

@Test func incompleteFaceHeldBackWhenNoPrevious() throws {
    let incomplete = FaceState(id: "u1", createIDs: ["a:1"], deleted: false,
                               fields: ["name": Register(versions: ["a:1": .name("Only Name")])])
    #expect(!incomplete.conflict)
    let state = libraryState([incomplete], order: ["u1"])
    let result = try Projection.build(state: state, presets: [preset()], policyID: "p", settingsVersion: 0)
    #expect(result.heldBack == ["u1": .incomplete])
    #expect(!result.projection.document.faces.map(\.id).contains("u1"))
}

@Test func incompleteFaceReusesPreviousWhenAvailable() throws {
    let incomplete = FaceState(id: "u1", createIDs: ["a:1"], deleted: false,
                               fields: ["name": Register(versions: ["a:1": .name("Only Name")])])
    let state = libraryState([incomplete], order: ["u1"])
    let previousFace = BoardFace(id: "u1", name: "Last Known Good", artwork: Artwork(), order: 2)
    let previous = BoardDocument(startupDefaultId: "preset", faces: [preset(), previousFace])
    let result = try Projection.build(state: state, presets: [preset()], policyID: "p", settingsVersion: 0, previous: previous)
    #expect(result.heldBack.isEmpty)
    #expect(result.projection.document.faces.first(where: { $0.id == "u1" })?.name == "Last Known Good")
}

@Test func danglingStartupFallsBackToPreviousDefault() throws {
    let live = liveFace(id: "u1", createID: "a:1", name: "Live")
    let state = libraryState([live], order: ["u1"])
    let previous = BoardDocument(startupDefaultId: "u1", faces: [preset(), BoardFace(id: "u1", name: "Old", artwork: Artwork(), order: 2)])
    // Ask for a startup id that no longer exists in the new document; the
    // previous board's default ("u1") is still present, so it wins.
    let result = try Projection.build(state: state, presets: [preset()], policyID: "p",
                                      startupDefaultId: "gone", settingsVersion: 0, previous: previous)
    #expect(result.projection.document.startupDefaultId == "u1")
}

@Test func danglingStartupWithNoPreviousFallsBackToFirstPreset() throws {
    let state = libraryState([], order: [])
    let result = try Projection.build(state: state, presets: [preset("presetA")], policyID: "p",
                                      startupDefaultId: "gone", settingsVersion: 0)
    #expect(result.projection.document.startupDefaultId == "presetA")
}

@Test func nilStartupDefaultStaysNil() throws {
    let state = libraryState([], order: [])
    let result = try Projection.build(state: state, presets: [preset("presetA")], policyID: "p", settingsVersion: 0)
    #expect(result.projection.document.startupDefaultId == nil)
}

@Test func presetIdCollisionRenamesLaterFace() throws {
    // Defensive: a user face whose entity id happens to equal a preset id must
    // never silently overwrite/hide the protected preset.
    let colliding = liveFace(id: "preset", createID: "actorA:1", name: "Impostor")
    let state = libraryState([colliding], order: ["preset"])
    let result = try Projection.build(state: state, presets: [preset()], policyID: "p", settingsVersion: 0)
    let ids = result.projection.document.faces.map(\.id)
    #expect(ids.contains("preset"))
    #expect(ids.contains("preset-actorA-1"))
    let real = result.projection.document.faces.first(where: { $0.id == "preset" })
    #expect(real?.locked == true && real?.editable == false)
    let renamed = result.projection.document.faces.first(where: { $0.id == "preset-actorA-1" })
    #expect(renamed?.name == "Impostor")
    try result.projection.document.validate()
}

@Test func conflictedFaceCollidingWithPresetIdDoesNotAdoptThePresetAsPrevious() throws {
    // A conflicted user entity whose id equals a preset id must never treat
    // the preset itself as its "previous" reused candidate.
    var colliding = liveFace(id: "preset", createID: "actorA:1", name: "New Name")
    colliding.fields["name"] = Register(versions: ["actorA:1": .name("New Name"), "b:1": .name("Other Name")])
    #expect(colliding.conflict)
    let state = libraryState([colliding], order: ["preset"])
    let previous = BoardDocument(startupDefaultId: "preset", faces: [preset()])
    let result = try Projection.build(state: state, presets: [preset()], policyID: "p", settingsVersion: 0, previous: previous)
    #expect(result.heldBack["preset"] == .conflict)
    #expect(result.projection.document.faces.map(\.id) == ["preset"])
}

@Test func conflictedFaceReusesPreviouslySuffixedDeployment() throws {
    // The face was previously collision-renamed on deploy; a later reuse
    // lookup must find it under that same deterministic suffix.
    var colliding = liveFace(id: "preset", createID: "actorA:1", name: "New Name")
    colliding.fields["name"] = Register(versions: ["actorA:1": .name("New Name"), "b:1": .name("Other Name")])
    let state = libraryState([colliding], order: ["preset"])
    let previouslyDeployed = BoardFace(id: "preset-actorA-1", name: "Last Known Good", artwork: Artwork(), order: 2)
    let previous = BoardDocument(startupDefaultId: "preset", faces: [preset(), previouslyDeployed])
    let result = try Projection.build(state: state, presets: [preset()], policyID: "p", settingsVersion: 0, previous: previous)
    #expect(result.heldBack.isEmpty)
    #expect(result.projection.document.faces.contains(where: { $0.id == "preset-actorA-1" && $0.name == "Last Known Good" }))
}

@Test func projectionDecodesMissingSettingsVersionAsZero() throws {
    let json = """
    {"vector":{"counters":{}},"policyID":"p","document":{"format":"rina_packed_faces_370_v2","version":4,"category":"unified_saved_faces","faces":[]}}
    """
    let projection = try JSONDecoder().decode(Projection.self, from: Data(json.utf8))
    #expect(projection.settingsVersion == 0)
}

@Test func settingsOnlyRedeployIsAllowedWhenVectorUnchanged() async throws {
    let vector = VersionVector(["a": 1])
    let boardID = "board", libraryID = "lib"
    var initial = BoardState(boardID: boardID, libraryID: libraryID)
    let firstDoc = BoardDocument(startupDefaultId: "preset", faces: [preset(), preset("alternate")])
    let firstProjection = Projection(vector: vector, policyID: "p", document: firstDoc, settingsVersion: 0)
    initial.projection = firstProjection
    initial.revision = 1

    var settingsDoc = firstDoc
    settingsDoc.startupDefaultId = "alternate"
    let request = DeploymentRequest(board: initial,
                                    projection: Projection(vector: vector, policyID: "p", document: settingsDoc, settingsVersion: 1))
    try BoardCommitGuard.validate(request, against: initial)
    let board = try DurableBoardModel(path: ":memory:", initial: initial)
    let receipt = try await board.commit(request)
    let committed = try await board.state()
    #expect(receipt.committedRevision == 2)
    #expect(committed.projection?.vector == vector)
    #expect(committed.projection?.settingsVersion == 1)
    #expect(committed.projection?.document.startupDefaultId == "alternate")
    #expect(committed.projection?.document.faces == firstDoc.faces)
}

@Test func sameVectorSameSettingsVersionDifferentDigestIsAmbiguous() throws {
    let vector = VersionVector(["a": 1])
    var initial = BoardState(boardID: "board", libraryID: "lib")
    let firstDoc = BoardDocument(startupDefaultId: "preset", faces: [preset()])
    initial.projection = Projection(vector: vector, policyID: "p", document: firstDoc, settingsVersion: 3)
    initial.revision = 1

    var other = firstDoc
    other.faces[0].name = "Different"
    let request = DeploymentRequest(board: initial,
                                    projection: Projection(vector: vector, policyID: "p", document: other, settingsVersion: 3))
    do { try BoardCommitGuard.validate(request, against: initial); Issue.record("Expected ambiguousVersion") }
    catch { #expect((error as? FaceSyncError) == .ambiguousVersion) }
}

@Test func sameVectorOlderSettingsVersionIsRollback() throws {
    let vector = VersionVector(["a": 1])
    var initial = BoardState(boardID: "board", libraryID: "lib")
    let firstDoc = BoardDocument(startupDefaultId: "preset", faces: [preset()])
    initial.projection = Projection(vector: vector, policyID: "p", document: firstDoc, settingsVersion: 3)
    initial.revision = 1

    let request = DeploymentRequest(board: initial,
                                    projection: Projection(vector: vector, policyID: "p", document: firstDoc, settingsVersion: 1))
    do { try BoardCommitGuard.validate(request, against: initial); Issue.record("Expected versionRollback") }
    catch { #expect((error as? FaceSyncError) == .versionRollback) }
}

@Test func newerVectorRequiresSettingsVersionToHaveCaughtUp() throws {
    var initial = BoardState(boardID: "board", libraryID: "lib")
    let firstDoc = BoardDocument(startupDefaultId: "preset", faces: [preset()])
    initial.projection = Projection(vector: VersionVector(["a": 1]), policyID: "p", document: firstDoc, settingsVersion: 5)
    initial.revision = 1

    var newerDoc = firstDoc
    newerDoc.faces.append(BoardFace(id: "u1", name: "New", artwork: Artwork(), order: 2))
    let staleSettings = DeploymentRequest(board: initial,
                                          projection: Projection(vector: VersionVector(["a": 2]), policyID: "p",
                                                                 document: newerDoc, settingsVersion: 4))
    do { try BoardCommitGuard.validate(staleSettings, against: initial); Issue.record("Expected versionRollback") }
    catch { #expect((error as? FaceSyncError) == .versionRollback) }

    let caughtUp = DeploymentRequest(board: initial,
                                     projection: Projection(vector: VersionVector(["a": 2]), policyID: "p",
                                                            document: newerDoc, settingsVersion: 5))
    try BoardCommitGuard.validate(caughtUp, against: initial)
}
