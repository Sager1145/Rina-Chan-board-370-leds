import CloudKit
import Foundation
import FaceSyncCore

/// Compiled alongside the actual Apple integration by the adjacent runner;
/// no CloudKit container, account, network or engine is needed for this seam.
@main
struct AuditBehaviorCloudKitCheckpointTests {
    static func main() async throws {
        let scope = StoreScope(container: "iCloud.test.rina", environment: "Development", account: "test",
                               database: "private", zoneOwner: "owner", zoneName: "Faces", libraryID: "library")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let source = try FaceRepository(path: ":memory:", scope: scope, writerID: "source")
        let operation = try await source.create(name: "Saved", entityID: "face")
        let repository = try FaceRepository(path: path, scope: scope, writerID: "receiver")
        let zone = CKRecordZone.ID(zoneName: scope.zoneName, ownerName: scope.zoneOwner)
        let good = CKRecord(recordType: "FaceOperationV2", recordID: CKRecord.ID(recordName: operation.id, zoneID: zone))
        good["payload"] = try encoded(operation)
        let malformed = CKRecord(recordType: "FaceOperationV2", recordID: CKRecord.ID(recordName: "source:2", zoneID: zone))
        malformed["payload"] = Data("malformed".utf8)
        let checkpoint = CloudKitFetchedCheckpoint(repository: repository, zoneID: zone)
        try await repository.persistCloudState(Data("durable-token".utf8))
        do {
            try await checkpoint.ingest(records: [good, malformed], deletedRecordIDs: [])
            fatalError("Malformed batch unexpectedly committed")
        } catch is DecodingError { }
        try await checkpoint.persist(Data("advanced-token".utf8))
        let reopened = try FaceRepository(path: path, scope: scope, writerID: "receiver")
        guard try await reopened.cloudState() == Data("durable-token".utf8) else {
            fatalError("Decode failure advanced the durable token; restart would skip the batch")
        }
        guard try await reopened.operations().isEmpty else { fatalError("Part of failed batch committed") }
        // Later successful batches cannot unblock the missed batch by themselves.
        try await checkpoint.ingest(records: [good], deletedRecordIDs: [])
        try await checkpoint.persist(Data("still-advanced-token".utf8))
        guard try await reopened.cloudState() == Data("durable-token".utf8) else { fatalError("Later success unblocked a failed batch") }
        // Decodable but invalid operations must close the same checkpoint gate.
        var invalidOperation = operation
        invalidOperation.kind = "invalid"
        let invalid = CKRecord(recordType: "FaceOperationV2", recordID: CKRecord.ID(recordName: operation.id, zoneID: zone))
        invalid["payload"] = try encoded(invalidOperation)
        await checkpoint.beginReplay()
        do {
            try await checkpoint.ingest(records: [good, invalid], deletedRecordIDs: [])
            fatalError("Invalid decoded operation unexpectedly committed")
        } catch FaceSyncError.invalid { }
        try await checkpoint.persist(Data("invalid-operation-token".utf8))
        guard try await reopened.cloudState() == Data("durable-token".utf8) else { fatalError("Validation failure advanced checkpoint") }
        await checkpoint.beginReplay()
        try await checkpoint.ingest(records: [good], deletedRecordIDs: [])
        try await checkpoint.persist(Data("replayed-token".utf8))
        guard try await reopened.operations() == [operation],
              try await reopened.cloudState() == Data("replayed-token".utf8) else { fatalError("Replay did not commit operation and token") }
        print("CloudKit fetched-batch decode/validation/checkpoint/restart/replay regression passed")
    }
}
