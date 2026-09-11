import Foundation

/// One of the four composable expression-part groups (`app.js`
/// `selectedCall` keys / `EXPRESSION_PARTS.call.ids` keys).
public enum PartGroup: String, CaseIterable, Codable, Sendable, Hashable {
    case leye
    case reye
    case mouth
    case cheek

    /// The `EXPRESSION_PARTS.parts[*].type` value used by parts in this group.
    public var partType: String {
        switch self {
        case .leye: return "eye_left"
        case .reye: return "eye_right"
        case .mouth: return "mouth"
        case .cheek: return "cheek"
        }
    }

    /// Localized display name (`左眼`/`右眼`/`嘴巴`/`脸颊`).
    public var displayName: String {
        switch self {
        case .leye:
            return NSLocalizedString("partGroup.leye", value: "左眼", comment: "Left eye part group")
        case .reye:
            return NSLocalizedString("partGroup.reye", value: "右眼", comment: "Right eye part group")
        case .mouth:
            return NSLocalizedString("partGroup.mouth", value: "嘴巴", comment: "Mouth part group")
        case .cheek:
            return NSLocalizedString("partGroup.cheek", value: "脸颊", comment: "Cheek part group")
        }
    }
}

/// The four part IDs that make up a composed expression, mirroring `app.js`'s
/// `selectedCall` object.
public struct PartsCall: Hashable, Codable, Sendable {
    public var leye: String
    public var reye: String
    public var mouth: String
    public var cheek: String

    public init(leye: String, reye: String, mouth: String, cheek: String) {
        self.leye = leye
        self.reye = reye
        self.mouth = mouth
        self.cheek = cheek
    }

    public subscript(group: PartGroup) -> String {
        get {
            switch group {
            case .leye: return leye
            case .reye: return reye
            case .mouth: return mouth
            case .cheek: return cheek
            }
        }
        set {
            switch group {
            case .leye: leye = newValue
            case .reye: reye = newValue
            case .mouth: mouth = newValue
            case .cheek: cheek = newValue
            }
        }
    }

    /// `EXPRESSION_PARTS.call.default_face` (`app.js` ~L230): `{leye:101, reye:201, mouth:301, cheek:400}`.
    public static let defaultCall = PartsCall(leye: "101", reye: "201", mouth: "301", cheek: "400")
}

/// Decoded `expression_parts.json` (`EXPRESSION_PARTS` in the legacy `app.js`,
/// ~L203-L2995). Provides part lookup and the same composition/randomization/
/// symmetry semantics as `composePartsFrame`, `randomParts`, and
/// `syncSymmetricEyesFrom` in the legacy WebUI.
public struct PartsLibrary: Codable, Sendable {
    public struct Matrix: Codable, Sendable {
        public let cols: Int
        public let rows: Int
        public let numLeds: Int
        public let rowLengths: [Int]
        public let rowValidXRanges: [[Int]]
        public let serpentine: Bool
        public let serpentineOddRowsReversed: Bool

        enum CodingKeys: String, CodingKey {
            case cols, rows
            case numLeds = "num_leds"
            case rowLengths = "row_lengths"
            case rowValidXRanges = "row_valid_x_ranges"
            case serpentine
            case serpentineOddRowsReversed = "serpentine_odd_rows_reversed"
        }
    }

    public struct LayoutBox: Codable, Sendable {
        public let h: Int
        public let w: Int
        public let x: Int
        public let y: Int
        public let role: String
        public let mirrorX: Bool

        enum CodingKeys: String, CodingKey {
            case h, w, x, y, role
            case mirrorX = "mirror_x"
        }
    }

    public struct Call: Codable, Sendable {
        public let ids: [String: [String]]
        public let map: [String: [String: String]]
        public let defaultFace: [String: Int]

        enum CodingKeys: String, CodingKey {
            case ids, map
            case defaultFace = "default_face"
        }
    }

    public struct Part: Codable, Sendable, Equatable {
        public struct Placement: Codable, Sendable, Equatable {
            public let x: Int
            public let y: Int
            public let mirrorX: Bool

            enum CodingKeys: String, CodingKey {
                case x, y
                case mirrorX = "mirror_x"
            }
        }

        public let id: Int
        public let name: String
        public let type: String
        public let size: [Int]
        public let rowHex: [String]
        public let preview: [String]
        public let placement: [Placement]
        public let frame: String
        public let stripIndices: [Int]
        public let litCount: Int
        public let bbox: [Int]?

        enum CodingKeys: String, CodingKey {
            case id, name, type, size, preview, placement, frame, bbox
            case rowHex = "row_hex"
            case stripIndices = "strip_indices"
            case litCount = "lit_count"
        }
    }

    public let format: String
    public let version: Int
    public let matrix: Matrix
    public let layout: [String: [LayoutBox]]
    public let call: Call
    public let groups: [String: [String]]
    public let parts: [String: Part]

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(PartsLibrary.self, from: jsonData)
    }

    /// The IDs callable for `group`, in the exact order listed in
    /// `EXPRESSION_PARTS.call.ids[<group>]` (`app.js` ~L212-L230). The first
    /// entry ("0" for eyes/mouth, "400" for cheeks) denotes the empty part.
    public func ids(for group: PartGroup) -> [String] {
        call.ids[group.rawValue] ?? []
    }

    /// Looks up a part by its raw storage key (`parts[id]`). Note that the
    /// *callable* ID "400" (cheek's empty placeholder) is not a storage key;
    /// use `resolvedPart(group:id:)` to resolve call IDs through `call.map`.
    public func part(id: String) -> Part? {
        parts[id]
    }

    /// Resolves a call ID through `call.map[group]` (mirrors `resolvePartId`
    /// in `app.js` ~L5811): `cheek` "400" maps to storage key "0"; falls back
    /// to the empty part "0" if the resolved key isn't a stored part.
    public func resolvedPart(group: PartGroup, id: String) -> Part {
        let normalized = id
        let mapped = call.map[group.rawValue]?[normalized] ?? normalized
        let resolved = (group == .cheek && mapped == "400") ? "0" : mapped
        return parts[resolved] ?? parts["0"] ?? emptyPart
    }

    private var emptyPart: Part {
        Part(id: 0, name: "empty_000", type: "empty", size: [8, 8],
             rowHex: Array(repeating: "00", count: 8),
             preview: Array(repeating: String(repeating: ".", count: 8), count: 8),
             placement: [], frame: String(repeating: "0", count: 94),
             stripIndices: [], litCount: 0, bbox: nil)
    }

    /// The `PackedFrame` for `part.frame` (94 hex chars), or a blank frame if
    /// the hex is malformed.
    public func frame(for part: Part) -> PackedFrame {
        PackedFrame(hex94: part.frame) ?? PackedFrame()
    }

    /// Rebuilds `part`'s frame from its *physical* `strip_indices` by mapping
    /// each physical index to its logical index via `physicalToLogicalIndex`
    /// (the fallback path in `orPartIntoFrame`, `app.js` ~L5680). `table` is
    /// the `matrix_geometry.json` `physical_to_logical_index` array (370
    /// entries); pass `MatrixGeometry.physicalToLogicalIndex` wrapped in a
    /// closure if the precomputed table isn't available.
    public func frameFromStripIndices(_ part: Part, physicalToLogicalIndex table: [Int]) -> PackedFrame {
        var frame = PackedFrame()
        for physical in part.stripIndices {
            guard physical >= 0 && physical < table.count else { continue }
            let logical = table[physical]
            guard logical >= 0 && logical < PackedFrame.ledCount else { continue }
            frame.set(logical)
        }
        return frame
    }

    /// Composes the four selected parts into one frame, mirroring
    /// `frameFromPartsCall`/`orPartIntoFrame` (`app.js` ~L5680-5699): OR each
    /// resolved part's `frame` into a blank frame. Empty ids ("0"/"400")
    /// resolve to the all-zero part and contribute nothing.
    public func compose(call selected: PartsCall) -> PackedFrame {
        var frame = PackedFrame()
        for group in [PartGroup.leye, .reye, .mouth, .cheek] {
            let part = resolvedPart(group: group, id: selected[group])
            frame.formUnion(self.frame(for: part))
        }
        return frame
    }

    /// Picks a random call mirroring `randomParts()` (`app.js` ~L9783).
    /// Non-symmetric mode: eyes and mouth never pick "0" (empty); cheek may
    /// pick any listed id, including the empty placeholder "400".
    public func randomCall(using generator: inout some RandomNumberGenerator) -> PartsCall {
        func randomNonEmpty(_ group: PartGroup) -> String {
            let candidates = ids(for: group).filter { $0 != "0" }
            guard !candidates.isEmpty else { return "0" }
            return candidates[Int.random(in: 0..<candidates.count, using: &generator)]
        }
        func randomAny(_ group: PartGroup) -> String {
            let candidates = ids(for: group)
            guard !candidates.isEmpty else { return "0" }
            return candidates[Int.random(in: 0..<candidates.count, using: &generator)]
        }
        return PartsCall(
            leye: randomNonEmpty(.leye),
            reye: randomNonEmpty(.reye),
            mouth: randomNonEmpty(.mouth),
            cheek: randomAny(.cheek)
        )
    }

    /// Picks a random *symmetric* call, mirroring `randomParts()`'s
    /// `partsSymmetry` branch: both eyes pick the same display index (never
    /// index 0, the empty placeholder), so `leye`/`reye` land on
    /// corresponding parts (e.g. index 1 -> "101"/"201").
    public func randomSymmetricCall(using generator: inout some RandomNumberGenerator) -> PartsCall {
        let leyeIds = ids(for: .leye)
        let reyeIds = ids(for: .reye)
        let maxEyeIndex = min(leyeIds.count, reyeIds.count) - 1
        let upperBound = max(1, maxEyeIndex)
        let eyeIndex = 1 + Int.random(in: 0..<upperBound, using: &generator)
        let clampedIndex = min(max(eyeIndex, 0), max(leyeIds.count, reyeIds.count) - 1)
        let leye = leyeIds[min(clampedIndex, leyeIds.count - 1)]
        let reye = reyeIds[min(clampedIndex, reyeIds.count - 1)]
        let mouthIds = ids(for: .mouth).filter { $0 != "0" }
        let cheekIds = ids(for: .cheek)
        let mouth = mouthIds.isEmpty ? "0" : mouthIds[Int.random(in: 0..<mouthIds.count, using: &generator)]
        let cheek = cheekIds.isEmpty ? "400" : cheekIds[Int.random(in: 0..<cheekIds.count, using: &generator)]
        return PartsCall(leye: leye, reye: reye, mouth: mouth, cheek: cheek)
    }

    /// Finds the display index of `id` within `group`'s callable id list,
    /// mirroring `getPartDisplayIndex` (`app.js` ~L9694).
    public func displayIndex(of id: String, in group: PartGroup) -> Int? {
        ids(for: group).firstIndex(of: id)
    }

    /// The callable id at `index` within `group`'s list, clamped to bounds,
    /// mirroring `callIdAtDisplayIndex` (`app.js` ~L9698).
    public func callId(at index: Int, in group: PartGroup) -> String {
        let list = ids(for: group)
        guard !list.isEmpty else { return "0" }
        let clamped = min(max(index, 0), list.count - 1)
        return list[clamped]
    }

    /// The mirrored eye id for `id` (assumed to belong to `leye` or `reye`),
    /// mirroring `syncSymmetricEyesFrom` (`app.js` ~L9704): eyes are mirrored
    /// by *display index* within their respective callable id lists, not by
    /// numeric suffix, e.g. `leye` index 1 ("101") <-> `reye` index 1 ("201").
    public func mirroredEyeId(_ id: String) -> String? {
        if let idx = displayIndex(of: id, in: .leye) {
            return callId(at: idx, in: .reye)
        }
        if let idx = displayIndex(of: id, in: .reye) {
            return callId(at: idx, in: .leye)
        }
        return nil
    }
}
