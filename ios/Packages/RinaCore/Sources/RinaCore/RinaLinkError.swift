import Foundation

/// Decoded from a type `0xFF` error frame: `{"ok":false,"error":"...","code":<int>}`.
public struct RinaLinkError: Error, Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String
    public let code: Int?
    /// Present on some 400 "unexpected chunk offset" replies so the caller
    /// can resync a `BLOB_CHUNK` upload instead of aborting it outright.
    public let expectedOffset: Int?

    public init(ok: Bool = false, error: String, code: Int? = nil, expectedOffset: Int? = nil) {
        self.ok = ok
        self.error = error
        self.code = code
        self.expectedOffset = expectedOffset
    }

    /// An error frame is a failure whatever its body says, so a reply that
    /// omits `ok` still decodes and keeps the board's own message.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        error = try container.decode(String.self, forKey: .error)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        expectedOffset = try container.decodeIfPresent(Int.self, forKey: .expectedOffset)
    }
}

extension RinaLinkError: LocalizedError {
    /// The localized message for this board error (`RinaErrorText.boardMessage`).
    /// The board's own English text stays in `error` / `boardText`.
    public var errorDescription: String? { RinaErrorText.boardMessage(error, code: code) }
}

extension RinaLinkError {
    /// The board's original, untranslated error text (same as `error`).
    public var boardText: String { error }

    /// Longest raw text kept from an error frame that is not a JSON error object.
    public static let maxUndecodableTextLength = 200

    /// Builds the error for a type `0xFF` frame payload, whatever shape it
    /// has. A well-formed `{"error":…}` object decodes exactly as `Codable`
    /// would. Otherwise the text is read loosely from `error` / `message` /
    /// `msg` / `reason` and the code from `code` / `status`; a payload that is
    /// not a JSON object is used as UTF-8 text (trimmed and capped at
    /// `maxUndecodableTextLength` characters); anything else gives an empty
    /// text, which `RinaErrorText` reports as an unknown board error.
    public init(errorFramePayload payload: Data) {
        self = Self.parse(errorFramePayload: payload)
    }

    private static func parse(errorFramePayload payload: Data) -> RinaLinkError {
        if let decoded = try? JSONDecoder().decode(RinaLinkError.self, from: payload) {
            return decoded
        }
        if let object = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) {
            if let fields = object as? [String: Any] {
                var text = ""
                for key in ["error", "message", "msg", "reason"] {
                    if let value = fields[key] as? String, !Self.cleaned(value).isEmpty {
                        text = value
                        break
                    }
                    if let nested = fields[key] as? [String: Any],
                       let value = nested["message"] as? String, !Self.cleaned(value).isEmpty {
                        text = value
                        break
                    }
                }
                return RinaLinkError(error: cleaned(text),
                                     code: looseInt(fields["code"]) ?? looseInt(fields["status"]),
                                     expectedOffset: looseInt(fields["expectedOffset"]))
            }
            if let text = object as? String {
                return RinaLinkError(error: cleaned(text))
            }
        }
        return RinaLinkError(error: cleaned(String(data: payload, encoding: .utf8) ?? ""))
    }

    private static func looseInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            // JSON true/false also arrive as NSNumber; they are not a code.
            // JSONSerialization boxes them as a `char`, numbers never.
            if String(cString: number.objCType) == "c" { return nil }
            return Int(exactly: number.doubleValue)
        }
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func cleaned(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxUndecodableTextLength else { return trimmed }
        return String(trimmed.prefix(maxUndecodableTextLength)) + "…"
    }
}

/// Transport / protocol level failures that are not board-reported errors.
public enum RinaTransportError: Error, Sendable {
    case notConnected
    case timeout
    case cancelled
    case invalidResponse
    case sequenceSpaceExhausted
    case underlying(String)
}

// Without this, UI shows the system's generic "The operation couldn't be
// completed (RinaCore.RinaTransportError …)" instead of the actual cause.
extension RinaTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: return NSLocalizedString("面板未连接", comment: "transport error not connected")
        case .timeout: return NSLocalizedString("面板响应超时", comment: "transport error timeout")
        case .cancelled: return NSLocalizedString("操作已取消", comment: "transport error cancelled")
        case .invalidResponse: return NSLocalizedString("面板回复无法解析", comment: "transport error invalid response")
        case .sequenceSpaceExhausted: return NSLocalizedString("等待中的面板请求过多，请稍后重试", comment: "all protocol sequence identifiers are in use")
        case .underlying(let message): return message
        }
    }
}
