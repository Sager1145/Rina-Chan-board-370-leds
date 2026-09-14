import Foundation
import XCTest
import Darwin
import RinaCore
@testable import RinaBoard

// Shared harness for the Stress*Tests suites (stress run 20260912-211559).
// Everything here is test-only: a controllable fake board, memory probes,
// reflection into private BoardConnection state, and a one-line-per-case
// metrics recorder ("STRESSCASE {json}") that the run scripts turn into CSV.

final class StressBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

struct StressRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Stress {
    static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since start: UInt64) -> Double { Double(nowNs() &- start) / 1_000_000 }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    static func mib(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
    static func mibDelta(_ a: UInt64, _ b: UInt64) -> Double { (Double(b) - Double(a)) / 1_048_576 }

    // MARK: Reflection into private state (read-only)

    static func reflect(_ subject: Any, _ name: String) -> Any? {
        for child in Mirror(reflecting: subject).children
        where child.label == name || child.label == "_" + name {
            return child.value
        }
        return nil
    }

    static func count(_ value: Any?) -> Int {
        guard let value else { return -1 }
        if let collection = value as? any Collection { return collection.count }
        return -1
    }

    @MainActor static func pendingCount(_ c: BoardConnection) -> Int { count(reflect(c, "pending")) }
    @MainActor static func quarantined(_ c: BoardConnection) -> Set<UInt8> { reflect(c, "quarantinedSeqs") as? Set<UInt8> ?? [] }
    @MainActor static func nextSeq(_ c: BoardConnection) -> UInt8 { reflect(c, "nextSeq") as? UInt8 ?? 0 }
    @MainActor static func eventSubscriberCount(_ c: BoardConnection) -> Int { count(reflect(c, "eventContinuations")) }
    @MainActor static func operationsCount(_ o: BoardPlaybackCoordinator) -> Int { count(reflect(o, "operations")) }

    /// Sum of `PendingRequest.accumulated` sizes across all pending requests.
    @MainActor static func accumulatedBytes(_ c: BoardConnection) -> Int {
        guard let dict = reflect(c, "pending") else { return -1 }
        var total = 0
        for entry in Mirror(reflecting: dict).children {
            guard let value = reflect(entry.value, "value"),
                  let data = reflect(value, "accumulated") as? Data else { continue }
            total += data.count
        }
        return total
    }

    // MARK: Waiting

    @MainActor
    static func wait(timeout: TimeInterval, poll: UInt64 = 1_000_000, _ condition: () -> Bool) async -> Bool {
        let deadline = nowNs() + UInt64(timeout * 1_000_000_000)
        while !condition() {
            if nowNs() > deadline { return condition() }
            try? await Task.sleep(nanoseconds: poll)
        }
        return true
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return -1 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }

    static func setFrameReason(_ frame: RinaLinkFrame) -> String {
        let bytes = [UInt8](frame.payload)
        guard bytes.count >= 2 else { return "" }
        let length = Int(bytes[1])
        guard bytes.count >= 2 + length else { return "" }
        return String(decoding: bytes[2..<(2 + length)], as: UTF8.self)
    }

    static func setFramePacked(_ frame: RinaLinkFrame) -> PackedFrame? {
        let bytes = [UInt8](frame.payload)
        guard bytes.count >= 2 else { return nil }
        let start = 2 + Int(bytes[1])
        guard bytes.count == start + PackedFrame.byteCount else { return nil }
        return PackedFrame(bytes: Array(bytes[start...]))
    }

    static func json(_ frame: RinaLinkFrame) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]) ?? [:]
    }

    // MARK: Recording

    static func record(case id: String, layer: String, load: String, seed: String = "-",
                       status: String, metrics: [String: Any], evidence: String) {
        let object: [String: Any] = [
            "case_id": id, "layer": layer, "load": load, "seed": seed,
            "status": status, "metrics": sanitize(metrics), "evidence": evidence,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let line = String(decoding: data, as: UTF8.self)
        print("STRESSCASE " + line)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stress", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cases.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as Double:
            guard d.isFinite else { return String(describing: d) }
            return (d * 1000).rounded() / 1000
        case let dict as [String: Any]:
            return dict.mapValues { sanitize($0) }
        case let array as [Any]:
            return array.map { sanitize($0) }
        case is Int, is String, is Bool, is UInt64, is UInt8:
            return value
        default:
            return String(describing: value)
        }
    }
}

/// Fake board. Decodes everything written with its own `RinaLinkDecoder`
/// (the board-side parser), records each parsed frame with a timestamp, and
/// either replies automatically or holds the request for the test to answer.
@MainActor
final class StressTransport: @MainActor RinaTransport {
    struct Write {
        let frame: RinaLinkFrame
        let atNs: UInt64
    }

    enum Fault {
        case throwBeforeWrite
        case silentDrop
        case shortWrite(Int)
        case disconnectMidFrame(Int)
    }

    let kind: TransportKind
    var preferredChunkBytes = 512
    var autoReply = true
    /// Types answered automatically even while `autoReply` is false.
    var autoReplyTypes: Set<UInt8> = []
    var replyDelayMs: Double = 0
    var responder: ((RinaLinkFrame) -> [RinaLinkFrame]?)?
    var holdWrites = false
    var chunkedWriteBytes = 0
    var serializeWrites = false
    var pendingFault: (types: Set<UInt8>?, fault: Fault)?

    private(set) var writes: [Write] = []
    private(set) var held: [RinaLinkFrame] = []
    private(set) var wireBytes = 0
    private(set) var connectCount = 0
    private(set) var connectWriteIndex: [Int] = []
    private(set) var disconnectCount = 0
    private(set) var sendCalls = 0
    private(set) var maxConcurrentSends = 0
    private var concurrentSends = 0
    private var heldWrites: [CheckedContinuation<Void, Never>] = []
    private let boardDecoder = RinaLinkDecoder()
    private let writePump = RatePump(minInterval: 0, depth: 255)
    private var incoming: AsyncStream<Data>.Continuation?
    private var states: AsyncStream<TransportState>.Continuation?

    init(kind: TransportKind = .bluetooth) { self.kind = kind }

    func stateStream() -> AsyncStream<TransportState> { AsyncStream { self.states = $0 } }
    func incomingStream() -> AsyncStream<Data> { AsyncStream { self.incoming = $0 } }
    var currentIncoming: AsyncStream<Data>.Continuation? { incoming }

    func connect() async throws {
        connectCount += 1
        connectWriteIndex.append(writes.count)
        boardDecoder.reset()
        states?.yield(.connected)
    }

    func disconnect() {
        disconnectCount += 1
        states?.yield(.disconnected)
    }

    func emit(_ state: TransportState) { states?.yield(state) }
    func injectRaw(_ data: Data) { incoming?.yield(data) }
    func inject(_ frame: RinaLinkFrame) { incoming?.yield(RinaLinkEncoder.encode(frame)) }

    func reply(to request: RinaLinkFrame, payload: Data, flags: UInt8 = 0) {
        inject(RinaLinkFrame(type: request.type | 0x80, seq: request.seq, flags: flags, payload: payload))
    }

    func resetRecords() {
        writes.removeAll()
        held.removeAll()
        sendCalls = 0
        wireBytes = 0
        maxConcurrentSends = 0
        connectWriteIndex.removeAll()
    }

    var heldWriteWaiters: Int { heldWrites.count }

    func releaseWrites() {
        let waiters = heldWrites
        heldWrites.removeAll()
        waiters.forEach { $0.resume() }
    }

    func clearHeld() { held.removeAll() }

    func takeHeld(_ predicate: (RinaLinkFrame) -> Bool) -> RinaLinkFrame? {
        guard let index = held.firstIndex(where: predicate) else { return nil }
        return held.remove(at: index)
    }

    @discardableResult
    func replyHeld(_ predicate: (RinaLinkFrame) -> Bool, payload: Data? = nil) -> Bool {
        guard let frame = takeHeld(predicate) else { return false }
        reply(to: frame, payload: payload ?? defaultPayload(frame))
        return true
    }

    func replyAllHeld() {
        let frames = held
        held.removeAll()
        for frame in frames { reply(to: frame, payload: defaultPayload(frame)) }
    }

    func writes(of type: RinaLinkMessageType) -> [Write] {
        writes.filter { $0.frame.type == type.rawValue }
    }

    func send(_ data: Data) async throws {
        sendCalls += 1
        if serializeWrites {
            try await writePump.run { @MainActor in try await self.performSend(data) }
        } else {
            try await performSend(data)
        }
    }

    private func performSend(_ data: Data) async throws {
        concurrentSends += 1
        maxConcurrentSends = max(maxConcurrentSends, concurrentSends)
        defer { concurrentSends -= 1 }
        if holdWrites {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                heldWrites.append(continuation)
            }
        }
        try Task.checkCancellation()
        let bytes = [UInt8](data)
        if let fault = pendingFault, fault.types == nil || (bytes.count > 1 && fault.types!.contains(bytes[1])) {
            pendingFault = nil
            switch fault.fault {
            case .throwBeforeWrite:
                throw RinaTransportError.notConnected
            case .silentDrop:
                return
            case .shortWrite(let n):
                board(Data(bytes.prefix(n)))
                throw RinaTransportError.underlying("short write")
            case .disconnectMidFrame(let n):
                board(Data(bytes.prefix(n)))
                states?.yield(.disconnected)
                throw RinaTransportError.notConnected
            }
        }
        if chunkedWriteBytes > 0 {
            var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + chunkedWriteBytes)
                board(Data(bytes[offset..<end]))
                offset = end
                if offset < bytes.count { await Task.yield() }
            }
        } else {
            board(data)
        }
    }

    private func board(_ bytes: Data) {
        wireBytes += bytes.count
        for frame in boardDecoder.feed(bytes) {
            writes.append(Write(frame: frame, atNs: Stress.nowNs()))
            guard autoReply || autoReplyTypes.contains(frame.type) else {
                held.append(frame)
                continue
            }
            let replies = responder?(frame)
                ?? [RinaLinkFrame(type: frame.type | 0x80, seq: frame.seq, flags: 0, payload: defaultPayload(frame))]
            if replyDelayMs > 0 {
                let delay = UInt64(replyDelayMs * 1_000_000)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delay)
                    for reply in replies { self?.inject(reply) }
                }
            } else {
                for reply in replies { inject(reply) }
            }
        }
    }

    func defaultPayload(_ frame: RinaLinkFrame) -> Data {
        switch RinaLinkMessageType(rawValue: frame.type) {
        case .ping:
            return frame.payload
        case .getFrame:
            return PackedFrame().data
        case .blobBegin:
            return Data(#"{"ok":true,"offset":0,"chunkMax":4032}"#.utf8)
        case .blobChunk:
            let b = [UInt8](frame.payload)
            guard b.count >= 4 else { return Data(#"{"ok":true}"#.utf8) }
            let offset = Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24)
            return Data("{\"ok\":true,\"offset\":\(offset + b.count - 4)}".utf8)
        default:
            return Data(#"{"ok":true}"#.utf8)
        }
    }
}

@MainActor
func stressConnected(_ transport: StressTransport, reconnectDelay: TimeInterval = 0.01,
                     file: StaticString = #filePath, line: UInt = #line) async -> BoardConnection {
    let connection = BoardConnection(reconnectDelay: { _ in reconnectDelay }, handshakeTimeout: 2)
    let ok = await connection.connect(using: transport)
    XCTAssertTrue(ok, "stress harness failed to connect", file: file, line: line)
    transport.resetRecords()
    return connection
}
