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
    public enum EncodingError: Error, Equatable, Sendable {
        case payloadTooLarge(actual: Int, maximum: Int)
    }

    /// Encodes one frame (header + payload). Payloads over 4096 bytes must be
    /// split by the caller into multiple `BLOB_CHUNK` messages; this function
    /// does not itself slice.
    public static func encode(_ frame: RinaLinkFrame) throws -> Data {
        try validatePayloadSize(frame.payload.count)
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

    public static func validatePayloadSize(_ count: Int) throws {
        guard count <= RinaLinkFrameConstants.maxPayloadBytes else {
            throw EncodingError.payloadTooLarge(
                actual: count,
                maximum: RinaLinkFrameConstants.maxPayloadBytes
            )
        }
    }

    public static func encode(type: RinaLinkMessageType, seq: UInt8, flags: UInt8 = 0, payload: Data) throws -> Data {
        try encode(RinaLinkFrame(type: type, seq: seq, flags: flags, payload: payload))
    }
}

extension RinaLinkEncoder.EncodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge(let actual, let maximum):
            return "RinaLink payload is \(actual) bytes; the maximum is \(maximum) bytes"
        }
    }
}

/// Streaming decoder: feed arbitrary chunks of bytes (as they arrive from BLE
/// notifications or a TCP receive loop) and get back zero or more complete
/// frames. Resyncs on bad magic bytes by scanning forward for the next 0xA5.
/// Internally keeps a read cursor into `storage` instead of repeatedly
/// removing consumed bytes, and only compacts the buffer periodically.
public final class RinaLinkDecoder {
    private var storage = Data()
    private var readOffset = 0

    /// Incremented each time `feed` performs a partial compaction
    /// (`removeSubrange`, as opposed to a full drain). Test-only hook.
    var compactionCountForTesting = 0

    public init() {}

    /// Feeds newly received bytes, returning any frames that became complete.
    public func feed(_ data: Data) -> [RinaLinkFrame] {
        storage.append(data)
        var frames: [RinaLinkFrame] = []

        while true {
            let count = storage.count
            guard readOffset < count else {
                readOffset = count
                break
            }

            let foundIndex = Self.indexOfMagic(in: storage, from: readOffset, count: count)

            guard let magicIndex = foundIndex else {
                readOffset = count
                break
            }
            readOffset = magicIndex

            guard count - readOffset >= RinaLinkFrameConstants.headerBytes else { break }

            var type: UInt8 = 0
            var seq: UInt8 = 0
            var flags: UInt8 = 0
            var length = 0
            storage.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                let header = base + readOffset
                type = header[1]
                seq = header[2]
                flags = header[3]
                length = Int(header[4]) | (Int(header[5]) << 8)
            }

            guard length <= RinaLinkFrameConstants.maxPayloadBytes else {
                // Corrupt length field; drop the magic byte and resync from the next one.
                readOffset += 1
                continue
            }

            let total = RinaLinkFrameConstants.headerBytes + length
            guard count - readOffset >= total else { break }

            let base = storage.startIndex
            let payload = storage.subdata(
                in: (base + readOffset + RinaLinkFrameConstants.headerBytes)..<(base + readOffset + total)
            )
            frames.append(RinaLinkFrame(type: type, seq: seq, flags: flags, payload: payload))
            readOffset += total
        }

        if readOffset == storage.count {
            storage.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= 16_384 && readOffset * 2 >= storage.count {
            storage.removeSubrange(storage.startIndex..<(storage.startIndex + readOffset))
            readOffset = 0
            compactionCountForTesting += 1
        }

        return frames
    }

    public func reset() {
        storage.removeAll()
        readOffset = 0
    }

    /// Returns the offset (relative to `data`'s start) of the next magic byte
    /// at or after `start`, or `nil` if none is present in `data[start..<count]`.
    private static func indexOfMagic(in data: Data, from start: Int, count: Int) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let searchLength = count - start
            guard let match = memchr(base + start, Int32(RinaLinkFrameConstants.magic), searchLength) else {
                return nil
            }
            let matchOffset = UnsafeRawPointer(match) - UnsafeRawPointer(base)
            return matchOffset
        }
    }
}
