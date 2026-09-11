import Foundation

/// A single decoded glyph from the Ark Pixel 12px bitmap font table, ready to
/// be blitted into a scroll-text bitmap. Mirrors the shape produced by the
/// WebUI's `buildTextGlyph()` (app.js ~12189).
public struct ArkGlyph: Sendable {
    public let isSpace: Bool
    public let advance: Int
    public let width: Int
    public let height: Int
    public let xOffset: Int
    public let yOffset: Int
    public let dstY: Int
    /// `height` rows of `width` columns each; `rows[y][x]` is `true` when the
    /// pixel is lit.
    public let rows: [[Bool]]

    /// `pixel(x, y)` per app.js `glyphPixel()`.
    public func pixel(x: Int, y: Int) -> Bool {
        guard y >= 0 && y < rows.count else { return false }
        let row = rows[y]
        guard x >= 0 && x < row.count else { return false }
        return row[x]
    }

    static let space = ArkGlyph(
        isSpace: true, advance: ScrollRasterizer.spaceColumns, width: 0, height: 0,
        xOffset: 0, yOffset: 0, dstY: 0, rows: []
    )
}

/// Loads and serves glyphs from `ark12.json`, ported from the WebUI's
/// `loadArkPixelFontTable()` / `buildTextGlyph()` (app.js ~4188-4229, 12151-12227).
///
/// Parses the 2.5 MB JSON table once with `JSONSerialization`, but keeps each
/// glyph's raw tuple (advance/width/height/offsets/rowsHex) instead of eagerly
/// decoding all 33k+ glyphs into `[[Bool]]` bitmaps; row decoding happens on
/// first use and is cached.
public final class ArkPixelFont: @unchecked Sendable {
    public let rows: Int
    public let lineHeight: Int
    public let ascent: Int
    public let descent: Int
    public let defaultAdvance: Int

    /// Fallback glyph codepoint (U+25A1, WHITE SQUARE) per spec.
    public static let missingGlyphScalar: Unicode.Scalar = Unicode.Scalar(0x25A1)!

    private struct RawGlyph {
        let advance: Double
        let width: Int
        let height: Int
        let xOffset: Int
        let yOffset: Int
        let dstY: Int
        let rowsHex: String
    }

    private let rawGlyphs: [UInt32: RawGlyph]

    private let cacheLock = NSLock()
    private var decodedCache: [UInt32: ArkGlyph] = [:]

    public enum FontError: Error {
        case invalidFormat
        case invalidGlyphTable
    }

    public init(jsonData: Data) throws {
        guard
            let top = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw FontError.invalidFormat
        }

        func number(_ key: String) -> Double? {
            (top[key] as? NSNumber)?.doubleValue
        }

        let headerRows = Int(number("rows") ?? number("lineHeight") ?? 12)
        self.rows = headerRows
        self.lineHeight = headerRows
        self.ascent = Int(number("ascent") ?? 10)
        self.descent = Int(number("descent") ?? Double(max(0, headerRows - Int(number("ascent") ?? 10))))
        self.defaultAdvance = Int(number("defaultAdvance") ?? 12)

        guard let glyphsObject = top["glyphs"] as? [String: Any] else {
            throw FontError.invalidGlyphTable
        }

        var table: [UInt32: RawGlyph] = [:]
        table.reserveCapacity(glyphsObject.count)
        for (hexKey, value) in glyphsObject {
            guard let cp = UInt32(hexKey, radix: 16) else { continue }
            guard let tuple = value as? [Any], tuple.count >= 7 else { continue }
            let advance = (tuple[0] as? NSNumber)?.doubleValue ?? 0
            let width = Int((tuple[1] as? NSNumber)?.doubleValue ?? 0)
            let height = Int((tuple[2] as? NSNumber)?.doubleValue ?? 0)
            let xOffset = Int((tuple[3] as? NSNumber)?.doubleValue ?? 0)
            let yOffset = Int((tuple[4] as? NSNumber)?.doubleValue ?? 0)
            let dstY = Int((tuple[5] as? NSNumber)?.doubleValue ?? 0)
            let rowsHex = (tuple[6] as? String) ?? ""
            table[cp] = RawGlyph(
                advance: advance, width: max(0, width), height: max(0, height),
                xOffset: xOffset, yOffset: yOffset, dstY: dstY, rowsHex: rowsHex
            )
        }
        guard !table.isEmpty else { throw FontError.invalidGlyphTable }
        self.rawGlyphs = table
    }

    public static func loadBundled(url: URL) throws -> ArkPixelFont {
        let data = try Data(contentsOf: url)
        return try ArkPixelFont(jsonData: data)
    }

    /// `glyph(for cp)` per app.js `buildTextGlyph()`.
    public func glyph(for scalar: Unicode.Scalar) -> ArkGlyph {
        if Character(scalar).isWhitespace {
            return .space
        }

        let cp = scalar.value
        if let cached = cachedGlyph(for: cp) {
            return cached
        }

        let raw = rawGlyphs[cp] ?? rawGlyphs[Self.missingGlyphScalar.value]
        guard let raw else {
            // Defensive fallback; ark12.json is guaranteed to contain U+25A1.
            let empty = ArkGlyph(
                isSpace: false, advance: max(1, defaultAdvance), width: 0, height: 0,
                xOffset: 0, yOffset: 0, dstY: 0, rows: []
            )
            cache(empty, for: cp)
            return empty
        }

        let width = raw.width
        let decodedRows = Self.decodePackedRows(raw.rowsHex, width: width)
        let height = raw.height != 0 ? raw.height : decodedRows.count
        let advance = raw.advance.isFinite ? max(0, Int(raw.advance)) : max(1, defaultAdvance)

        var finalRows: [[Bool]] = []
        finalRows.reserveCapacity(height)
        for y in 0..<height {
            let bits = y < decodedRows.count ? decodedRows[y] : ""
            var row = [Bool](repeating: false, count: width)
            for (i, ch) in bits.enumerated() where i < width {
                row[i] = ch == "1"
            }
            finalRows.append(row)
        }

        let glyph = ArkGlyph(
            isSpace: false, advance: advance, width: width, height: height,
            xOffset: raw.xOffset, yOffset: raw.yOffset, dstY: raw.dstY, rows: finalRows
        )
        cache(glyph, for: cp)
        return glyph
    }

    private func cachedGlyph(for cp: UInt32) -> ArkGlyph? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return decodedCache[cp]
    }

    private func cache(_ glyph: ArkGlyph, for cp: UInt32) {
        cacheLock.lock()
        decodedCache[cp] = glyph
        cacheLock.unlock()
    }

    /// `decodePackedGlyphRows()` (app.js ~4188): each row is `ceil(width/4)`
    /// hex nibbles, MSB-first, decoded to a bit string of exactly `width` bits.
    static func decodePackedRows(_ rowsHex: String, width: Int) -> [String] {
        guard !rowsHex.isEmpty else { return [] }
        let nibbles = max(1, Int(ceil(Double(max(0, width)) / 4.0)))
        return rowsHex.split(separator: "/", omittingEmptySubsequences: false).map { rowHex in
            let cleaned = rowHex.filter { $0.isHexDigit }
            var padded = String(repeating: "0", count: max(0, nibbles - cleaned.count)) + cleaned
            if padded.count > nibbles {
                padded = String(padded.suffix(nibbles))
            }
            var bits = ""
            bits.reserveCapacity(nibbles * 4)
            for ch in padded {
                let value = UInt8(String(ch), radix: 16) ?? 0
                bits += String(String(value, radix: 2))
                    .leftPadded(toLength: 4, with: "0")
            }
            return String(bits.prefix(max(0, width)))
        }
    }
}

private extension String {
    func leftPadded(toLength length: Int, with pad: Character) -> String {
        if count >= length { return self }
        return String(repeating: String(pad), count: length - count) + self
    }
}
