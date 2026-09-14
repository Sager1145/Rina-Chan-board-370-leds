import XCTest
@testable import RinaCore

// MARK: - Reference decoder (verbatim copy of the pre-cursor implementation,
// git HEAD e7a0a5c, ios/Packages/RinaCore/Sources/RinaCore/RinaLinkCodec.swift).
// Kept here only to differentially fuzz against the cursor-based decoder.

final class ReferenceRinaLinkDecoder {
    private var buffer = Data()

    init() {}

    func feed(_ data: Data) -> [RinaLinkFrame] {
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

    func reset() {
        buffer.removeAll()
    }
}

// MARK: - Deterministic RNG

struct RinaLinkFuzzRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        Int(next() % UInt64(range.upperBound - range.lowerBound + 1)) + range.lowerBound
    }

    mutating func nextByte() -> UInt8 {
        UInt8(next() & 0xFF)
    }
}

// MARK: - Stream construction helpers

private let payloadSizeChoices = [0, 1, 5, 47, 300, 4095, 4096]

private func makeValidFrame(rng: inout RinaLinkFuzzRNG) -> Data {
    let size = payloadSizeChoices.randomElement(using: &rng)!
    var payload = Data(count: size)
    for i in 0..<size {
        payload[payload.startIndex + i] = rng.nextByte()
    }
    let frame = RinaLinkFrame(
        type: rng.nextByte(),
        seq: rng.nextByte(),
        flags: rng.nextByte(),
        payload: payload
    )
    return try! RinaLinkEncoder.encode(frame)
}

private func makeGarbageRun(rng: inout RinaLinkFuzzRNG, includeMagic: Bool) -> Data {
    let length = rng.nextInt(in: 1...20)
    var data = Data(count: length)
    for i in 0..<length {
        var byte = rng.nextByte()
        if !includeMagic {
            while byte == RinaLinkFrameConstants.magic {
                byte = rng.nextByte()
            }
        }
        data[data.startIndex + i] = byte
    }
    if includeMagic {
        // Ensure at least one magic byte is present somewhere in the run.
        let idx = data.startIndex + rng.nextInt(in: 0...(length - 1))
        data[idx] = RinaLinkFrameConstants.magic
    }
    return data
}

private func makeFakeOversizeHeader(rng: inout RinaLinkFuzzRNG) -> Data {
    // magic, type, seq, flags, lenLo, lenHi with length > maxPayloadBytes.
    let badLength = rng.nextInt(in: (RinaLinkFrameConstants.maxPayloadBytes + 1)...70_000)
    var data = Data()
    data.append(RinaLinkFrameConstants.magic)
    data.append(rng.nextByte())
    data.append(rng.nextByte())
    data.append(rng.nextByte())
    data.append(UInt8(badLength & 0xFF))
    data.append(UInt8((badLength >> 8) & 0xFF))
    return data
}

private func makeTruncatedFrame(rng: inout RinaLinkFuzzRNG) -> Data {
    let full = makeValidFrame(rng: &rng)
    guard full.count > 1 else { return full }
    let keep = rng.nextInt(in: 1...(full.count - 1))
    return full.prefix(keep)
}

private func buildRandomStream(rng: inout RinaLinkFuzzRNG, segmentCount: Int) -> Data {
    var stream = Data()
    for _ in 0..<segmentCount {
        let choice = rng.nextInt(in: 0...3)
        switch choice {
        case 0:
            stream.append(makeValidFrame(rng: &rng))
        case 1:
            stream.append(makeGarbageRun(rng: &rng, includeMagic: rng.nextInt(in: 0...1) == 1))
        case 2:
            stream.append(makeFakeOversizeHeader(rng: &rng))
        default:
            stream.append(makeValidFrame(rng: &rng))
        }
    }
    // One truncated frame at the end.
    stream.append(makeTruncatedFrame(rng: &rng))
    return stream
}

/// Feeds `stream` to both decoders in matching chunks, asserting the results
/// agree after every feed call. Optionally resets both decoders partway
/// through at `resetAfterChunk` (an index into the chunk sequence).
///
/// When `useDirectSlices` is true, chunks are passed as `Data` subrange
/// slices of `stream` (which generally have a nonzero `startIndex`) instead
/// of zero-based copies from `subdata(in:)`. This exercises decoder inputs
/// shaped like the slices BLE/networking APIs commonly hand back.
@discardableResult
private func assertDecodersAgree(
    stream: Data,
    chunking: [Int],
    resetAfterChunk: Int? = nil,
    useDirectSlices: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line
) -> (referenceFrameCount: Int, cursorFrameCount: Int) {
    let reference = ReferenceRinaLinkDecoder()
    let cursor = RinaLinkDecoder()

    var offset = stream.startIndex
    var chunkIndex = 0
    var referenceCount = 0
    var cursorCount = 0

    func makeChunk(_ range: Range<Data.Index>) -> Data {
        useDirectSlices ? stream[range] : stream.subdata(in: range)
    }

    for size in chunking {
        guard offset < stream.endIndex else { break }
        let end = min(offset + size, stream.endIndex)
        let chunk = makeChunk(offset..<end)
        offset = end

        let refFrames = reference.feed(chunk)
        let curFrames = cursor.feed(chunk)

        XCTAssertEqual(refFrames, curFrames, "mismatch at chunk \(chunkIndex)", file: file, line: line)
        for frame in curFrames {
            XCTAssertEqual(frame.payload.startIndex, 0, "payload not zero-based", file: file, line: line)
        }
        referenceCount += refFrames.count
        cursorCount += curFrames.count

        if let resetAfterChunk, chunkIndex == resetAfterChunk {
            reference.reset()
            cursor.reset()
        }
        chunkIndex += 1
    }

    // Feed any remaining stream in one go if chunking ran out.
    if offset < stream.endIndex {
        let remaining = makeChunk(offset..<stream.endIndex)
        let refFrames = reference.feed(remaining)
        let curFrames = cursor.feed(remaining)
        XCTAssertEqual(refFrames, curFrames, "mismatch on remainder", file: file, line: line)
        for frame in curFrames {
            XCTAssertEqual(frame.payload.startIndex, 0, "payload not zero-based", file: file, line: line)
        }
        referenceCount += refFrames.count
        cursorCount += curFrames.count
    }

    return (referenceCount, cursorCount)
}

private func chunkSizes(for streamLength: Int, mode: Int, rng: inout RinaLinkFuzzRNG) -> [Int] {
    switch mode {
    case 0:
        return Array(repeating: 1, count: streamLength)
    case 1:
        var sizes: [Int] = []
        var remaining = streamLength
        while remaining > 0 {
            let size = min(remaining, rng.nextInt(in: 1...600))
            sizes.append(size)
            remaining -= size
        }
        return sizes
    default:
        return [streamLength]
    }
}

/// Builds a sequence of complete, valid small frames whose encoded bytes sum
/// to exactly `target`. Uses payload size 10 (encoded length 16) for every
/// frame except the last, whose payload is padded to consume the remainder.
private func buildFramesSumming(to target: Int) throws -> Data {
    precondition(target >= 16, "target must fit at least one frame")
    let baseEncodedLength = 16 // 6-byte header + 10-byte payload
    let frameCount = target / baseEncodedLength
    let remainder = target % baseEncodedLength

    var stream = Data()
    for i in 0..<(frameCount - 1) {
        let frame = RinaLinkFrame(type: 0x20, seq: UInt8(i & 0xFF), flags: 0, payload: Data(repeating: 0xCC, count: 10))
        stream.append(try RinaLinkEncoder.encode(frame))
    }
    let lastFrame = RinaLinkFrame(
        type: 0x20,
        seq: UInt8((frameCount - 1) & 0xFF),
        flags: 0,
        payload: Data(repeating: 0xCC, count: 10 + remainder)
    )
    stream.append(try RinaLinkEncoder.encode(lastFrame))

    precondition(stream.count == target, "buildFramesSumming produced \(stream.count) bytes, wanted \(target)")
    return stream
}

final class RinaLinkDecoderDifferentialTests: XCTestCase {

    func testFuzzedStreamsAgreeWithReference() {
        for seed in 0..<500 {
            var rng = RinaLinkFuzzRNG(seed: UInt64(seed) &+ 1)
            let stream = buildRandomStream(rng: &rng, segmentCount: rng.nextInt(in: 5...20))
            let chunkMode = rng.nextInt(in: 0...2)
            let sizes = chunkSizes(for: stream.count, mode: chunkMode, rng: &rng)

            let doReset = rng.nextInt(in: 0...4) == 0
            let resetAfter = doReset && !sizes.isEmpty ? rng.nextInt(in: 0...(sizes.count - 1)) : nil
            let useDirectSlices = rng.nextInt(in: 0...2) == 0

            assertDecodersAgree(
                stream: stream,
                chunking: sizes,
                resetAfterChunk: resetAfter,
                useDirectSlices: useDirectSlices
            )
        }
    }

    func testFrameSplitAcrossThreeFeeds() throws {
        let frame = RinaLinkFrame(type: 0x10, seq: 1, flags: 0, payload: Data(repeating: 0x42, count: 47))
        let encoded = try RinaLinkEncoder.encode(frame)
        let cut1 = 2
        let cut2 = encoded.count - 3
        let chunks = [
            encoded.prefix(cut1),
            encoded[(encoded.startIndex + cut1)..<(encoded.startIndex + cut2)],
            encoded.suffix(from: encoded.startIndex + cut2),
        ]

        let reference = ReferenceRinaLinkDecoder()
        let cursor = RinaLinkDecoder()
        var refAll: [RinaLinkFrame] = []
        var curAll: [RinaLinkFrame] = []
        for chunk in chunks {
            refAll.append(contentsOf: reference.feed(Data(chunk)))
            curAll.append(contentsOf: cursor.feed(Data(chunk)))
        }
        XCTAssertEqual(refAll, curAll)
        XCTAssertEqual(curAll.count, 1)
        XCTAssertEqual(curAll[0].payload.startIndex, 0)
    }

    func testTwoFramesInOneFeed() throws {
        let f1 = try RinaLinkEncoder.encode(RinaLinkFrame(type: 0x01, seq: 1, flags: 0, payload: Data([1, 2, 3])))
        let f2 = try RinaLinkEncoder.encode(RinaLinkFrame(type: 0x02, seq: 2, flags: 0, payload: Data()))
        var combined = f1
        combined.append(f2)

        let reference = ReferenceRinaLinkDecoder()
        let cursor = RinaLinkDecoder()
        let refFrames = reference.feed(combined)
        let curFrames = cursor.feed(combined)
        XCTAssertEqual(refFrames, curFrames)
        XCTAssertEqual(curFrames.count, 2)
    }

    func testBadLengthFollowedByValidFrame() throws {
        var stream = Data()
        stream.append(RinaLinkFrameConstants.magic)
        stream.append(0x00)
        stream.append(0x00)
        stream.append(0x00)
        stream.append(0xFF) // length low byte
        stream.append(0xFF) // length high byte -> huge length, > max
        stream.append(try RinaLinkEncoder.encode(RinaLinkFrame(type: 0x05, seq: 9, flags: 0, payload: Data([9, 9]))))

        let reference = ReferenceRinaLinkDecoder()
        let cursor = RinaLinkDecoder()
        let refFrames = reference.feed(stream)
        let curFrames = cursor.feed(stream)
        XCTAssertEqual(refFrames, curFrames)
        XCTAssertEqual(curFrames.count, 1)
        XCTAssertEqual(curFrames[0].seq, 9)
    }

    func testTwentyKilobyteGarbagePrefixWithNoValidFrameThenOneFrame() throws {
        var garbage = Data(count: 20 * 1024)
        var rng = RinaLinkFuzzRNG(seed: 99)
        for i in 0..<garbage.count {
            var byte = rng.nextByte()
            while byte == RinaLinkFrameConstants.magic {
                byte = rng.nextByte()
            }
            garbage[garbage.startIndex + i] = byte
        }
        let frame = try RinaLinkEncoder.encode(RinaLinkFrame(type: 0x07, seq: 3, flags: 0, payload: Data(repeating: 0x5A, count: 128)))
        var stream = garbage
        stream.append(frame)

        let reference = ReferenceRinaLinkDecoder()
        let cursor = RinaLinkDecoder()

        // Feed in 4096-byte chunks. No valid frame is found until the very end,
        // so each feed fully drains its buffer (readOffset == storage.count)
        // rather than exercising the partial `removeSubrange` compaction path.
        var offset = stream.startIndex
        var refAll: [RinaLinkFrame] = []
        var curAll: [RinaLinkFrame] = []
        while offset < stream.endIndex {
            let end = min(offset + 4096, stream.endIndex)
            let chunk = stream.subdata(in: offset..<end)
            offset = end
            refAll.append(contentsOf: reference.feed(chunk))
            curAll.append(contentsOf: cursor.feed(chunk))
        }
        XCTAssertEqual(refAll, curAll)
        XCTAssertEqual(curAll.count, 1)
        XCTAssertEqual(curAll[0].payload.count, 128)
        XCTAssertEqual(curAll[0].payload.startIndex, 0)
    }

    func testTenThousandSequentialSmallFramesThenOneMoreFrameSplitAcrossFeeds() throws {
        let reference = ReferenceRinaLinkDecoder()
        let cursor = RinaLinkDecoder()

        var refTotal = 0
        var curTotal = 0
        for i in 0..<10_000 {
            let frame = RinaLinkFrame(type: 0x08, seq: UInt8(i & 0xFF), flags: 0, payload: Data([UInt8(i & 0xFF)]))
            let encoded = try RinaLinkEncoder.encode(frame)
            let refFrames = reference.feed(encoded)
            let curFrames = cursor.feed(encoded)
            XCTAssertEqual(refFrames, curFrames)
            refTotal += refFrames.count
            curTotal += curFrames.count
        }
        XCTAssertEqual(refTotal, 10_000)
        XCTAssertEqual(curTotal, 10_000)

        // Each of the 10_000 single-frame feeds above fully drains its buffer
        // (readOffset == storage.count), so this reaches the loop 10_000 times
        // without ever exercising partial compaction; see
        // testPartialCompactionAtThresholds for that. Here we just confirm a
        // frame split across two more feeds still decodes correctly afterward.
        let finalFrame = try RinaLinkEncoder.encode(RinaLinkFrame(type: 0x09, seq: 1, flags: 0, payload: Data(repeating: 0x11, count: 4096)))
        let mid = finalFrame.count / 2
        let part1 = finalFrame.prefix(mid)
        let part2 = finalFrame.suffix(from: finalFrame.startIndex + mid)

        let refFrames1 = reference.feed(Data(part1))
        let curFrames1 = cursor.feed(Data(part1))
        XCTAssertEqual(refFrames1, curFrames1)
        XCTAssertEqual(curFrames1.count, 0)

        let refFrames2 = reference.feed(Data(part2))
        let curFrames2 = cursor.feed(Data(part2))
        XCTAssertEqual(refFrames2, curFrames2)
        XCTAssertEqual(curFrames2.count, 1)
        XCTAssertEqual(curFrames2[0].payload.startIndex, 0)
    }

    /// Exercises the partial-compaction branch (`removeSubrange`, RinaLinkCodec
    /// ~L136) directly, at and around its 16_384-byte threshold. Neither of
    /// the tests above hits this: both fully drain their buffer every feed.
    func testPartialCompactionAtThresholds() throws {
        for target in [16_383, 16_384, 16_385, 16_390] {
            for k in [1, 5, 6, 2000] {
                let smallFrames = try buildFramesSumming(to: target)
                let bigFrame = try RinaLinkEncoder.encode(
                    RinaLinkFrame(type: 0x30, seq: 42, flags: 0, payload: Data(repeating: 0x77, count: 4096))
                )
                let bigPrefix = bigFrame.prefix(k)

                var firstChunk = smallFrames
                firstChunk.append(bigPrefix)

                let reference = ReferenceRinaLinkDecoder()
                let cursor = RinaLinkDecoder()

                let refFrames0 = reference.feed(firstChunk)
                let curFrames0 = cursor.feed(firstChunk)
                XCTAssertEqual(
                    refFrames0, curFrames0,
                    "mismatch after first combined feed (target=\(target), k=\(k))"
                )
                XCTAssertEqual(
                    curFrames0.count, target / 16,
                    "expected all small frames decoded (target=\(target), k=\(k))"
                )

                if target >= 16_384 {
                    XCTAssertEqual(
                        cursor.compactionCountForTesting, 1,
                        "expected partial compaction to have run (target=\(target), k=\(k))"
                    )
                } else {
                    XCTAssertEqual(
                        cursor.compactionCountForTesting, 0,
                        "did not expect partial compaction to run (target=\(target), k=\(k))"
                    )
                }

                // Feed the rest of the big frame's bytes in 2-3 later chunks.
                let remaining = bigFrame.suffix(from: bigFrame.startIndex + k)
                var rng = RinaLinkFuzzRNG(seed: UInt64(target) &* 7 &+ UInt64(k))
                let pieceCount = remaining.count >= 2 ? rng.nextInt(in: 2...3) : 1
                var pieces: [Data] = []
                var remOffset = remaining.startIndex
                for pieceIndex in 0..<pieceCount {
                    let isLast = pieceIndex == pieceCount - 1
                    let end: Data.Index
                    if isLast {
                        end = remaining.endIndex
                    } else {
                        let maxLen = remaining.endIndex - remOffset - (pieceCount - pieceIndex - 1)
                        let len = maxLen > 1 ? rng.nextInt(in: 1...maxLen) : 1
                        end = min(remOffset + len, remaining.endIndex)
                    }
                    pieces.append(remaining.subdata(in: remOffset..<end))
                    remOffset = end
                    if remOffset >= remaining.endIndex { break }
                }

                var refAll = refFrames0
                var curAll = curFrames0
                for piece in pieces {
                    let refFrames = reference.feed(piece)
                    let curFrames = cursor.feed(piece)
                    XCTAssertEqual(
                        refFrames, curFrames,
                        "mismatch feeding big-frame remainder piece (target=\(target), k=\(k))"
                    )
                    refAll.append(contentsOf: refFrames)
                    curAll.append(contentsOf: curFrames)
                }

                // One more small frame afterward.
                let trailingFrame = try RinaLinkEncoder.encode(
                    RinaLinkFrame(type: 0x31, seq: 7, flags: 0, payload: Data([1, 2, 3]))
                )
                let refFramesTrailing = reference.feed(trailingFrame)
                let curFramesTrailing = cursor.feed(trailingFrame)
                XCTAssertEqual(
                    refFramesTrailing, curFramesTrailing,
                    "mismatch feeding trailing frame (target=\(target), k=\(k))"
                )
                refAll.append(contentsOf: refFramesTrailing)
                curAll.append(contentsOf: curFramesTrailing)

                XCTAssertEqual(curFramesTrailing.count, 1)
                XCTAssertEqual(curFramesTrailing[0].payload, Data([1, 2, 3]))

                // Total frame counts: all small frames + big frame + trailing frame.
                XCTAssertEqual(curAll.count, target / 16 + 2, "target=\(target), k=\(k)")
                for frame in curAll {
                    XCTAssertEqual(frame.payload.startIndex, 0, "payload not zero-based (target=\(target), k=\(k))")
                }
            }
        }
    }
}
