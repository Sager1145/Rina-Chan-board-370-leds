import Foundation

/// One decoded/encoded RinaLink frame (header + payload), `RINALINK_PROTOCOL_V1.md` §2.
public struct RinaLinkFrame: Equatable, Sendable {
    public let type: UInt8
    public let seq: UInt8
    public let flags: UInt8
    public let payload: Data

    public init(type: UInt8, seq: UInt8, flags: UInt8, payload: Data) {
        self.type = type
        self.seq = seq
        self.flags = flags
        self.payload = payload
    }

    public init(type: RinaLinkMessageType, seq: UInt8, flags: UInt8 = 0, payload: Data) {
        self.init(type: type.rawValue, seq: seq, flags: flags, payload: payload)
    }

    public var isMore: Bool { (flags & RinaLinkFrameConstants.flagMore) != 0 }
    public var isError: Bool { type == RinaLinkMessageType.error.rawValue }
}

public enum RinaLinkEncoder {
    /// Encodes one frame (header + payload). Payloads over 4096 bytes must be
    /// split by the caller into multiple `BLOB_CHUNK` messages; this function
    /// does not itself slice.
    public static func encode(_ frame: RinaLinkFrame) -> Data {
        precondition(
            frame.payload.count <= RinaLinkFrameConstants.maxPayloadBytes,
            "RinaLinkEncoder.encode: payload (\(frame.payload.count) bytes) exceeds maxPayloadBytes (\(RinaLinkFrameConstants.maxPayloadBytes)); caller must slice into BLOB_CHUNK messages first"
        )
        var out = Data(capacity: RinaLinkFrameConstants.headerBytes + frame.payload.count)
        let length = UInt16(frame.payload.count)
        out.append(RinaLinkFrameConstants.magic)
        out.append(frame.type)
        out.append(frame.seq)
        out.append(frame.flags)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(frame.payload)
        return out
    }

    public static func encode(type: RinaLinkMessageType, seq: UInt8, flags: UInt8 = 0, payload: Data) -> Data {
        encode(RinaLinkFrame(type: type, seq: seq, flags: flags, payload: payload))
    }
}

/// Streaming decoder: feed arbitrary chunks of bytes (as they arrive from BLE
/// notifications or a TCP receive loop) and get back zero or more complete
/// frames. Resyncs on bad magic bytes by scanning forward for the next 0xA5.
public final class RinaLinkDecoder {
    private var buffer = Data()

    public init() {}

    /// Feeds newly received bytes, returning any frames that became complete.
    public func feed(_ data: Data) -> [RinaLinkFrame] {
        buffer.append(data)
        var frames: [RinaLinkFrame] = []

        while true {
            // Resync: drop bytes until buffer starts with magic.
            while let first = buffer.first, first != RinaLinkFrameConstants.magic {
                buffer.removeFirst()
            }
            guard buffer.count >= RinaLinkFrameConstants.headerBytes else { break }

            let bytes = [UInt8](buffer.prefix(RinaLinkFrameConstants.headerBytes))
            let type = bytes[1]
            let seq = bytes[2]
            let flags = bytes[3]
            let length = Int(bytes[4]) | (Int(bytes[5]) << 8)

            guard length <= RinaLinkFrameConstants.maxPayloadBytes else {
                // Corrupt length field; drop the magic byte and resync from the next one.
                buffer.removeFirst()
                continue
            }

            let total = RinaLinkFrameConstants.headerBytes + length
            guard buffer.count >= total else { break }

            let payload = buffer.subdata(in: (buffer.startIndex + RinaLinkFrameConstants.headerBytes)..<(buffer.startIndex + total))
            frames.append(RinaLinkFrame(type: type, seq: seq, flags: flags, payload: payload))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
        }

        return frames
    }

    public func reset() {
        buffer.removeAll()
    }
}
