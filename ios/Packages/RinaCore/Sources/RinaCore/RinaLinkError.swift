import Foundation

/// Decoded from a type `0xFF` error frame: `{"ok":false,"error":"...","code":<int>}`.
public struct RinaLinkError: Error, Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String
    public let code: Int?

    public init(ok: Bool = false, error: String, code: Int? = nil) {
        self.ok = ok
        self.error = error
        self.code = code
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
    case underlying(String)
}
