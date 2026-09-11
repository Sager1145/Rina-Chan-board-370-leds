import Foundation

/// Message type byte, `RINALINK_PROTOCOL_V1.md` §3. Reply types are the
/// request type OR'd with `0x80` (see `replyType`).
public enum RinaLinkMessageType: UInt8, Sendable {
    // Control
    case cmd = 0x01
    case getStatus = 0x02
    case getPower = 0x03
    case getScrollMeta = 0x04
    case getPreviewSync = 0x05
    case ping = 0x06

    // Frames
    case setFrame = 0x10
    case getFrame = 0x11

    // Blob
    case blobBegin = 0x20
    case blobChunk = 0x21
    case blobEnd = 0x22
    case blobAbort = 0x23
    case getFaces = 0x24

    // Events (board -> client, seq = 0)
    case evPreviewSync = 0x90
    case evStatus = 0x91
    case evPower = 0x92
    case evWifi = 0x93
    case evLog = 0x94
    case evWifiScan = 0x95

    case error = 0xFF

    /// The reply type byte for a request type: `type | 0x80`.
    public var replyType: UInt8 { rawValue | 0x80 }

}

public enum RinaLinkFrameConstants {
    public static let magic: UInt8 = 0xA5
    public static let headerBytes = 6
    public static let maxPayloadBytes = 4096
    public static let flagMore: UInt8 = 0x01
}
