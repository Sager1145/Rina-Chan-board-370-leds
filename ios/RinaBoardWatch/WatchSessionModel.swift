import Foundation
import SwiftUI
import WatchConnectivity

/// The watch end of the phone link: the latest `WatchBoardSnapshot`, the
/// reachability of the iPhone, and the short-lived drafts the crown-driven
/// controls need so a slow echo from the phone never yanks a value back
/// under the user's finger (the same two-second window the phone's own
/// Control Center uses).
@Observable
@MainActor
final class WatchSessionModel {
    private(set) var snapshot: WatchBoardSnapshot?
    private(set) var isReachable = false
    private(set) var isActivated = false
    /// A failure reported by the phone for the last command, or a local
    /// send failure. Shown once as an alert.
    var errorMessage: String?

    // MARK: Drafts (crown-driven values)

    var brightness: Double = 50
    var autoIntervalSeconds: Double = 3
    var scrollFps: Double = 10
    var sensitivityDb: Double = -40

    private enum Draft: Hashable { case brightness, autoInterval, scrollFps, sensitivity }
    private var touchUntil: [Draft: Date] = [:]

    @ObservationIgnored private let relay = WatchLinkSessionRelay()
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var brightnessSender: WatchCoalescedSender<Int>?
    @ObservationIgnored private var intervalSender: WatchCoalescedSender<Double>?
    @ObservationIgnored private var scrollFpsSender: WatchCoalescedSender<Int>?
    @ObservationIgnored private var sensitivitySender: WatchCoalescedSender<Double>?

    // MARK: Derived

    var isConnected: Bool { snapshot?.board.isConnected ?? false }
    /// Controls are live only with a reachable phone and a connected target.
    var canControl: Bool { isReachable && isConnected }
    var selectedTarget: WatchTargetChoice? {
        snapshot?.targets.first { $0.id == snapshot?.selectedTargetID }
    }

    // MARK: Lifecycle

    func activate() {
        guard session == nil else { return }
        let session = WCSession.default
        self.session = session
        relay.onPayload = { [weak self] data, reply in
            reply?(Data())
            Task { @MainActor in self?.apply(data) }
        }
        relay.onContext = { [weak self] data in
            Task { @MainActor in self?.apply(data) }
        }
        relay.onStateChange = { [weak self] in
            Task { @MainActor in self?.sessionStateChanged() }
        }
        brightnessSender = WatchCoalescedSender { [weak self] in self?.send(.setBrightness(raw: $0)) }
        intervalSender = WatchCoalescedSender { [weak self] in self?.send(.setAutoInterval(seconds: $0)) }
        scrollFpsSender = WatchCoalescedSender { [weak self] in self?.send(.setScrollFps(fps: $0)) }
        sensitivitySender = WatchCoalescedSender { [weak self] in self?.send(.setLipSyncSensitivity(db: $0)) }
        session.delegate = relay
        session.activate()
        // Whatever the phone last published, before any live message.
        if let data = WatchLinkCodec.payload(in: session.receivedApplicationContext) {
            apply(data)
        }
        // Activation and reachability can complete in either order, and a
        // request sent before activation is dropped: keep asking, at a
        // gentle pace, until the first snapshot lands.
        Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.snapshot == nil else { return }
                self.sessionStateChanged()
                self.refresh()
            }
        }
    }

    private func sessionStateChanged() {
        guard let session else { return }
        isActivated = session.activationState == .activated
        isReachable = session.isReachable
        if isReachable { refresh() }
    }

    /// Asks the phone for a fresh snapshot.
    func refresh() {
        send(.requestState)
    }

    // MARK: Snapshot

    private func apply(_ data: Data) {
        guard let snapshot = try? WatchLinkCodec.decode(WatchBoardSnapshot.self, from: data) else { return }
        self.snapshot = snapshot
        let now = Date()
        if now >= (touchUntil[.brightness] ?? .distantPast) {
            brightness = Double(snapshot.controls.brightnessRaw)
        }
        if now >= (touchUntil[.autoInterval] ?? .distantPast) {
            autoIntervalSeconds = snapshot.controls.autoIntervalSeconds
        }
        if now >= (touchUntil[.scrollFps] ?? .distantPast), let fps = snapshot.controls.scrollFps {
            scrollFps = Double(fps)
        }
        if now >= (touchUntil[.sensitivity] ?? .distantPast) {
            sensitivityDb = snapshot.lipSync.sensitivityDb
        }
        // The phone sends a command failure exactly once, so this never
        // re-raises an alert the user has dismissed.
        if let message = snapshot.errorMessage {
            errorMessage = message
        }
    }

    // MARK: Commands

    /// Sends one command and applies the phone's reply. Silently dropped
    /// while the phone is out of reach — the status row already says so, and
    /// a queued command arriving minutes later would be a surprise.
    func send(_ command: WatchCommand) {
        guard let session, session.activationState == .activated else { return }
        guard session.isReachable else {
            isReachable = false
            return
        }
        guard let data = try? WatchLinkCodec.encode(command) else { return }
        session.sendMessage(WatchLinkCodec.envelope(data), replyHandler: { [weak self] reply in
            guard let payload = WatchLinkCodec.payload(in: reply) else { return }
            Task { @MainActor in self?.apply(payload) }
        }, errorHandler: { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.isReachable = self.session?.isReachable ?? false
                if case .requestState = command { return }
                self.errorMessage = message
            }
        })
    }

    func selectTarget(_ id: String) {
        // Show the choice immediately; the reply confirms or corrects it.
        if var snapshot { snapshot.selectedTargetID = id; self.snapshot = snapshot }
        touchUntil = [:]
        // A value already sent to the previous board must be sendable again
        // to the new one.
        for sender in [brightnessSender, scrollFpsSender] { sender?.reset() }
        for sender in [intervalSender, sensitivitySender] { sender?.reset() }
        send(.selectTarget(id: id))
    }

    func stepFace(_ direction: Int) {
        send(.stepFace(direction: direction))
    }

    func setAutoMode(_ enabled: Bool) {
        if var snapshot { snapshot.controls.isAutoMode = enabled; self.snapshot = snapshot }
        send(.setAutoMode(enabled: enabled))
    }

    func setColor(hex: String) {
        if var snapshot { snapshot.controls.colorHex = hex; self.snapshot = snapshot }
        send(.setColor(hex: hex))
    }

    func brightnessChanged() {
        touchUntil[.brightness] = Date().addingTimeInterval(2)
        brightnessSender?.submit(Int(brightness.rounded()))
    }

    func autoIntervalChanged() {
        touchUntil[.autoInterval] = Date().addingTimeInterval(2)
        intervalSender?.submit((autoIntervalSeconds * 10).rounded() / 10)
    }

    func scrollFpsChanged() {
        touchUntil[.scrollFps] = Date().addingTimeInterval(2)
        scrollFpsSender?.submit(Int(scrollFps.rounded()))
    }

    func sensitivityChanged() {
        touchUntil[.sensitivity] = Date().addingTimeInterval(2)
        sensitivitySender?.submit(sensitivityDb.rounded())
    }

    func toggleLipSync() {
        guard let snapshot else { return }
        if snapshot.lipSync.isRunning {
            send(.lipSyncStop)
        } else {
            send(.lipSyncStart)
            // A start is answered before it runs (it may wait on the
            // microphone prompt); ask again for the outcome in case the
            // phone's push does not reach us.
            Task { [weak self] in
                for delay in [2.0, 5.0] {
                    try? await Task.sleep(for: .seconds(delay))
                    self?.refresh()
                }
            }
        }
    }

    /// Percentage label for a raw brightness, matching the phone's label.
    func brightnessPercent(_ raw: Double) -> Int {
        guard let controls = snapshot?.controls else { return Int(raw) }
        let span = Double(controls.brightnessMax - controls.brightnessMin)
        guard span > 0 else { return 0 }
        return Int(((raw - Double(controls.brightnessMin)) / span * 100).rounded())
    }
}

/// Sends the newest value at most once per `interval`, so a crown spin does
/// not turn into a message per tick. The first value goes immediately.
@MainActor
final class WatchCoalescedSender<Value: Equatable & Sendable> {
    private let interval: Duration
    private let send: @MainActor (Value) -> Void
    private var pending: Value?
    private var lastSent: Value?
    private var drain: Task<Void, Never>?

    init(interval: Duration = .milliseconds(120), send: @escaping @MainActor (Value) -> Void) {
        self.interval = interval
        self.send = send
    }

    /// Forgets the last value sent, e.g. after the target changed.
    func reset() {
        lastSent = nil
    }

    func submit(_ value: Value) {
        pending = value
        guard drain == nil else { return }
        drain = Task { [weak self] in
            while let self, let value = self.pending {
                self.pending = nil
                if value != self.lastSent {
                    self.lastSent = value
                    self.send(value)
                }
                try? await Task.sleep(for: self.interval)
            }
            self?.drain = nil
        }
    }
}
