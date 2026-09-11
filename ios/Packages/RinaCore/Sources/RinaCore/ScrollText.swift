import Foundation

/// Text normalisation helpers for the scroll-text feature, ported from the
/// WebUI (app.js 4102-4156, 9819-9866, 11047). All iteration is by Unicode
/// scalar (codepoint), matching the JS `Array.from(text)` codepoint walk.
public enum ScrollText {
    /// Visible-character cap enforced client-side (`MAX_SCROLL_TEXT_CHARS`).
    public static let maxVisibleChars = 1000
    /// UTF-8 byte cap enforced before upload (`MAX_SCROLL_TEXT_BYTES`).
    public static let maxTextBytes = 4096

    /// `isEmojiFormatControl(cp)` (app.js ~4106).
    public static func isEmojiFormatControl(_ scalar: Unicode.Scalar) -> Bool {
        let cp = scalar.value
        return (cp >= 0xFE00 && cp <= 0xFE0F)
            || cp == 0x200D
            || (cp >= 0x1F3FB && cp <= 0x1F3FF)
            || (cp >= 0xE0000 && cp <= 0xE007F)
    }

    /// `isTextScrollEmojiPresentationBase(cp)` (app.js ~4114).
    public static func isEmojiPresentationBase(_ scalar: Unicode.Scalar) -> Bool {
        let cp = scalar.value
        return cp == 0x00A9
            || cp == 0x00AE
            || cp == 0x203C
            || cp == 0x2049
            || cp == 0x2122
            || cp == 0x2139
            || (cp >= 0x2194 && cp <= 0x21AA)
            || (cp >= 0x231A && cp <= 0x23FF)
            || (cp >= 0x2460 && cp <= 0x24FF)
            || (cp >= 0x25AA && cp <= 0x27BF)
            || (cp >= 0x2934 && cp <= 0x2935)
            || (cp >= 0x2B05 && cp <= 0x2B55)
            || cp == 0x3030
            || cp == 0x303D
            || cp == 0x3297
            || cp == 0x3299
            || (cp >= 0x1F000 && cp <= 0x1FAFF)
    }

    private static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0xFE00 && scalar.value <= 0xFE0F
    }

    /// `normalizeTextScrollEmojiPresentation(text)` (app.js ~4140): every
    /// presentation base gets exactly one trailing U+FE0E; other variation
    /// selectors are dropped.
    public static func normalizeEmojiPresentation(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let cp = scalars[i]
            if isVariationSelector(cp) {
                if let last = out.last, isEmojiPresentationBase(last) {
                    out.append(Unicode.Scalar(0xFE0E)!)
                }
                i += 1
                continue
            }
            out.append(cp)
            if isEmojiPresentationBase(cp) {
                let next = i + 1 < scalars.count ? scalars[i + 1] : nil
                if !(next.map(isVariationSelector) ?? false) {
                    out.append(Unicode.Scalar(0xFE0E)!)
                }
            }
            i += 1
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: out)
        return String(view)
    }

    /// `truncateScrollText(text)` (app.js ~9819): keeps scalars while the
    /// running count of non-format-control scalars is `<= maxVisibleChars`.
    public static func truncate(_ text: String, maxVisibleChars: Int = ScrollText.maxVisibleChars) -> String {
        var view = String.UnicodeScalarView()
        var visibleCount = 0
        for scalar in text.unicodeScalars {
            if !isEmojiFormatControl(scalar) {
                visibleCount += 1
            }
            if visibleCount > maxVisibleChars {
                break
            }
            view.append(scalar)
        }
        return String(view)
    }

    /// `scrollTextVisibleCharCount(text)` (app.js ~9829): normalises, then
    /// counts scalars that are not format controls.
    public static func visibleCharCount(_ text: String) -> Int {
        let normalized = normalizeEmojiPresentation(text)
        return normalized.unicodeScalars.reduce(0) { count, scalar in
            isEmojiFormatControl(scalar) ? count : count + 1
        }
    }

    public static func utf8ByteCount(_ text: String) -> Int {
        text.utf8.count
    }

    /// Byte-limit pre-flight check (app.js ~3031) run before rasterising.
    public static func exceedsByteLimit(_ text: String, limit: Int = ScrollText.maxTextBytes) -> Bool {
        utf8ByteCount(text) > limit
    }
}
