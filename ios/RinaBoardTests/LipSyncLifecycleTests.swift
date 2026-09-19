import XCTest
import RinaCore
@testable import RinaBoard

@MainActor
final class LipSyncLifecycleTests: XCTestCase {
    func testReopenedModelResumesTheSameLipSyncStream() async throws {
        let suite = "LipSyncResume-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = BoardConnection()
        _ = await connection.connect(using: FakeRinaTransport())
        defer { connection.disconnect() }
        let original = LipSyncModel(defaults: defaults, capture: TestMicrophone(), permissionRequest: { .granted })
        original.setSyncEyes(true)
        original.setCostumePart("0", for: .cheek)
        original.sensitivityDb = -45
        await original.start(connection: connection)
        let streamID = try XCTUnwrap(defaults.string(forKey: "lipSyncStreamID"))
        original.stop()

        let capture = TestMicrophone()
        let reopened = LipSyncModel(defaults: defaults, capture: capture, permissionRequest: { .granted })
        XCTAssertEqual(reopened.baseCall, original.baseCall)
        XCTAssertTrue(reopened.syncEyes)
        XCTAssertEqual(reopened.sensitivityDb, -45)
        defer { reopened.stop() }
        await reopened.start(connection: connection, resumingStreamID: streamID)
        XCTAssertTrue(reopened.isRunning)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(defaults.string(forKey: "lipSyncStreamID"), streamID)
    }

    func testForeignLipSyncStreamDoesNotStartTheMicrophone() async {
        let connection = BoardConnection()
        _ = await connection.connect(using: FakeRinaTransport())
        defer { connection.disconnect() }
        let capture = TestMicrophone()
        let model = LipSyncModel(capture: capture, permissionRequest: { .granted })
        await model.start(connection: connection, resumingStreamID: UUID().uuidString)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(connection.output.source)
    }

    func testBoardTakeoverDuringResumeDoesNotStartTheMicrophone() async {
        let connection = BoardConnection()
        _ = await connection.connect(using: FakeRinaTransport())
        defer { connection.disconnect() }
        let capture = TestMicrophone()
        let model = LipSyncModel(capture: capture, permissionRequest: { .granted })
        await model.start(connection: connection, shouldStart: { false })
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertNil(connection.output.source)
    }

    func testCalibrationDistinguishesMissingBuffersFromSilentPCM() async throws {
        // Looked up the way the model does, so the simulator's language does not matter.
        for (samples, expected) in [([Float](), String(localized: "麦克风未传入音频数据，请检查输入设备后重新校准")),
                                     ([Float](repeating: 0, count: 4096), String(localized: "麦克风传入的音频全部为静音，请检查输入设备是否被静音"))] {
            let capture = TestMicrophone()
            capture.samples = samples
            let model = LipSyncModel(capture: capture, permissionRequest: { .granted })
            model.calibrate(.a, duration: 0.2)
            let deadline = ContinuousClock.now + .seconds(3)
            while model.isCalibrating && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.errorMessage, expected)
            XCTAssertFalse(model.isCalibrating)
            model.cancelCalibration()
        }
    }

    func testCalibrationReportsMeasuredLevelForQuietNonzeroAudio() async throws {
        let capture = TestMicrophone()
        capture.samples = capture.samples.map { $0 * 0.0001 }
        let model = LipSyncModel(capture: capture, permissionRequest: { .granted })
        model.calibrate(.a, duration: 0.2)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.isCalibrating && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.errorMessage?.hasPrefix("声音不足：最高") == true, model.errorMessage ?? "No error")
        XCTAssertLessThan(model.volumeDb, model.sensitivityDb)
        model.cancelCalibration()
    }

    func testPermissionAlertDoesNotCancelStartAndSamplesReachRecognition() async throws {
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        let capture = TestMicrophone()
        var model: LipSyncModel!
        model = LipSyncModel(capture: capture, permissionRequest: {
            // Repeated inactive notifications from the permission alert
            // must leave the pending start intact.
            model.scenePhaseChanged(.inactive)
            model.scenePhaseChanged(.inactive, connection: connection)
            await Task.yield()
            return .granted
        })
        defer { model.stop(); connection.disconnect() }

        await model.start(connection: connection)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertFalse(model.isStarting)
        let deadline = ContinuousClock.now + .seconds(2)
        while model.rawVowel == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(model.volumeDb, model.sensitivityDb)
        XCTAssertNotNil(model.rawVowel)
        XCTAssertNotNil(model.vowel)
        XCTAssertFalse(model.distances.isEmpty)
    }

    func testBackgroundWhilePermissionPendingCancelsStart() async {
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        let capture = TestMicrophone()
        var model: LipSyncModel!
        model = LipSyncModel(capture: capture, permissionRequest: {
            model.scenePhaseChanged(.background)
            return .granted
        })
        defer { model.stop(); connection.disconnect() }
        await model.start(connection: connection)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertNil(connection.output.source)
    }

    func testStopWhileCaptureActivationIsPendingDoesNotRestartRecognition() async {
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        let capture = TestMicrophone()
        capture.suspendStart = true
        let model = LipSyncModel(capture: capture, permissionRequest: { .granted })
        defer { model.stop(); connection.disconnect() }
        let start = Task { await model.start(connection: connection) }
        await waitUntilTrue("Microphone start never suspended") { capture.startContinuation != nil }

        model.stop(connection: connection)
        capture.startContinuation?.resume()
        capture.startContinuation = nil
        await start.value

        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(capture.running)
        XCTAssertFalse(model.isStarting)
        XCTAssertNil(connection.output.source)
    }

    func testFailedCaptureReleasesOutputLease() async {
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        let capture = TestMicrophone()
        capture.failStart = true
        let model = LipSyncModel(capture: capture, permissionRequest: { .granted })
        connection.output.register(.lipSync) { model.stop() }
        defer { model.stop(); connection.disconnect() }
        await model.start(connection: connection)
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(connection.output.session)
        XCTAssertNil(connection.output.source)
    }

    func testFirstCalibrationRequestsPermissionAndSurvivesAlert() async throws {
        let capture = TestMicrophone()
        var requestCount = 0
        var model: LipSyncModel!
        model = LipSyncModel(capture: capture, permissionRequest: {
            requestCount += 1
            model.scenePhaseChanged(.inactive)
            return .granted
        })
        defer { model.cancelCalibration() }
        model.calibrate(.a)
        let deadline = ContinuousClock.now + .seconds(2)
        while capture.startCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertTrue(model.isCalibrating)
        XCTAssertNil(model.errorMessage)
    }

    func testDeniedCalibrationDoesNotOpenMicrophone() async throws {
        let capture = TestMicrophone()
        let model = LipSyncModel(capture: capture, permissionRequest: { .denied })
        defer { model.cancelCalibration() }
        model.calibrate(.a)
        let deadline = ContinuousClock.now + .seconds(2)
        while model.isCalibrating && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isCalibrating)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testCancelledCalibrationCannotStopReplacementCapture() async throws {
        let capture = TestMicrophone()
        let model = LipSyncModel(capture: capture, permissionRequest: { .granted })
        defer { model.cancelCalibration() }
        model.calibrate(.a)
        let deadline = ContinuousClock.now + .seconds(2)
        while capture.startCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(capture.startCount, 1)
        model.cancelCalibration()
        model.calibrate(.i)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertTrue(capture.running)
        XCTAssertEqual(model.calibratingVowel, .i)
    }

    func testStoppedAudioEngineStopsRecognitionAndCanRestart() async throws {
        let connection = BoardConnection()
        let connected = await connection.connect(using: FakeRinaTransport())
        XCTAssertTrue(connected)
        let capture = TestMicrophone()
        let model = LipSyncModel(capture: capture, permissionRequest: { .granted })
        connection.output.register(.lipSync) { model.stop() }
        defer { model.stop(); connection.disconnect() }
        await model.start(connection: connection)
        capture.running = false
        let deadline = ContinuousClock.now + .seconds(2)
        while model.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.vowel)
        await model.start(connection: connection)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(capture.startCount, 2)
    }
}

private final class TestMicrophone: LipSyncCapturing {
    var startCount = 0
    var running = false
    var isRunning: Bool { running }
    var failStart = false
    var suspendStart = false
    var startContinuation: CheckedContinuation<Void, Never>?
    let currentSampleRate: Double = 16_000
    var samples = LipSyncSignal.synthesizeVowel(
        formantsHz: [800, 1200, 2500], pitchHz: 140, sampleRate: 16_000, count: 4096)

    @MainActor func start() async throws {
        startCount += 1
        if failStart { throw LipSyncAudioCapture.CaptureError.noInputAvailable }
        running = true
        if suspendStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
    }

    func stop() { running = false }

    func latestWindow(count: Int) -> (samples: [Float], sampleRate: Double) {
        (running ? Array(samples.suffix(count)) : [], currentSampleRate)
    }
}
