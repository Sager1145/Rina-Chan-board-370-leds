import Foundation

/// One saved face entry. `frameBytes` is the 47-byte packed frame as a plain
/// int array (0...255 each), matching `saved_faces.json`'s on-disk shape.
public struct SavedFace: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case `default`
        case custom
        case parts
    }

    public struct CallIds: Codable, Equatable, Sendable {
        public var leye: String?
        public var reye: String?
        public var mouth: String?
        public var cheek: String?

        public init(leye: String? = nil, reye: String? = nil, mouth: String? = nil, cheek: String? = nil) {
            self.leye = leye
            self.reye = reye
            self.mouth = mouth
            self.cheek = cheek
        }
    }

    public var id: String
    public var name: String
    public var type: Kind
    public var frameBytes: [Int]
    public var order: Int
    public var editable: Bool?
    public var deletable: Bool?
    public var locked: Bool?
    public var isStartupDefault: Bool?
    public var sourceFile: String?
    public var savedAt: String?
    public var updatedAt: String?
    public var call: CallIds?

    enum CodingKeys: String, CodingKey {
        case id, name, type, frameBytes, order, editable, deletable, locked
        case isStartupDefault = "is_startup_default"
        case sourceFile
        case savedAt
        case updatedAt
        case call
    }

    public init(id: String, name: String, type: Kind, frameBytes: [Int], order: Int,
                editable: Bool? = nil, deletable: Bool? = nil, locked: Bool? = nil,
                isStartupDefault: Bool? = nil, sourceFile: String? = nil, savedAt: String? = nil,
                updatedAt: String? = nil, call: CallIds? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.frameBytes = frameBytes
        self.order = order
        self.editable = editable
        self.deletable = deletable
        self.locked = locked
        self.isStartupDefault = isStartupDefault
        self.sourceFile = sourceFile
        self.savedAt = savedAt
        self.updatedAt = updatedAt
        self.call = call
    }

    /// The `PackedFrame` for `frameBytes`, or nil if malformed.
    public var packedFrame: PackedFrame? {
        guard frameBytes.count == PackedFrame.byteCount else { return nil }
        let bytes = frameBytes.map { UInt8(clamping: $0) }
        return PackedFrame(bytes: bytes)
    }
}

/// `saved_faces.json` document, format `rina_packed_faces_370_v2`, version 4.
public struct FaceDocument: Codable, Equatable, Sendable {
    public var format: String
    public var version: Int
    public var matrix: MatrixInfo?
    public var faces: [SavedFace]

    enum CodingKeys: String, CodingKey {
        case format, version, matrix, faces
    }

    public init(format: String = "rina_packed_faces_370_v2", version: Int = 4,
                matrix: MatrixInfo? = nil, faces: [SavedFace] = []) {
        self.format = format
        self.version = version
        self.matrix = matrix
        self.faces = faces
    }

    /// Faces sorted by `(order, index-in-array)`, matching the WebUI's stable sort.
    public var sortedFaces: [SavedFace] {
        faces.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.order != rhs.element.order {
                    return lhs.element.order < rhs.element.order
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(FaceDocument.self, from: jsonData)
    }

    /// Encodes back to JSON, preserving all fields.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
