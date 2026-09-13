import Foundation
import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class BoardConnectionOutputTests: XCTestCase {
    func testConfiguredNameFollowsBoardSwitchAndDisconnect() async {
        let connection = BoardConnection()
        let first = FakeRinaTransport()
        first.commandReply = ["ok": true, "name": "璃奈一号"]
        let firstConnected = await connection.connect(using: first)
        XCTAssertTrue(firstConnected)
        XCTAssertEqual(connection.deviceName, "璃奈一号")

        let second = FakeRinaTransport()
        second.commandReply = ["ok": true, "name": "璃奈二号"]
        let secondConnected = await connection.connect(using: second)
        XCTAssertTrue(secondConnected)
        XCTAssertEqual(connection.deviceName, "璃奈二号")

        connection.disconnect()
        XCTAssertNil(connection.deviceName)
    }

    func testRenameUpdatesConfiguredNameAndRejectedRenamePreservesIt() async throws {
        let connection = BoardConnection()
        let transport = FakeRinaTransport()
        transport.commandReply = ["ok": true, "name": "原名称"]
        _ = await connection.connect(using: transport)
        transport.commandReply = ["ok": true, "name": "新名称"]
        _ = try await connection.command(.setDeviceName(name: "新名称"))
        XCTAssertEqual(connection.deviceName, "新名称")

        transport.commandReply = ["ok": false, "error": "denied", "name": "错误名称"]
        do {
            _ = try await connection.command(.setDeviceName(name: "错误名称"))
            XCTFail("Expected rejected rename")
        } catch {
            XCTAssertEqual(connection.deviceName, "新名称")
        }
    }

    func testSupersededQueuedFrameDoesNotSendAndLateReplyDoesNotChangeCurrentFrame() async throws {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.automaticallyReplies = false

        var firstFrame = PackedFrame()
        firstFrame.set(1)
        var queuedFrame = PackedFrame()
        queuedFrame.set(2)

        let oldSession = connection.output.begin(.debug)
        let first = Task { @MainActor in
            try await connection.withOutput(oldSession) {
                try await connection.setFrame(firstFrame,
                                              playback: .idle,
                                              reason: "test-first",
                                              outputSession: oldSession)
            }
        }
        try await transport.waitForSent(type: .setFrame, count: 1)

        let queued = Task { @MainActor in
            try await connection.withOutput(oldSession) {
                try await connection.setFrame(queuedFrame,
                                              playback: .idle,
                                              reason: "test-queued",
                                              outputSession: oldSession)
            }
        }
        _ = connection.output.begin(.manual)

        await assertCancelled(first)
        await assertCancelled(queued)
        XCTAssertEqual(transport.sentCount(type: .setFrame), 1)
        XCTAssertEqual(connection.currentFrame, PackedFrame())
    }

    func testCommandRejectsFirmwareReplyWithOkFalse() async throws {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.commandReply = ["ok": false, "error": "denied"]
        let session = connection.output.begin(.debug)

        do {
            _ = try await connection.withOutput(session) {
                try await connection.command(.pauseScroll)
            }
            XCTFail("Expected a rejected command to throw")
        } catch is CancellationError {
            XCTFail("Firmware rejection must not be reported as cancellation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("面板拒绝指令"))
        }
    }

    func testCancellingInflightFrameUnblocksNewSessionAndQuarantinesLateReply() async throws {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.automaticallyReplies = false

        var cancelledFrame = PackedFrame()
        cancelledFrame.set(3)
        let cancelledSession = connection.output.begin(.debug)
        let superseded = Task { @MainActor in
            try await connection.withOutput(cancelledSession) {
                try await connection.setFrame(cancelledFrame,
                                              playback: .idle,
                                              reason: "test-cancelled",
                                              outputSession: cancelledSession)
            }
        }
        try await transport.waitForSent(type: .setFrame, count: 1)

        var replacementFrame = PackedFrame()
        replacementFrame.set(4)
        let replacementSession = connection.output.begin(.manual)
        let replacement = Task { @MainActor in
            try await connection.withOutput(replacementSession) {
                try await connection.setFrame(replacementFrame,
                                              playback: .idle,
                                              reason: "test-replacement",
                                              outputSession: replacementSession)
            }
        }
        await assertCancelled(superseded)
        try await transport.waitForSent(type: .setFrame, count: 2)

        // The cancelled request's late response is ignored; only the second
        // response can complete and publish the replacement frame.
        transport.replyToNext(type: .setFrame, json: ["ok": true])
        transport.replyToNext(type: .setFrame, json: ["ok": true])
        _ = try await replacement.value
        XCTAssertEqual(connection.currentFrame, replacementFrame)
    }

    func testLateCompletionFromSupersededConnectCannotOverwriteNewConnection() async throws {
        let oldTransport = FakeRinaTransport(connectImmediately: false)
        let newTransport = FakeRinaTransport(kind: .wifi(host: "new-board.local", port: 80))
        let connection = BoardConnection()

        let oldConnect = Task { @MainActor in
            await connection.connect(using: oldTransport)
        }
        try await oldTransport.waitForConnectStarted()
        let newConnected = await connection.connect(using: newTransport)
        XCTAssertTrue(newConnected)
        let newGeneration = connection.connectionGeneration

        oldTransport.completeDeferredConnect()

        let oldConnected = await oldConnect.value
        XCTAssertFalse(oldConnected)
        XCTAssertEqual(connection.connectionState, .connected)
        XCTAssertEqual(connection.transportKind, .wifi(host: "new-board.local", port: 80))
        XCTAssertEqual(connection.connectionGeneration, newGeneration)
    }

    func testSupersededOutputCancelsTransportSendQueuedBehindBackPressure() async throws {
        let transport = FakeRinaTransport()
        let connection = BoardConnection()
        let connected = await connection.connect(using: transport)
        XCTAssertTrue(connected)
        transport.automaticallyReplies = false
        transport.resetTransportSendCalls()
        transport.holdNextTransportSend()

        let blocker = Task { @MainActor in
            try await connection.send(type: .ping, payload: Data())
        }
        try await transport.waitForHeldTransportSend()

        var oldFrame = PackedFrame()
        oldFrame.set(5)
        let oldSession = connection.output.begin(.manual)
        let oldOutput = Task { @MainActor in
            try await connection.withOutput(oldSession) {
                try await connection.setFrame(oldFrame,
                                              playback: .idle,
                                              reason: "test-old-backpressured",
                                              outputSession: oldSession)
            }
        }
        try await transport.waitForTransportSendCalls(2)

        var latestFrame = PackedFrame()
        latestFrame.set(6)
        let latestSession = connection.output.begin(.manual)
        let latestOutput = Task { @MainActor in
            try await connection.withOutput(latestSession) {
                try await connection.setFrame(latestFrame,
                                              playback: .idle,
                                              reason: "test-latest-backpressured",
                                              outputSession: latestSession)
            }
        }
        await assertCancelled(oldOutput)

        transport.releaseHeldTransportSend()
        try await transport.waitForSent(type: .setFrame, count: 1)
        XCTAssertEqual(transport.sentCount(type: .setFrame), 1)

        transport.replyToNext(type: .ping, json: ["ok": true])
        transport.replyToNext(type: .setFrame, json: ["ok": true])
        _ = try await blocker.value
        _ = try await latestOutput.value
        XCTAssertEqual(connection.currentFrame, latestFrame)
    }

    func testDirectFramesCancelAcrossEveryModeAndTransport() async throws {
        let kinds: [TransportKind] = [.bluetooth, .wifi(host: "board.local", port: 80), .hotspot]
        let sources: [BoardOutputSource] = [.manual, .automatic, .text, .lipSync, .performance, .debug]
        for kind in kinds {
            let transport = FakeRinaTransport(kind: kind)
            let connection = BoardConnection()
            let connected = await connection.connect(using: transport)
            XCTAssertTrue(connected)
            transport.automaticallyReplies = false
            for (index, source) in sources.enumerated() {
                let session = connection.output.begin(source)
                let old = Task { @MainActor in
                    try await connection.setFrame(PackedFrame(), playback: .idle,
                                                  reason: "direct-frame", outputSession: session)
                }
                try await transport.waitForSent(type: .setFrame, count: index + 1)
                _ = connection.output.begin(sources[(index + 1) % sources.count])
                await assertCancelled(old)
                transport.replyToNext(type: .setFrame, json: ["ok": true])
            }
            connection.disconnect()
        }
    }

    func testCancelledBlobAbortsBeforeNextUploadBeginsOnEveryTransport() async throws {
        for kind: TransportKind in [.bluetooth, .wifi(host: "board.local", port: 80), .hotspot] {
            let transport = FakeRinaTransport(kind: kind)
            let connection = BoardConnection()
            let connected = await connection.connect(using: transport)
            XCTAssertTrue(connected)
            transport.automaticallyReplies = false
            let session = connection.output.begin(.text)
            let old = Task { @MainActor in
                try await BoardOutputContext.$session.withValue(session) {
                    try await connection.uploadBlob(kind: .scroll, meta: [:], data: Data(repeating: 0, count: 47))
                }
            }
            try await transport.waitForSent(type: .blobBegin, count: 1)
            // Even a lost BEGIN reply may have allocated the device's blob owner.
            let nextSession = connection.output.begin(.text)
            let next = Task { @MainActor in
                try await BoardOutputContext.$session.withValue(nextSession) {
                    try await connection.uploadBlob(kind: .scroll, meta: [:], data: Data(repeating: 0, count: 47))
                }
            }
            try await transport.waitForSent(type: .blobAbort, count: 1)
            XCTAssertEqual(transport.sentCount(type: .blobBegin), 1)
            transport.replyToNext(type: .blobAbort, json: ["ok": true])
            await assertCancelled(old)
            try await transport.waitForSent(type: .blobBegin, count: 2)
            transport.replyToNext(type: .blobBegin, json: ["ok": true, "offset": 0])
            transport.replyToNext(type: .blobBegin, json: ["ok": true, "offset": 0])
            try await transport.waitForSent(type: .blobChunk, count: 1)
            transport.replyToNext(type: .blobChunk, json: ["ok": true, "offset": 47])
            try await transport.waitForSent(type: .blobEnd, count: 1)
            transport.replyToNext(type: .blobEnd, json: ["ok": true])
            _ = try await next.value
            connection.disconnect()
        }
    }

    func testCancelledChunkReleasesEveryBlobKind() async throws {
        for kind: BoardConnection.BlobKind in [.scroll, .scrollBitmap, .faces] {
            let transport = FakeRinaTransport()
            let connection = BoardConnection()
            let connected = await connection.connect(using: transport)
            XCTAssertTrue(connected)
            transport.automaticallyReplies = false
            let session = connection.output.begin(.text)
            let upload = Task { @MainActor in
                try await BoardOutputContext.$session.withValue(session) {
                    try await connection.uploadBlob(kind: kind, meta: [:], data: Data(repeating: 0, count: 47))
                }
            }
            try await transport.waitForSent(type: .blobBegin, count: 1)
            transport.replyToNext(type: .blobBegin, json: ["ok": true, "offset": 0])
            try await transport.waitForSent(type: .blobChunk, count: 1)
            _ = connection.output.begin(.performance)
            try await transport.waitForSent(type: .blobAbort, count: 1)
            transport.replyToNext(type: .blobAbort, json: ["ok": true])
            await assertCancelled(upload)
            XCTAssertEqual(transport.sentCount(type: .blobEnd), 0)
            XCTAssertEqual(connection.connectionState, .connected)
            connection.disconnect()
        }
    }

    func testTCPSendCompletionHandlesCancellationBeforeAndAfterRegistration() async {
        for cancelFirst in [true, false] {
            let completion = TCPSendCompletion()
            if cancelFirst { completion.finish(.failure(CancellationError())) }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    _ = completion.install(continuation)
                    completion.finish(.failure(CancellationError()))
                    // A delayed Network.framework callback cannot resume twice.
                    completion.finish(.success(()))
                }
                XCTFail("Expected cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTCPTimeoutCleanupFinishesBeforeConcurrentContinuationRegistrationResumes() async {
        let completion = TCPSendCompletion()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completion.finish(.failure(RinaTransportError.timeout), beforeResume: {
                    XCTAssertTrue(completion.install(continuation),
                                  "Registration during socket close must wait until close finishes")
                })
            }
            XCTFail("Expected timeout")
        } catch RinaTransportError.timeout {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTCPSubmittedWriteKeepsPermitWhileCancelledQueuedWritesAreDiscarded() async throws {
        let queue = TCPWriteQueue()
        let wire = HeldTCPWrites()
        let first = Task {
            try await queue.send(timeout: 2, onTimeout: {}) { wire.submit($0) }
        }
        try await wire.waitForCount(1)
        first.cancel()
        for _ in 0..<40 {
            let stale = Task {
                try await queue.send(timeout: 2, onTimeout: {}) { wire.submit($0) }
            }
            stale.cancel()
            await assertCancelled(stale)
        }
        let latest = Task {
            try await queue.send(timeout: 2, onTimeout: {}) { wire.submit($0) }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(wire.count, 1, "Cancelling the submitted write must not release its permit")
        wire.completeFirst()
        await assertCancelled(first)
        try await wire.waitForCount(2)
        wire.completeFirst()
        try await latest.value
        XCTAssertEqual(wire.count, 2)
    }

    func testTCPWriteDeadlineClosesBeforeReleasingPermit() async throws {
        let queue = TCPWriteQueue()
        let wire = HeldTCPWrites()
        let first = Task {
            try await queue.send(timeout: 0.05, onTimeout: { wire.closed() }) { wire.submit($0) }
        }
        try await wire.waitForCount(1)
        let next = Task {
            try await queue.send(timeout: 2, onTimeout: {}) { wire.submit($0) }
        }
        do {
            try await first.value
            XCTFail("Expected TCP write timeout")
        } catch RinaTransportError.timeout {
        }
        try await wire.waitForCount(2)
        XCTAssertEqual(wire.events, ["submit", "close", "submit"])
        // The timed-out write can still report completion, without affecting
        // either its former permit or the replacement write's continuation.
        wire.completeFirst()
        wire.completeFirst()
        try await next.value
    }

    private func assertCancelled<T>(_ task: Task<T, Error>,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
        }
    }
}

@MainActor
final class FakeRinaTransport: @MainActor RinaTransport {
    let kind: TransportKind
    let preferredChunkBytes = 512
    var automaticallyReplies = true
    var commandReply: [String: Any] = ["ok": true]
    private let connectImmediately: Bool
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var connectStarted = false

    private let decoder = RinaLinkDecoder()
    private let sendPump = RatePump(minInterval: 0, depth: 255)
    private var sent: [RinaLinkFrame] = []
    private var heldRequests: [RinaLinkFrame] = []
    private var incomingContinuation: AsyncStream<Data>.Continuation?
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var transportSendCalls = 0
    private var shouldHoldNextTransportSend = false
    private var heldTransportSendContinuation: CheckedContinuation<Void, Never>?

    init(kind: TransportKind = .bluetooth, connectImmediately: Bool = true) {
        self.kind = kind
        self.connectImmediately = connectImmediately
    }

    func stateStream() -> AsyncStream<TransportState> {
        AsyncStream { stateContinuation = $0 }
    }

    func incomingStream() -> AsyncStream<Data> {
        AsyncStream { incomingContinuation = $0 }
    }

    func connect() async throws {
        connectStarted = true
        if !connectImmediately {
            await withCheckedContinuation { connectContinuation = $0 }
        }
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
    }

    func send(_ data: Data) async throws {
        transportSendCalls += 1
        try await sendPump.run { @MainActor in
            if self.shouldHoldNextTransportSend {
                self.shouldHoldNextTransportSend = false
                await withCheckedContinuation { self.heldTransportSendContinuation = $0 }
            }
            try Task.checkCancellation()
            for request in self.decoder.feed(data) {
                self.sent.append(request)
                if self.automaticallyReplies {
                    self.reply(request, payload: self.defaultPayload(for: request))
                } else {
                    self.heldRequests.append(request)
                }
            }
        }
    }

    func holdNextTransportSend() {
        shouldHoldNextTransportSend = true
    }

    func resetTransportSendCalls() {
        transportSendCalls = 0
    }

    func releaseHeldTransportSend() {
        heldTransportSendContinuation?.resume()
        heldTransportSendContinuation = nil
    }

    func waitForHeldTransportSend() async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if heldTransportSendContinuation != nil { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw FakeTransportError.timedOutWaitingForSend
    }

    func waitForTransportSendCalls(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if transportSendCalls >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw FakeTransportError.timedOutWaitingForSend
    }

    func sentCount(type: RinaLinkMessageType) -> Int {
        sent.count { $0.type == type.rawValue }
    }

    func waitForSent(type: RinaLinkMessageType, count: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if sentCount(type: type) >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw FakeTransportError.timedOutWaitingForSend
    }

    func waitForConnectStarted() async throws {
        for _ in 0..<1_000 {
            if connectStarted { return }
            await Task.yield()
        }
        throw FakeTransportError.timedOutWaitingForConnect
    }

    func completeDeferredConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func replyToNext(type: RinaLinkMessageType, json: [String: Any]) {
        guard let index = heldRequests.firstIndex(where: { $0.type == type.rawValue }) else {
            XCTFail("No held \(type) request")
            return
        }
        let request = heldRequests.remove(at: index)
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        reply(request, payload: payload)
    }

    private func defaultPayload(for request: RinaLinkFrame) -> Data {
        if request.type == RinaLinkMessageType.cmd.rawValue {
            return (try? JSONSerialization.data(withJSONObject: commandReply)) ?? Data()
        }
        if request.type == RinaLinkMessageType.setFrame.rawValue {
            return Data(#"{"ok":true}"#.utf8)
        }
        return Data(#"{"ok":true}"#.utf8)
    }

    private func reply(_ request: RinaLinkFrame, payload: Data) {
        incomingContinuation?.yield(RinaLinkEncoder.encode(
            RinaLinkFrame(type: request.type | 0x80,
                          seq: request.seq,
                          flags: 0,
                          payload: payload)
        ))
    }
}

private enum FakeTransportError: Error {
    case timedOutWaitingForSend
    case timedOutWaitingForConnect
}

private final class HeldTCPWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (Result<Void, Error>) -> Void] = []
    private var submitted = 0
    private var recordedEvents: [String] = []
    var count: Int { lock.withLock { submitted } }
    var events: [String] { lock.withLock { recordedEvents } }
    func submit(_ callback: @escaping @Sendable (Result<Void, Error>) -> Void) {
        lock.withLock {
            submitted += 1
            recordedEvents.append("submit")
            callbacks.append(callback)
        }
    }
    func closed() { lock.withLock { recordedEvents.append("close") } }
    func completeFirst() {
        let callback = lock.withLock { callbacks.removeFirst() }
        callback(.success(()))
    }
    func waitForCount(_ expected: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if count >= expected { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw FakeTransportError.timedOutWaitingForSend
    }
}
