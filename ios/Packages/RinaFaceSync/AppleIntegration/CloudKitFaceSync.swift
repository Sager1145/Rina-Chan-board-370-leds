// Integration source for the iOS target. Requires iOS 17+, real CloudKit
// entitlements and an Apple SDK build. Compile with CloudKitFetchedCheckpoint.swift.
// NOT included in the Linux-tested target.
// API shape checked against Apple's sample-cloudkit-sync-engine (63d9d16).
#if canImport(CloudKit)
import CloudKit
import Foundation
import FaceSyncCore

@available(iOS 17.0, macOS 14.0, *)
public actor CloudKitFaceSync: CKSyncEngineDelegate {
    /// `fatal` means the engine has been cancelled and this instance can never
    /// sync again; a caller must throw it away and open a new, correctly
    /// scoped driver. `recoverable` means the engine keeps running: automatic
    /// sync, retries and further delegate events continue as normal, and the
    /// halt is just the last-known reason. Call `resume()` to clear it.
    public enum SyncHalt: Equatable, Sendable {
        case fatal(String)
        case recoverable(String)
    }
    public private(set) var halt: SyncHalt?
    /// Source-compatible accessor for the latest halt reason, fatal or not.
    public var stoppedReason: String? {
        switch halt {
        case .some(.fatal(let reason)), .some(.recoverable(let reason)): return reason
        case .none: return nil
        }
    }
    private var isFatal: Bool { if case .fatal = halt { return true }; return false }
    /// Keeps every failed fetched batch (including decode/validation) ahead
    /// of the durable checkpoint until the replacement engine replays it.
    private let fetchedCheckpoint: CloudKitFetchedCheckpoint
    /// Per-record permanent upload failures (schema/permission/validation),
    /// keyed by operation id. The op stays pending in the repository; this is
    /// just a surface for diagnostics/UI, not a queue.
    public private(set) var blockedUploads: [String: String] = [:]

    private let repository: FaceRepository
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private var engine: CKSyncEngine?
    private var eventTail: Task<Void, Never>?
    private static let recordType = "FaceOperationV2"

    /// One namespace-scoped instance for this library. A production manager
    /// coalesces several libraries in the same database if many are used.
    public init(repository: FaceRepository) throws {
        self.repository = repository
        let scope = repository.scope
        container = CKContainer(identifier: scope.container)
        switch scope.database {
        case "private": database = container.privateCloudDatabase
        case "shared": database = container.sharedCloudDatabase
        default: throw FaceSyncError.invalid("Public database is not a personal face library")
        }
        zoneID = CKRecordZone.ID(zoneName: scope.zoneName, ownerName: scope.zoneOwner)
        fetchedCheckpoint = CloudKitFetchedCheckpoint(repository: repository, zoneID: zoneID)
    }

    /// The host must read the signed-in account identity BEFORE opening a
    /// repository. The environment comes from the signing configuration,
    /// never from user input. Account switches open another local namespace.
    private func verifyAccount() async throws {
        guard try await container.accountStatus() == .available else {
            throw FaceSyncError.recoveryRequired("iCloud account is unavailable; keep local data")
        }
        let user = try await container.userRecordID()
        guard user.recordName == repository.scope.account else { throw FaceSyncError.scopeMismatch }
    }

    /// Build a fresh engine from whatever checkpoint is currently persisted.
    /// Shared by `start()` (first bootstrap) and `resume()` (rebuild after a
    /// recoverable halt) so both construct the engine identically.
    private func makeEngine() async throws -> CKSyncEngine {
        let data = try await repository.cloudState()
        let serialization = try data.map {
            try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        var configuration = CKSyncEngine.Configuration(database: database,
                                                       stateSerialization: serialization,
                                                       delegate: self)
        configuration.automaticallySync = true
        configuration.subscriptionID = "facesync-v2-" + sha256(try encoded(repository.scope))
        return CKSyncEngine(configuration)
    }

    /// Bootstrap a private custom zone separately, once, after explicit new-
    /// library creation. Existing/deleted/revoked zones are NOT recreated here.
    /// If an engine is already running with no halt, this throws `.busy`
    /// rather than opening a second engine. If the running engine is under a
    /// recoverable halt, this behaves like `resume()`. Refuses after a fatal
    /// halt, which requires a new correctly-scoped driver instance instead.
    public func start() async throws {
        guard !isFatal else {
            throw FaceSyncError.recoveryRequired("Create a new correctly-scoped sync driver")
        }
        if engine != nil {
            guard halt != nil else { throw FaceSyncError.busy }
            try await resume()
            return
        }
        try await verifyAccount()
        let metadata = try await database.record(for: CKRecord.ID(recordName: "library", zoneID: zoneID))
        guard metadata.recordType == "FaceLibraryMetadataV2",
              metadata["libraryID"] as? String == repository.scope.libraryID else {
            throw FaceSyncError.scopeMismatch
        }
        engine = try await makeEngine()
        halt = nil
        await fetchedCheckpoint.beginReplay()
        try await enqueuePending()
    }

    /// Call AFTER the SQLite transaction commits, not before. Rebuilt on every
    /// start, so a crash between local commit and this call cannot lose an op.
    public func enqueuePending() async throws {
        guard !isFatal, let engine else { return }
        let pending = try await repository.pending()
        guard !isFatal else { return }
        engine.state.add(pendingRecordZoneChanges: pending.map {
            .saveRecord(CKRecord.ID(recordName: $0.id, zoneID: zoneID))
        })
    }

    /// Foreground/manual reconciliation. Automatic sync remains engine-managed;
    /// do not put an unbounded timer/retry loop around this method.
    public func synchronizeNow() async throws {
        try await verifyAccount()
        guard !isFatal, let engine else {
            throw FaceSyncError.recoveryRequired(stoppedReason ?? "Sync not started")
        }
        try await enqueuePending()
        try await engine.fetchChanges()
        try await engine.sendChanges()
        try await engine.fetchChanges()
    }

    /// Recover from a recoverable halt. The running engine's in-memory zone
    /// token may already have advanced past records whose ingest failed (that
    /// is exactly why `fetchedCheckpoint` withheld the checkpoint), so the
    /// engine itself is not reusable: it is cancelled and rebuilt from the
    /// last persisted `repository.cloudState()`, same as `start()`. Clear the
    /// old halt before replay, so a replay failure can retain its new halt. Throws
    /// if the current halt is fatal (or absent) rather than recoverable.
    public func resume() async throws {
        guard case .recoverable = halt, let current = engine else {
            throw FaceSyncError.recoveryRequired(stoppedReason ?? "No recoverable halt to resume")
        }
        try await verifyAccount()
        await current.cancelOperations()
        engine = nil
        let rebuilt = try await makeEngine()
        engine = rebuilt
        await fetchedCheckpoint.beginReplay()
        halt = nil
        do {
            try await enqueuePending()
            try await rebuilt.fetchChanges()
            // A decode/ingest failure surfaced by a delegate event may not
            // make fetchChanges throw. Keep its new halt/checkpoint block.
        } catch {
            applyFailure(error, engine: rebuilt)
            throw error
        }
    }

    /// CKSyncEngine delegate is async; explicitly serialize local event
    /// persistence across actor reentrancy. A fatal failure latches a halt
    /// before any later engine checkpoint is saved; a recoverable one does not
    /// stop later events from being processed.
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let previous = eventTail
        let task = Task {
            await previous?.value
            await self.process(event, engine: syncEngine)
        }
        eventTail = task
        await task.value
    }

    private func process(_ event: CKSyncEngine.Event, engine: CKSyncEngine) async {
        guard !isFatal else { return }
        do {
            switch event {
            case .accountChange(let event):
                switch event.changeType {
                case .signIn:
                    try await verifyAccount()
                    try await enqueuePending()
                case .switchAccounts, .signOut:
                    haltFatal("Account changed; freeze this namespace and reopen the correct account", engine: engine)
                @unknown default:
                    haltFatal("Unknown account transition", engine: engine)
                }
            case .fetchedRecordZoneChanges(let event):
                // Decode, validate and ingest form one failed-batch boundary.
                // Missing parents remain durable inbox entries; physical
                // history deletion still requires explicit fatal recovery.
                try await fetchedCheckpoint.ingest(records: event.modifications.map(\.record),
                                                   deletedRecordIDs: event.deletions.map(\.recordID))
            case .stateUpdate(let event):
                // Serialized after earlier record events. The gate preserves
                // the older token whenever any batch failed before commit.
                try await fetchedCheckpoint.persist(try encoded(event.stateSerialization))
            case .fetchedDatabaseChanges(let event):
                if event.deletions.contains(where: { $0.zoneID == zoneID }) {
                    throw FaceSyncError.recoveryRequired("Library zone deleted or share revoked; explicit recovery required")
                }
            case .sentRecordZoneChanges(let event):
                let saved = try event.savedRecords.filter {
                    $0.recordID.zoneID == zoneID && $0.recordType == Self.recordType
                }.map(decode)
                // Acknowledge one at a time: `repository.acknowledge` throws
                // `immutableCollision` both when the row is missing (e.g. the
                // op was abandoned meanwhile) and when the body mismatches. A
                // missing row is skipped here; a mismatch stays fatal below.
                let known = Dictionary(uniqueKeysWithValues: try await repository.operations().map { ($0.id, $0) })
                for op in saved {
                    guard let local = known[op.id] else { continue } // abandoned meanwhile; skip
                    guard local == op else { throw FaceSyncError.immutableCollision }
                    try await repository.acknowledge([op])
                    blockedUploads.removeValue(forKey: op.id)
                }
                for failure in event.failedRecordSaves where failure.record.recordID.zoneID == zoneID {
                    switch failure.error.code {
                    case .serverRecordChanged:
                        guard let server = failure.error.serverRecord else { throw failure.error }
                        let intended = try decode(failure.record), confirmed = try decode(server)
                        guard intended == confirmed else { throw FaceSyncError.immutableCollision }
                        // Lost upload ACK: same ID and payload already exist.
                        try await repository.acknowledge([confirmed])
                        blockedUploads.removeValue(forKey: confirmed.id)
                        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
                    case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                         .requestRateLimited, .operationCancelled:
                        break // CKSyncEngine retry/backoff; durable outbox remains.
                    case .notAuthenticated:
                        // Re-adding here would just spin against the same
                        // unauthenticated session. Halt recoverably; the
                        // `.accountChange(.signIn)` event path or an explicit
                        // `resume()` re-enqueues the outbox once signed in.
                        halt = .recoverable("iCloud account not available; will retry after sign-in/unlock")
                    case .limitExceeded:
                        // This record itself is over CloudKit's per-record/
                        // request size limit; re-adding it would fail the same
                        // way forever. (Batch splitting for otherwise-oversize
                        // requests is the sync engine's own job, not ours.)
                        halt = .recoverable("A record exceeded CloudKit's size limit; upload paused")
                    case .accountTemporarilyUnavailable, .batchRequestFailed,
                         .partialFailure, .internalError:
                        // Not covered by the engine's own backoff; re-queue
                        // explicitly so the durable outbox is retried instead
                        // of silently dropped.
                        engine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    case .quotaExceeded:
                        // Do not re-add and do not delete anything locally;
                        // uploads simply pause until the account has room.
                        halt = .recoverable("iCloud storage full; local library kept, uploads paused")
                    case .permissionFailure, .invalidArguments, .serverRejectedRequest,
                         .constraintViolation, .unknownItem:
                        // Permanent, per-record. Leave the op pending in the
                        // repository (never acknowledged) and keep the engine
                        // running; surface it for diagnostics/UI instead.
                        blockedUploads[failure.record.recordID.recordName] = String(describing: failure.error)
                    default:
                        // Includes unknown schema and missing zone. Do not
                        // silently recreate a revoked share.
                        throw failure.error
                    }
                }
            case .sentDatabaseChanges:
                break // zone creation/sharing is explicit, outside this engine
            case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
                 .didFetchChanges, .willSendChanges, .didSendChanges:
                break
            @unknown default:
                break
            }
        } catch { applyFailure(error, engine: engine) }
    }

    /// Fatal: this instance is done, the engine is cancelled, a new
    /// correctly-scoped driver is required. Only for errors that mean this
    /// namespace/account/zone can never be resolved by retrying: account
    /// switch/sign-out, scope mismatch, immutable collision, or recovery-
    /// required conditions (deleted history/zone, revoked share), plus the
    /// CKError codes below that mean the container/entitlement/zone itself is
    /// wrong rather than temporarily unavailable.
    private func classifyFatal(_ error: Error) -> String? {
        switch error {
        case FaceSyncError.scopeMismatch:
            return "Library scope mismatch; create a new correctly-scoped sync driver"
        case FaceSyncError.immutableCollision:
            return "Immutable operation collision; create a new correctly-scoped sync driver"
        case FaceSyncError.recoveryRequired(let reason):
            return reason
        default:
            break
        }
        guard let ck = error as? CKError else { return nil }
        switch ck.code {
        case .badContainer, .missingEntitlement, .incompatibleVersion,
             .managedAccountRestricted, .userDeletedZone:
            return String(describing: ck)
        case .zoneNotFound:
            return zoneNotFoundNamesOurZone(ck) ? String(describing: ck) : nil
        default:
            return nil
        }
    }

    /// A batched zoneNotFound can partial-fail on a zone other than ours; a
    /// single-operation zoneNotFound is inherently scoped to the zone we
    /// asked for, since every request this actor issues targets `zoneID`.
    private func zoneNotFoundNamesOurZone(_ error: CKError) -> Bool {
        guard let partial = error.partialErrorsByItemID, !partial.isEmpty else { return true }
        return partial.keys.contains { ($0 as? CKRecordZone.ID) == zoneID }
    }

    /// Every other error, including any other CKError and SQLite/decode
    /// failures: recoverable, the engine keeps running and automatic sync
    /// continues on its own.
    private func applyFailure(_ error: Error, engine: CKSyncEngine) {
        if let reason = classifyFatal(error) {
            haltFatal(reason, engine: engine)
        } else {
            halt = .recoverable(String(describing: error))
        }
    }

    private func haltFatal(_ reason: String, engine: CKSyncEngine) {
        halt = .fatal(reason)
        // Don't await cancellation inside a delegate event that the operation
        // being canceled might itself be waiting to finish.
        Task { await engine.cancelOperations() }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !isFatal else { return nil }
        do {
            let operations = try await repository.pending()
            guard !isFatal else { return nil }
            let snapshot = Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0) })
            let changes = operations.map {
                CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0.id, zoneID: zoneID))
            }.filter { context.options.scope.contains($0) }
            guard !changes.isEmpty else { return nil }
            // Encode before entering the async provider: encoding failure must
            // not silently remove an unsent operation from engine state.
            let bodies = try snapshot.mapValues { try encoded($0) }
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
                guard let body = bodies[id.recordName] else { return nil }
                let record = CKRecord(recordType: Self.recordType, recordID: id)
                record["payload"] = body as CKRecordValue
                record["schema"] = 2 as CKRecordValue
                return record
            }
        } catch {
            // Account is verified at start() and on .accountChange, so no
            // verifyAccount() round-trip here. Never cancel the engine from
            // this callback: a transient pending()/encode failure must not
            // permanently stop uploads.
            halt = .recoverable(String(describing: error))
            return nil
        }
    }

    private func decode(_ record: CKRecord) throws -> FaceOperation {
        try CloudKitFetchedCheckpoint.decode(record, scope: repository.scope, zoneID: zoneID)
    }
}
#endif
