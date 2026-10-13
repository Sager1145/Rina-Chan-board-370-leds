import Foundation

/// Chunk bytes exclude the 6-byte RinaLink header. BLOB_CHUNK payload includes
/// a 4-byte little-endian offset; BLE ATT slicing happens BELOW this layer.
public struct BlobChunkPlan: Sendable {
    public let body: Data
    public let chunkBytes: Int
    public init(body: Data, negotiatedChunkMax: Int) throws {
        guard !body.isEmpty, body.count <= 256 * 1024,
              negotiatedChunkMax > 0, negotiatedChunkMax <= 4092 else {
            throw FaceSyncError.capacity
        }
        self.body = body; self.chunkBytes = negotiatedChunkMax
    }
    public func payload(offset: Int) throws -> Data {
        guard offset >= 0, offset < body.count else { throw FaceSyncError.invalid("Invalid blob offset") }
        let n = min(chunkBytes, body.count - offset)
        let o = UInt32(offset)
        var data = Data([UInt8(truncatingIfNeeded:o),UInt8(truncatingIfNeeded:o>>8),
                         UInt8(truncatingIfNeeded:o>>16),UInt8(truncatingIfNeeded:o>>24)])
        let lower = body.index(body.startIndex, offsetBy: offset)
        let upper = body.index(lower, offsetBy: n)
        data.append(body.subdata(in: lower..<upper))
        return data
    }
    public func validateAcknowledgment(sentOffset: Int, nextOffset: Int) throws {
        guard sentOffset >= 0, sentOffset < body.count,
              nextOffset == sentOffset + min(chunkBytes, body.count - sentOffset) else {
            throw FaceSyncError.invalid("Unexpected chunk ACK; do not skip unsent bytes")
        }
    }
}

/// Transfer this file with native ShareLink/AirDrop or a user-authorized nearby
/// channel. This is a checksummed archive, NOT an authentication mechanism.
/// Importing into an unrelated account/library must instead create explicit
/// copies; the host decides membership, never an untrusted archive flag.
public struct PeerArchive: Codable, Sendable {
    public let format: String
    public let libraryID: String
    public let operations: [FaceOperation]
    public let digest: String
    public init(libraryID: String, operations: [FaceOperation]) throws {
        _ = try FaceReducer.reduce(operations)
        guard operations.allSatisfy({ $0.libraryID == libraryID }) else { throw FaceSyncError.scopeMismatch }
        format = "rina_faces_operations_v2"; self.libraryID=libraryID; self.operations=operations
        digest=sha256(try encoded(operations))
    }
    public static func decode(_ data: Data, expectedLibraryID: String) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw FaceSyncError.capacity }
        let archive=try JSONDecoder().decode(Self.self,from:data)
        guard archive.format=="rina_faces_operations_v2", archive.libraryID==expectedLibraryID,
              archive.operations.allSatisfy({$0.libraryID==expectedLibraryID}) else { throw FaceSyncError.scopeMismatch }
        guard archive.digest == sha256(try encoded(archive.operations)) else { throw FaceSyncError.invalid("Archive checksum mismatch") }
        _ = try FaceReducer.reduce(archive.operations)
        return archive
    }
}
