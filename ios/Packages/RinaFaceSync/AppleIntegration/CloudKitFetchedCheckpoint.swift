#if canImport(CloudKit)
import CloudKit
import Foundation
import FaceSyncCore

/// Owns fetched-batch durability and the token gate together. A failed batch
/// keeps checkpoints blocked until the engine replays from durable state;
/// later successful batches alone cannot make the missed history durable.
@available(iOS 17.0, macOS 14.0, *)
actor CloudKitFetchedCheckpoint {
    private let repository: FaceRepository
    private let zoneID: CKRecordZone.ID
    private var blocked = false

    init(repository: FaceRepository, zoneID: CKRecordZone.ID) {
        self.repository = repository
        self.zoneID = zoneID
    }

    func ingest(records: [CKRecord], deletedRecordIDs: [CKRecord.ID]) async throws {
        do {
            var operations: [FaceOperation] = []
            for record in records where record.recordID.zoneID == zoneID {
                if record.recordType == "FaceLibraryMetadataV2" {
                    guard record["libraryID"] as? String == repository.scope.libraryID else {
                        throw FaceSyncError.scopeMismatch
                    }
                    continue
                }
                guard record.recordType == "FaceOperationV2" else { continue }
                operations.append(try Self.decode(record, scope: repository.scope, zoneID: zoneID))
            }
            if deletedRecordIDs.contains(where: {
                $0.zoneID == zoneID && ($0.recordName.contains(":") || $0.recordName == "library")
            }) {
                throw FaceSyncError.recoveryRequired("Operation history deleted; do not re-upload or erase local data")
            }
            try await repository.ingest(operations)
        } catch {
            blocked = true
            throw error
        }
    }

    func persist(_ serialization: Data) async throws {
        guard !blocked else { return }
        try await repository.persistCloudState(serialization)
    }

    /// Called only after the former engine is cancelled and replaced with an
    /// engine built from the last durable token. Replay failures reclose it.
    func beginReplay() {
        blocked = false
    }

    nonisolated static func decode(_ record: CKRecord, scope: StoreScope, zoneID: CKRecordZone.ID) throws -> FaceOperation {
        guard record.recordType == "FaceOperationV2", record.recordID.zoneID == zoneID,
              let body = record["payload"] as? Data, body.count <= 65536 else {
            throw FaceSyncError.invalid("Unexpected cloud record")
        }
        let op = try JSONDecoder().decode(FaceOperation.self, from: body)
        try op.validate()
        guard op.id == record.recordID.recordName, op.libraryID == scope.libraryID else {
            throw FaceSyncError.scopeMismatch
        }
        return op
    }
}
#endif
