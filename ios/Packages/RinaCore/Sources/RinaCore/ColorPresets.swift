import Foundation

/// Decoded `color_presets.json` (`parent_color_groups`/`child_color_groups`
/// in the legacy `app.js`, ~L3140-L3249). 6 parent color groups, 67 total
/// child colors.
public struct ColorPresets: Codable, Sendable {
    public struct Parent: Codable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        public let color: String
        public let desc: String
    }

    public struct Child: Codable, Sendable, Equatable {
        public let name: String
        public let hex: String
    }

    public let parents: [Parent]
    public let children: [String: [Child]]

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(ColorPresets.self, from: jsonData)
    }

    /// The child colors belonging to `parentId` (string-keyed, e.g. "1"), in
    /// JSON order, or an empty array if `parentId` has none.
    public func children(of parentId: String) -> [Child] {
        children[parentId] ?? []
    }

    /// The child colors belonging to `parent.id`.
    public func children(of parent: Parent) -> [Child] {
        children(of: String(parent.id))
    }

    /// Finds the parent/child pair whose child hex matches `hex`
    /// (case-insensitive, `#` optional).
    public func lookup(hex: String) -> (parent: Parent, child: Child)? {
        let target = RGBHex.normalize(hex)
        for parent in parents {
            for child in children(of: parent) where RGBHex.normalize(child.hex) == target {
                return (parent, child)
            }
        }
        return nil
    }

    /// Selectable colors in WebUI order: the team's own color, then its members
    /// and subunits. A group without children still offers its own color.
    public func swatches(of parent: Parent) -> [Child] {
        [Child(name: parent.name, hex: parent.color)] + children(of: parent)
    }

    /// Resolve team colors before member colors, matching WebUI synchronization.
    public func parent(containing hex: String) -> Parent? {
        let target = RGBHex.normalize(hex)
        return parents.first { RGBHex.normalize($0.color) == target }
            ?? lookup(hex: hex)?.parent
    }

    /// Localized display name for a preset's raw stored `name` (a parent or
    /// child `name` straight out of `color_presets.json`), looked up in
    /// `PresetNames.xcstrings` keyed by that raw name. Falls back to the raw
    /// name unchanged if there's no translation for it, so calling this on a
    /// string that isn't a built-in preset name is harmless.
    public static func displayName(_ raw: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: raw, value: raw, table: "PresetNames")
    }
}

/// Hex color parsing/formatting and the LED power estimate used by the
/// legacy WebUI's power meter (FEATURE_INVENTORY C2).
public enum RGBHex {
    /// Parses `"#rrggbb"` (or `"rrggbb"`, case-insensitive) into 0...255 RGB
    /// components. Returns nil for malformed input.
    public static func parseHex(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let r = Int((value >> 16) & 0xFF)
        let g = Int((value >> 8) & 0xFF)
        let b = Int(value & 0xFF)
        return (r, g, b)
    }

    /// Formats RGB components (each clamped to 0...255) as lowercase `#rrggbb`.
    public static func formatHex(r: Int, g: Int, b: Int) -> String {
        let clampedR = min(max(r, 0), 255)
        let clampedG = min(max(g, 0), 255)
        let clampedB = min(max(b, 0), 255)
        return String(format: "#%02x%02x%02x", clampedR, clampedG, clampedB)
    }

    /// Normalizes a hex string to lowercase `#rrggbb` for comparison, or the
    /// original trimmed/lowercased string if it doesn't parse.
    static func normalize(_ hex: String) -> String {
        guard let (r, g, b) = parseHex(hex) else {
            return hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return formatHex(r: r, g: g, b: b)
    }

    /// Estimated power draw in watts (FEATURE_INVENTORY C2):
    /// `litCount * 0.06W/channel * 5 channels * (brightness/255) * (r+g+b)/765`.
    public static func estimatedWatts(litCount: Int, brightness: Int, hex: String) -> Double {
        guard let (r, g, b) = parseHex(hex) else { return 0 }
        let brightnessFraction = Double(brightness) / 255.0
        let colorFraction = Double(r + g + b) / 765.0
        return Double(litCount) * 0.06 * 5.0 * brightnessFraction * colorFraction
    }
}
