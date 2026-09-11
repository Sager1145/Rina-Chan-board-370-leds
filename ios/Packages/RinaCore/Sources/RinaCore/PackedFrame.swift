import Foundation

/// A 47-byte packed representation of 370 LED bits (M370), logical LED index,
/// LSB-first within each byte: LED `i` lives at byte `i>>3`, mask `1<<(i&7)`.
/// The top 6 bits of byte 46 (bits 370..375) must always be zero.
public struct PackedFrame: Equatable, Hashable, Sendable {
    public static let ledCount = 370
    public static let byteCount = 47

    public private(set) var bytes: [UInt8]

    /// Creates an all-off frame.
    public init() {
        bytes = [UInt8](repeating: 0, count: Self.byteCount)
    }

    /// Creates a frame from exactly 47 bytes. Returns nil if the length or the
    /// tail-bit invariant is violated.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
        guard validate() else { return nil }
    }

    /// Creates a frame from raw bytes without validating (use sparingly, e.g.
    /// while decoding data that will be validated right after).
    public init(unsafeBytes bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount, "PackedFrame requires exactly 47 bytes")
        self.bytes = bytes
    }

    /// Creates a frame from an array of 370 booleans/ints (`0`/non-zero), the
    /// representation used by `saved_faces.json` (`frameBytes` int arrays are
    /// already packed bytes; this initializer is for *bit* arrays of length 370).
    public init?(bits: [Int]) {
        guard bits.count == Self.ledCount else { return nil }
        var out = [UInt8](repeating: 0, count: Self.byteCount)
        for i in 0..<Self.ledCount where bits[i] != 0 {
            out[i >> 3] |= UInt8(1 << (i & 7))
        }
        self.bytes = out
    }

    public subscript(led: Int) -> Bool {
        get {
            guard led >= 0 && led < Self.ledCount else { return false }
            return (bytes[led >> 3] & UInt8(1 << (led & 7))) != 0
        }
        set {
            guard led >= 0 && led < Self.ledCount else { return }
            if newValue {
                bytes[led >> 3] |= UInt8(1 << (led & 7))
            } else {
                bytes[led >> 3] &= ~UInt8(1 << (led & 7))
            }
        }
    }

    public mutating func set(_ led: Int) { self[led] = true }
    public mutating func clear(_ led: Int) { self[led] = false }
    public mutating func toggle(_ led: Int) { self[led] = !self[led] }

    public mutating func invert() {
        for i in 0..<Self.byteCount {
            bytes[i] = ~bytes[i]
        }
        maskTail()
    }

    public mutating func fill() {
        for i in 0..<Self.ledCount { self[i] = true }
    }

    public mutating func clearAll() {
        bytes = [UInt8](repeating: 0, count: Self.byteCount)
    }

    /// OR-composite another frame's set bits into this one (used by the parts composer).
    public mutating func formUnion(_ other: PackedFrame) {
        for i in 0..<Self.byteCount {
            bytes[i] |= other.bytes[i]
        }
    }

    public var litCount: Int {
        var count = 0
        for i in 0..<Self.ledCount where self[i] {
            count += 1
        }
        return count
    }

    /// 47 bytes, top 6 bits of the last byte must be zero.
    public func validate() -> Bool {
        guard bytes.count == Self.byteCount else { return false }
        return (bytes[Self.byteCount - 1] & 0b1111_1100) == 0
    }

    private mutating func maskTail() {
        bytes[Self.byteCount - 1] &= 0b0000_0011
    }

    // MARK: Hex94

    public var hex94: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public init?(hex94 hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == Self.byteCount * 2 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(Self.byteCount)
        var idx = cleaned.startIndex
        for _ in 0..<Self.byteCount {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        self.bytes = out
        guard validate() else { return nil }
    }

    // MARK: Base64

    public var base64: String {
        Data(bytes).base64EncodedString()
    }

    public init?(base64 string: String) {
        guard let data = Data(base64Encoded: string), data.count == Self.byteCount else { return nil }
        self.bytes = [UInt8](data)
        guard validate() else { return nil }
    }

    // MARK: Data

    public var data: Data { Data(bytes) }

    public init?(data: Data) {
        self.init(bytes: [UInt8](data))
    }
}
