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
        case id, name, type, frameBytes, frameHex, order, editable, deletable, locked
        case isStartupDefault = "is_startup_default"
        case sourceFile
        case savedAt
        case updatedAt
        case call
    }

    /// Sentinel written by the lenient decoder when `order` is missing so
    /// `FaceDocument`'s decoder can backfill it with `index + 1`.
    static let missingOrderSentinel = Int.min

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

    /// Lenient decoding so one malformed face doesn't fail the whole document:
    /// an unknown/missing `type` falls back to `.custom`, a missing/invalid
    /// `frameBytes` falls back to decoding a `frameHex` hex string, and a
    /// missing `order` is marked with `missingOrderSentinel` for
    /// `FaceDocument` to backfill with `index + 1`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? id
        if let rawType = try? container.decode(Kind.self, forKey: .type) {
            type = rawType
        } else {
            type = .custom
        }
        // `frameBytes` wins only when it is actually usable. Accepting any
        // non-empty array let a malformed one (e.g. `[999]`) beat a perfectly
        // valid `frameHex`, so the documented hex fallback never ran and the
        // face failed to decode at all. When neither representation is usable
        // the old `frameBytes`-first precedence still applies, so nothing that
        // used to round-trip is dropped.
        let rawBytes = (try? container.decode([Int].self, forKey: .frameBytes))
            .flatMap { $0.isEmpty ? nil : $0 }
        let hexBytes = (try? container.decode(String.self, forKey: .frameHex))
            .flatMap { SavedFace.bytes(fromHex: $0) }
        frameBytes = [rawBytes, hexBytes].compactMap { $0 }.first(where: SavedFace.isUsableFrame)
            ?? rawBytes ?? hexBytes ?? []
        order = (try? container.decode(Int.self, forKey: .order)) ?? SavedFace.missingOrderSentinel
        editable = try? container.decode(Bool.self, forKey: .editable)
        deletable = try? container.decode(Bool.self, forKey: .deletable)
        locked = try? container.decode(Bool.self, forKey: .locked)
        isStartupDefault = try? container.decode(Bool.self, forKey: .isStartupDefault)
        sourceFile = try? container.decode(String.self, forKey: .sourceFile)
        savedAt = try? container.decode(String.self, forKey: .savedAt)
        updatedAt = try? container.decode(String.self, forKey: .updatedAt)
        call = try? container.decode(CallIds.self, forKey: .call)
    }

    private static func bytes(fromHex hex: String) -> [Int]? {
        var trimmed = Substring(hex)
        if trimmed.count % 2 != 0 { return nil }
        var result: [Int] = []
        result.reserveCapacity(trimmed.count / 2)
        while !trimmed.isEmpty {
            let next = trimmed.index(trimmed.startIndex, offsetBy: 2)
            guard let byte = UInt8(trimmed[trimmed.startIndex..<next], radix: 16) else { return nil }
            result.append(Int(byte))
            trimmed = trimmed[next...]
        }
        return result
    }

    /// Whether `bytes` has the exact shape a `PackedFrame` needs.
    static func isUsableFrame(_ bytes: [Int]) -> Bool {
        bytes.count == PackedFrame.byteCount && bytes.allSatisfy { (0...255).contains($0) }
    }

    /// The `PackedFrame` for `frameBytes`, or nil if malformed.
    public var packedFrame: PackedFrame? {
        guard Self.isUsableFrame(frameBytes) else { return nil }
        let bytes = frameBytes.map { UInt8($0) }
        return PackedFrame(bytes: bytes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(frameBytes, forKey: .frameBytes)
        try container.encode(order, forKey: .order)
        try container.encodeIfPresent(editable, forKey: .editable)
        try container.encodeIfPresent(deletable, forKey: .deletable)
        try container.encodeIfPresent(locked, forKey: .locked)
        try container.encodeIfPresent(isStartupDefault, forKey: .isStartupDefault)
        try container.encodeIfPresent(sourceFile, forKey: .sourceFile)
        try container.encodeIfPresent(savedAt, forKey: .savedAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(call, forKey: .call)
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

    /// Decodes for a user-initiated import, additionally reporting how many
    /// entries the lenient decoder had to skip.
    ///
    /// Skipping is the right behavior when reading data the board or this app
    /// already owns — one bad entry must not cost the whole library. It is the
    /// wrong behavior for an import the user just asked for, because the result
    /// is uploaded as a whole-document replacement: the difference between
    /// "imported your file" and "imported the part of your file that parsed"
    /// has to be visible. Callers refuse the import when this is non-zero.
    public static func decodedForImport(
        jsonData: Data
    ) throws -> (document: FaceDocument, skippedFaceCount: Int) {
        let diagnostics = FaceDecodeDiagnostics()
        let decoder = JSONDecoder()
        decoder.userInfo[.faceDecodeDiagnostics] = diagnostics
        let document = try decoder.decode(FaceDocument.self, from: jsonData)
        return (document, diagnostics.skippedFaceCount)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? container.decode(String.self, forKey: .format)) ?? "rina_packed_faces_370_v2"
        version = (try? container.decode(Int.self, forKey: .version)) ?? 4
        matrix = try? container.decode(MatrixInfo.self, forKey: .matrix)
        // Decode faces one at a time so a single malformed entry (e.g. missing
        // `id`) is skipped instead of failing the whole `faces` array.
        var decodedFaces: [SavedFace] = []
        if var facesContainer = try? container.nestedUnkeyedContainer(forKey: .faces) {
            while !facesContainer.isAtEnd {
                if let face = try? facesContainer.decode(SavedFace.self) {
                    decodedFaces.append(face)
                } else {
                    // Advance the cursor past the malformed element (JSON
                    // faces are always objects) instead of looping forever.
                    _ = try? facesContainer.decode(AnyJSONSkip.self)
                    (decoder.userInfo[.faceDecodeDiagnostics] as? FaceDecodeDiagnostics)?
                        .noteSkippedFace()
                }
            }
        }
        // Backfill any face whose `order` was missing on decode with `index + 1`
        // (SavedFace.init(from:) marks it with `missingOrderSentinel`).
        for index in decodedFaces.indices where decodedFaces[index].order == SavedFace.missingOrderSentinel {
            decodedFaces[index].order = index + 1
        }
        faces = decodedFaces
    }

    /// Encodes back to JSON, preserving all fields.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Collects what the lenient face decoder had to discard, so a user-initiated
/// import can refuse to silently replace a library with a partial parse.
/// Passed through `JSONDecoder.userInfo`; reading paths simply omit it and keep
/// the lenient behavior.
public final class FaceDecodeDiagnostics {
    public private(set) var skippedFaceCount = 0
    public init() {}
    func noteSkippedFace() { skippedFaceCount += 1 }
}

extension CodingUserInfoKey {
    public static let faceDecodeDiagnostics = CodingUserInfoKey(rawValue: "rina.faceDecodeDiagnostics")!
}

/// Consumes exactly one JSON value (object, array, or scalar) without caring
/// about its shape — used to advance an unkeyed container's cursor past a
/// malformed `SavedFace` entry that failed to decode.
private struct AnyJSONSkip: Decodable {
    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            while !unkeyed.isAtEnd {
                _ = try? unkeyed.decode(AnyJSONSkip.self)
            }
        } else if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in keyed.allKeys {
                _ = try? keyed.decode(AnyJSONSkip.self, forKey: key)
            }
        } else {
            _ = try? decoder.singleValueContainer()
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}
