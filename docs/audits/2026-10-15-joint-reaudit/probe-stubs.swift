import Foundation
import Observation
import RinaCore

struct BoardFaceSaveSource: Codable, Equatable {
 let boardID: String?; let generation: UUID?
 var expectedBootId: String? = nil; var expectedGen: Int? = nil
}
@MainActor final class BoardConnection {
 enum State { case connected, disconnected }
 var connectionState: State = .connected
 let boardKey: String? = "physical-A"
 let boardIdentity: String? = "physical-A"
 let connectionGeneration = UUID()
 let carrierGeneration = UUID()
 let supportsPartsReferences = false
 let supportsConditionalFaceWrites = true
 let bootId: String? = "boot-A"
 let currentFacesGeneration: Int? = 1
}
@MainActor final class BoardSession {
 let name = "A"; let connection = BoardConnection()
}
@MainActor final class BoardSessionStore { var sessions: [BoardSession] = [] }
@MainActor final class ControlViewModel {
 static func hasPendingSave(in storage: DraftStorage) async throws -> Bool { false }
}
@MainActor final class FaceLibraryModel {
 enum Outcome { case saved(id: String?), pending(id: String), failed }
 var errorMessage: String?
 var faceDocument = FaceDocument()
 func canonicalPayload(_ input: FaceUpsertPayload, supportsPartsReferences: Bool) -> FaceUpsertPayload { input }
 func reload(connection: BoardConnection) async -> Bool { true }
 func matchesSavedPayload(_ payload: FaceUpsertPayload, expectedOrder: Int? = nil) -> Bool { false }
 func face(id: String, in location: Location) -> SavedFace? {
  SavedFace(id: id, name: "foreign change", type: .custom, frameBytes: Array(repeating: 0, count: 47), order: 1)
 }
 enum Location { case board }
 func save(_ payload: FaceUpsertPayload, source: BoardFaceSaveSource, createOnly: Bool, connection: BoardConnection) async -> Outcome { .failed }
}
