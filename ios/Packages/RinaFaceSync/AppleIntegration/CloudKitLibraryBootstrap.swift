// Apple SDK integration source; NOT compiled by the Linux verification target.
#if canImport(CloudKit)
import CloudKit
import Foundation

@available(iOS 17.0, macOS 14.0, *)
public enum CloudKitLibraryBootstrap {
    /// Explicit "create library", not an error fallback. Use one deterministic
    /// default zone name on all devices of the same account (e.g. RinaFacesV2).
    /// Custom libraries use their own stable libraryID and zone name.
    public static func createPrivateZone(container: CKContainer, zoneName: String) async throws -> CKRecordZone {
        guard try await container.accountStatus() == .available else { throw CKError(.notAuthenticated) }
        return try await container.privateCloudDatabase.save(CKRecordZone(zoneName: zoneName))
    }
    /// Run only during explicit library bootstrap. Fixed record name + server
    /// conflict detection prevents two first-launch phones inventing two
    /// different library IDs in the same zone. Never call as a repair fallback
    /// for a deleted/revoked, previously known library.
    public static func createOrReadLibraryID(container: CKContainer, zoneID: CKRecordZone.ID) async throws -> String {
        let database = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: "library", zoneID: zoneID)
        func value(_ record: CKRecord) throws -> String {
            guard record.recordType == "FaceLibraryMetadataV2",
                  let library = record["libraryID"] as? String,
                  UUID(uuidString: library) != nil else { throw CKError(.serverRejectedRequest) }
            return library
        }
        do { return try value(await database.record(for: id)) }
        catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: "FaceLibraryMetadataV2", recordID: id)
            record["libraryID"] = UUID().uuidString.lowercased() as CKRecordValue
            do { return try value(await database.save(record)) }
            catch let conflict as CKError where conflict.code == .serverRecordChanged {
                guard let server = conflict.serverRecord else { throw conflict }
                return try value(server)
            }
        }
    }
    /// Whole-zone sharing includes future operation records. The owner stays
    /// in privateCloudDatabase; an invitee uses metadata.rootRecordID/zoneID
    /// from accepted share discovery, preserving the actual zone owner name.
    /// The UI must query/reuse an existing share before calling this function.
    public static func createZoneShare(container: CKContainer, zoneID: CKRecordZone.ID,
                                       title: String) async throws -> CKShare {
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        share.publicPermission = .none
        guard let saved = try await container.privateCloudDatabase.save(share) as? CKShare else {
            throw CKError(.internalError)
        }
        return saved
    }
}
#endif
