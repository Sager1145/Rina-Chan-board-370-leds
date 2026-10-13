import Foundation

public enum BoardCarrier: String, Codable, CaseIterable, Sendable { case ble, tcpLAN, tcpSoftAP }
public struct BoardFace: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var frameBytes: [Int]
    public var order: Int
    public var editable: Bool
    public var deletable: Bool
    public var locked: Bool
    public var call: [String: String]?
    public init(id: String, name: String, artwork: Artwork, order: Int, preset: Bool = false) {
        self.id = id; self.name = name; type = preset ? "default" : artwork.kind
        let hex = Array(artwork.frameHex.utf8)
        frameBytes = stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            guard offset + 1 < hex.count else { return nil }
            return Int(String(decoding: hex[offset...offset+1], as: UTF8.self), radix: 16)
        }
        self.order = order; editable = !preset; deletable = !preset; locked = preset
        call = artwork.call
    }
}
public struct BoardDocument: Codable, Equatable, Sendable {
    public var format = "rina_packed_faces_370_v2"
    public var version = 4
    public var category = "unified_saved_faces"
    public var startupDefaultId: String?
    public var faces: [BoardFace]
    public func validate() throws {
        guard faces.count <= 128 else { throw FaceSyncError.capacity }
        guard format == "rina_packed_faces_370_v2", version == 4, category == "unified_saved_faces",
              faces.contains(where: { $0.type == "default" }), Set(faces.map(\.id)).count == faces.count else {
            throw FaceSyncError.invalid("Invalid firmware document / missing protected preset")
        }
        if let startupDefaultId, !faces.contains(where: { $0.id == startupDefaultId }) {
            throw FaceSyncError.invalid("Dangling startup face")
        }
        for face in faces {
            try validateName(face.name)
            guard validID(face.id), face.frameBytes.count == 47,
                  face.frameBytes.allSatisfy({ (0...255).contains($0) }) else {
                throw FaceSyncError.invalid("Invalid board face")
            }
            let hex = face.frameBytes.map { String(format: "%02x", $0) }.joined()
            try Artwork(frameHex: hex, kind: face.type, call: face.call).validate(allowPreset: true)
            if face.type == "default", face.editable || face.deletable || !face.locked {
                throw FaceSyncError.invalid("Preset protection removed")
            }
        }
        guard try encoded(self).count <= 256 * 1024 else { throw FaceSyncError.capacity }
    }
}
public struct Projection: Codable, Equatable, Sendable {
    public var vector: VersionVector
    public var policyID: String
    public var document: BoardDocument
    public var settingsVersion: Int64
    public var digest: String { get throws { sha256(try encoded(document)) } }
    public init(vector: VersionVector, policyID: String, document: BoardDocument, settingsVersion: Int64 = 0) {
        self.vector = vector; self.policyID = policyID; self.document = document; self.settingsVersion = settingsVersion
    }
    private enum CodingKeys: String, CodingKey { case vector, policyID, document, settingsVersion }
    /// Older persisted BoardState JSON predates `settingsVersion`; decode it
    /// as 0 rather than failing to decode at all.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vector = try container.decode(VersionVector.self, forKey: .vector)
        policyID = try container.decode(String.self, forKey: .policyID)
        document = try container.decode(BoardDocument.self, forKey: .document)
        settingsVersion = try container.decodeIfPresent(Int64.self, forKey: .settingsVersion) ?? 0
    }
    /// Why a face didn't make it into a built document: a genuine multi-writer
    /// field conflict, or a create still missing required fields.
    public enum HoldReason: Equatable, Sendable { case conflict, incomplete }
    public struct ProjectionBuild: Equatable, Sendable {
        public var projection: Projection
        public var heldBack: [String: HoldReason]
    }
    /// Caller passes presets from the BOARD's confirmed baseline, never an
    /// arbitrary phone bundle. Different preset catalogs use distinct policies.
    /// `previous` is the board's currently deployed document (nil if none); it
    /// lets a conflicted/incomplete face keep showing its last-known-good state
    /// instead of taking the whole library offline.
    public static func build(state: LibraryState, presets: [BoardFace], policyID: String,
                             startupDefaultId: String? = nil,
                             confirmedInterleaving: [String]? = nil,
                             settingsVersion: Int64,
                             previous: BoardDocument? = nil) throws -> ProjectionBuild {
        guard !presets.isEmpty, Set(presets.map(\.id)).count == presets.count, presets.allSatisfy({ $0.type == "default" }) else {
            throw FaceSyncError.invalid("Preserve confirmed board presets")
        }
        var faces = presets
        var heldBack: [String: HoldReason] = [:]
        var usedIDs = Set(presets.map(\.id))
        for id in state.order {
            guard let face = state.faces[id], !face.deleted else { continue }
            var name: String?
            if case .name(let value)? = face.fields["name"]?.selected { name = value }
            var artwork: Artwork?
            if case .artwork(let value)? = face.fields["artwork"]?.selected { artwork = value }
            let incomplete = name == nil || artwork == nil
            var candidate: BoardFace
            if face.conflict || incomplete {
                // A previously deployed face may have been collision-renamed
                // (see below); look it up under either its raw id or the same
                // deterministic suffix, and only ever reuse a USER face — a
                // conflicted/incomplete entity whose id happens to collide
                // with a preset id must never adopt the preset as "previous".
                let suffix = (face.createID ?? id).replacingOccurrences(of: ":", with: "-")
                let suffixedID = "\(id)-\(suffix)"
                if let previous, let reused = previous.faces.first(where: {
                    $0.type != "default" && ($0.id == id || $0.id == suffixedID)
                }) {
                    candidate = reused
                } else {
                    heldBack[id] = face.conflict ? .conflict : .incomplete
                    continue
                }
            } else {
                candidate = BoardFace(id: id, name: name!, artwork: artwork!, order: faces.count + 1)
            }
            if usedIDs.contains(candidate.id) {
                let suffix = (face.createID ?? id).replacingOccurrences(of: ":", with: "-")
                candidate.id = "\(candidate.id)-\(suffix)"
            }
            usedIDs.insert(candidate.id)
            faces.append(candidate)
        }
        // Keep preset slots from the confirmed BOARD order. Fill the user slots
        // with the newly resolved user order, then append additions. Never reset
        // a preset/user interleaving just because sync ran. An explicit change
        // to preset slots belongs to a versioned board projection policy.
        if let confirmedInterleaving {
            guard Set(confirmedInterleaving).count == confirmedInterleaving.count else {
                throw FaceSyncError.invalid("Duplicate interleaving id")
            }
            let presetByID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
            let users = faces.filter { $0.type != "default" }
            var arranged: [BoardFace] = [], usedPresets = Set<String>(), nextUser = 0
            for id in confirmedInterleaving {
                if let preset = presetByID[id] {
                    arranged.append(preset); usedPresets.insert(id)
                } else if nextUser < users.count {
                    arranged.append(users[nextUser]); nextUser += 1
                }
            }
            arranged += presets.filter { !usedPresets.contains($0.id) }
            arranged += users.dropFirst(nextUser)
            faces = arranged
        }
        for i in faces.indices { faces[i].order = i + 1 }
        var resolvedStartup = startupDefaultId
        // A nil startupDefaultId means "no explicit request" and must stay
        // nil. Only a NON-nil id that names no face in the built document is
        // "dangling" and falls back to the previous board default (if still
        // present) or the first preset.
        if let requested = startupDefaultId, !faces.contains(where: { $0.id == requested }) {
            if let previousDefault = previous?.startupDefaultId, faces.contains(where: { $0.id == previousDefault }) {
                resolvedStartup = previousDefault
            } else {
                resolvedStartup = presets.first?.id
            }
        }
        let document = BoardDocument(startupDefaultId: resolvedStartup, faces: faces)
        try document.validate()
        let projection = Projection(vector: state.vector, policyID: policyID, document: document,
                                    settingsVersion: settingsVersion)
        return ProjectionBuild(projection: projection, heldBack: heldBack)
    }
    /// Convenience for callers/tests that don't need degraded-face bookkeeping.
    public static func buildProjection(state: LibraryState, presets: [BoardFace], policyID: String,
                                       startupDefaultId: String? = nil,
                                       confirmedInterleaving: [String]? = nil,
                                       settingsVersion: Int64,
                                       previous: BoardDocument? = nil) throws -> Projection {
        try build(state: state, presets: presets, policyID: policyID, startupDefaultId: startupDefaultId,
                 confirmedInterleaving: confirmedInterleaving, settingsVersion: settingsVersion,
                 previous: previous).projection
    }
}
public struct BoardState: Codable, Equatable, Sendable {
    public var boardID: String
    public var libraryID: String
    public var dataEpoch: String
    public var revision: Int64
    public var projection: Projection?
    public var legacyDirty: Bool
    public init(boardID: String, libraryID: String, dataEpoch: String = UUID().uuidString.lowercased()) {
        self.boardID = boardID; self.libraryID = libraryID; self.dataEpoch = dataEpoch
        revision = 0; projection = nil; legacyDirty = false
    }
}
public struct DeploymentRequest: Codable, Equatable, Sendable {
    public var transactionID: String
    public var boardID: String
    public var libraryID: String
    public var dataEpoch: String
    public var expectedRevision: Int64
    public var projection: Projection
    public init(board: BoardState, projection: Projection, transactionID: String = UUID().uuidString.lowercased()) {
        self.transactionID = transactionID; boardID = board.boardID; libraryID = board.libraryID
        dataEpoch = board.dataEpoch; expectedRevision = board.revision; self.projection = projection
    }
}
public struct BoardReceipt: Codable, Equatable, Sendable {
    public var transactionID: String
    public var boardID: String
    public var libraryID: String
    public var dataEpoch: String
    public var committedRevision: Int64
    public var currentRevision: Int64
    public var requestDigest: String
    public var projectionDigest: String
}

public enum BoardCommitGuard {
    public static func validate(_ request: DeploymentRequest, against state: BoardState) throws {
        guard request.boardID == state.boardID, request.dataEpoch == state.dataEpoch else { throw FaceSyncError.wrongBoard }
        guard request.libraryID == state.libraryID else { throw FaceSyncError.scopeMismatch }
        guard validID(request.transactionID), request.expectedRevision == state.revision,
              state.revision >= 0, state.revision < Int64.max else { throw FaceSyncError.staleBoard }
        guard !state.legacyDirty else { throw FaceSyncError.recoveryRequired("Read and reconcile unexpected legacy writes") }
        guard validID(request.projection.policyID) else { throw FaceSyncError.invalid("Invalid deployment policy") }
        try request.projection.document.validate(); try request.projection.vector.validated()
        if let current = state.projection {
            guard current.policyID == request.projection.policyID else { throw FaceSyncError.recoveryRequired("Projection policy changed") }
            guard request.projection.vector.covers(current.vector) else { throw FaceSyncError.versionRollback }
            if request.projection.vector == current.vector {
                // Projection-local settings (e.g. startupDefaultId, preset/user
                // interleaving) never move the vector, so an equal vector is not
                // automatically ambiguous: a strictly newer settingsVersion is a
                // legitimate settings-only deployment.
                if request.projection.settingsVersion > current.settingsVersion {
                    // allowed
                } else if request.projection.settingsVersion == current.settingsVersion {
                    if try request.projection.digest != current.digest { throw FaceSyncError.ambiguousVersion }
                } else {
                    throw FaceSyncError.versionRollback
                }
            } else if request.projection.settingsVersion < current.settingsVersion {
                throw FaceSyncError.versionRollback
            }
        }
        // Conservative actual encoding bound for this reference commit unit.
        // Firmware must measure its own final on-disk envelope, not just faces[].
        guard try encoded(request).count <= 256 * 1024 else { throw FaceSyncError.capacity }
    }
}

/// Host-only durable board model; SQLite here does NOT stand in for a verified
/// LittleFS implementation. Used to test identity/CAS/receipt/restart behavior.
public actor DurableBoardModel {
    private let db: SQLite
    public init(path: String, initial: BoardState) throws {
        db = try SQLite(path)
        try db.transaction {
            if let body = try db.metadata("board") {
                let old = try JSONDecoder().decode(BoardState.self, from: body)
                guard old.boardID == initial.boardID, old.libraryID == initial.libraryID else { throw FaceSyncError.wrongBoard }
            } else { try db.setMetadata("board", try encoded(initial)) }
        }
    }
    public func state() throws -> BoardState {
        guard let body = try db.metadata("board") else { throw FaceSyncError.recoveryRequired("Missing board state") }
        return try JSONDecoder().decode(BoardState.self, from: body)
    }
    public func receipt(_ transactionID: String) throws -> BoardReceipt? {
        guard let data = try db.metadata("receipt:\(transactionID)") else { return nil }
        var receipt = try JSONDecoder().decode(BoardReceipt.self, from: data)
        receipt.currentRevision = try state().revision
        return receipt
    }
    public func commit(_ request: DeploymentRequest, failBeforeCommit: Bool = false) throws -> BoardReceipt {
        try db.transaction {
            var current = try state()
            guard request.boardID == current.boardID, request.dataEpoch == current.dataEpoch,
                  request.libraryID == current.libraryID else { throw FaceSyncError.wrongBoard }
            let requestDigest = sha256(try encoded(request))
            if let old = try receipt(request.transactionID) {
                guard old.requestDigest == requestDigest else { throw FaceSyncError.immutableCollision }
                return old
            }
            try BoardCommitGuard.validate(request, against: current)
            current.revision += 1; current.projection = request.projection
            let receipt = BoardReceipt(transactionID: request.transactionID, boardID: current.boardID,
                                       libraryID: current.libraryID, dataEpoch: current.dataEpoch,
                                       committedRevision: current.revision, currentRevision: current.revision,
                                       requestDigest: requestDigest, projectionDigest: try request.projection.digest)
            try db.setMetadata("board", try encoded(current))
            try db.setMetadata("receipt:\(request.transactionID)", try encoded(receipt))
            if failBeforeCommit { throw FaceSyncError.sqlite("Injected pre-commit failure") }
            return receipt
        }
    }
    public func markLegacyDirty() throws {
        try db.transaction {
            var current = try state()
            guard current.revision < Int64.max else { throw FaceSyncError.capacity }
            current.legacyDirty = true; current.revision += 1
            try db.setMetadata("board", try encoded(current))
        }
    }
}

public struct BoardHello: Sendable {
    public var state: BoardState
    public var linkID: UUID
    public var supportsDurableSync: Bool
    public init(state: BoardState, linkID: UUID, supportsDurableSync: Bool) {
        self.state = state; self.linkID = linkID; self.supportsDurableSync = supportsDurableSync
    }
}
public protocol BoardSyncChannel: Sendable {
    var carrier: BoardCarrier { get }
    func hello() async throws -> BoardHello
    func currentLinkID() async -> UUID
    func receipt(transactionID: String) async throws -> BoardReceipt?
    /// The real adapter implements this with existing BLOB_START/CHUNK/END,
    /// negotiated chunkMax and a final persistent commit receipt.
    func commit(_ request: DeploymentRequest) async throws -> BoardReceipt
}
public enum DeploymentStatus: Equatable, Sendable { case confirmed, committedButSuperseded }

/// Construct exactly ONE instance per physical board in BoardSessionStore.
/// A route change must keep this coordinator and the persisted job.
public actor BoardSyncCoordinator {
    private let boardID: String
    private let repository: FaceRepository
    private var busy = false
    public init(boardID: String, repository: FaceRepository) { self.boardID = boardID; self.repository = repository }
    public func deploy(_ job: DeploymentRequest, over channel: any BoardSyncChannel) async throws -> DeploymentStatus {
        guard !busy else { throw FaceSyncError.busy }
        busy = true; defer { busy = false }
        guard boardID == job.boardID else { throw FaceSyncError.wrongBoard }
        if let pending = try await repository.deploymentJob(boardID: boardID), pending != job {
            throw FaceSyncError.recoveryRequired("Reconcile the previous durable job before replacing it")
        }
        try await repository.saveDeploymentJob(job)
        let hello = try await channel.hello()
        guard hello.state.boardID == job.boardID, hello.state.libraryID == job.libraryID,
              hello.state.dataEpoch == job.dataEpoch else { throw FaceSyncError.wrongBoard }
        guard hello.supportsDurableSync else { throw FaceSyncError.recoveryRequired("Old firmware: explicit manual transfer only") }
        let receipt: BoardReceipt
        if let stored = try await channel.receipt(transactionID: job.transactionID) { receipt = stored }
        else {
            try BoardCommitGuard.validate(job, against: hello.state)
            receipt = try await channel.commit(job)
        }
        guard await channel.currentLinkID() == hello.linkID else { throw FaceSyncError.staleSession }
        guard receipt.boardID == job.boardID, receipt.libraryID == job.libraryID,
              receipt.dataEpoch == job.dataEpoch, receipt.transactionID == job.transactionID,
              receipt.requestDigest == sha256(try encoded(job)),
              receipt.projectionDigest == (try job.projection.digest),
              receipt.committedRevision == job.expectedRevision + 1,
              receipt.currentRevision >= receipt.committedRevision else { throw FaceSyncError.invalid("Mismatched receipt") }
        try await repository.finishDeploymentJob(boardID: boardID, transactionID: job.transactionID)
        return receipt.currentRevision == receipt.committedRevision ? .confirmed : .committedButSuperseded
    }
}
