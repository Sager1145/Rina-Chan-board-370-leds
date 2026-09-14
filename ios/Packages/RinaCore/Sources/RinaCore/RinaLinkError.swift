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
}

extension RinaLinkError: LocalizedError {
    public var errorDescription: String? { error }
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
