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
    case underlying(String)
}
