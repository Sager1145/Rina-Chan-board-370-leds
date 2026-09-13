import Foundation
import RinaCore
import SwiftUI

/// Board-wide state behind the global Control Center (design guide §5, §63):
/// brightness, previous/next face, auto mode, and colour. These used to live
/// on the Control screen; they are board-global, so every tab reads them from
/// this one model and a change here is immediately visible everywhere.
///
/// `BoardConnection` stays the canonical source of hardware state — this model
/// only holds the short-lived *draft* values a control needs to stay
/// responsive while a command is in flight, and reconciles back to the board
/// as soon as the firmware echoes (§37).
@Observable
@MainActor
final class BoardControlCenterModel {
    // MARK: Brightness (raw firmware units, 10…200)

    var brightnessDraft: Double = Double(RinaLinkConstants.brightnessDefault)
    private var brightnessTouchUntil: Date = .distantPast

    // MARK: Mode / face

    var modeOverride: String?
    private var modeOverrideUntil: Date = .distantPast
    var faceIndexOverride: Int?
    private var faceIndexOverrideUntil: Date = .distantPast

    // MARK: Auto interval (seconds)

    var autoIntervalDraft: Double = Double(RinaLinkConstants.autoIntervalDefaultMs) / 1000
    private var autoIntervalTouchUntil: Date = .distantPast

    // MARK: Colour

    /// The confirmed/being-applied colour, always normalised `#rrggbb`.
    var colorHexDraft: String = "#ec3fc7"
    private var colorTouchUntil: Date = .distantPast
    var selectedParentId: String?
    var colorPresets: ColorPresets?

    /// Free-form hex field contents. Kept separate from `colorHexDraft` so a
    /// partially typed value never corrupts board state (§10): editing stays
    /// possible, the field reports validity, and nothing is transmitted until
    /// the value parses.
    var hexFieldText: String = "#ec3fc7"
    var hexFieldIsValid = true

    /// The board-global colour the physical board is currently set to, with
    /// the app's fallback when the draft hex cannot be parsed.
    var draftColor: Color { Color(hex: colorHexDraft) ?? .rinaPink }

    /// The raw firmware brightness (10…200) matching the draft.
    var draftBrightness: Int { Int(brightnessDraft) }

    var errorMessage: String?

    private var didLoadDefaults = false
    private weak var activeConnection: BoardConnection?
    /// Changes whenever the active board changes, so a late completion from
    /// the previous board cannot surface an error or alter reconciliation.
    private var connectionEpoch = UUID()

    @ObservationIgnored private let brightnessSender: LatestValueSender<Int>
    @ObservationIgnored private let autoIntervalSender: LatestValueSender<Double>
    @ObservationIgnored private let colorSender: LatestValueSender<String>

    init() {
        // The senders' closures escape, so they can't capture `self` before
        // every stored property is initialised; route the capture through a
        // box populated immediately afterwards.
        let box = WeakBox<BoardControlCenterModel>()
        brightnessSender = LatestValueSender<Int>(minInterval: 0.12) { raw in
            guard let self = box.value, let connection = self.activeConnection else { return }
            let epoch = self.connectionEpoch
            await self.run(connection, expectedConnectionEpoch: epoch,
                           reconcile: { $0.brightnessTouchUntil = .distantPast }) {
                _ = try await $0.command(.setBrightness(raw: raw))
            }
        }
        autoIntervalSender = LatestValueSender<Double>(minInterval: 0.12) { seconds in
            guard let self = box.value, let connection = self.activeConnection else { return }
            let ms = Int((seconds * 1000).rounded())
            let epoch = self.connectionEpoch
            await self.run(connection, expectedConnectionEpoch: epoch,
                           reconcile: { $0.autoIntervalTouchUntil = .distantPast }) {
                _ = try await $0.command(.setAutoInterval(ms: ms))
            }
        }
        // The colour picker's binding is continuous, so a drag would
        // otherwise spawn a command per frame and saturate the shared command
        // pump — starving brightness/step/mode sends and leaving the final
        // colour up to enqueue order. Coalesced like the sliders above.
        colorSender = LatestValueSender<String>(minInterval: 0.12) { hex in
            guard let self = box.value, let connection = self.activeConnection else { return }
            let epoch = self.connectionEpoch
            await self.run(connection, expectedConnectionEpoch: epoch,
                           reconcile: { $0.colorTouchUntil = .distantPast }) {
                _ = try await $0.command(.setColor(hex: hex))
            }
        }
        box.value = self
    }

    // MARK: Bootstrap

    func loadDefaultsIfNeeded() {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        colorPresets = try? RinaResources.colorPresets(bundle: .main)
        hexFieldText = colorHexDraft
    }

    /// Invalidates transient control state when the active board changes.
    ///
    /// Drafts normally ignore firmware echoes for two seconds after a user
    /// action. Those echoes belong to one board only: retaining the windows,
    /// overrides, or queued sends across a reconnect can make the next
    /// board's reported mode and preview settings look stale. The caller
    /// should follow this with `sync(from:)` when the new board's status is
    /// available.
    func connectionChanged() {
        connectionEpoch = UUID()
        brightnessTouchUntil = .distantPast
        autoIntervalTouchUntil = .distantPast
        colorTouchUntil = .distantPast
        modeOverride = nil
        modeOverrideUntil = .distantPast
        faceIndexOverride = nil
        faceIndexOverrideUntil = .distantPast
        activeConnection = nil
        brightnessSender.cancel()
        autoIntervalSender.cancel()
        colorSender.cancel()
        errorMessage = nil
    }

    // MARK: Sync from firmware (echo suppression)

    /// Pulls confirmed board state back into the drafts, except for controls
    /// the user touched in the last two seconds — otherwise a slow status echo
    /// would yank a slider back under the user's finger.
    func sync(from status: DeviceStatus?) {
        let now = Date()
        guard let renderer = status?.renderer else { return }
        if now >= brightnessTouchUntil, let brightness = renderer.brightness {
            brightnessDraft = Double(brightness)
        }
        if now >= autoIntervalTouchUntil, let ms = renderer.autoIntervalMs {
            autoIntervalDraft = Double(ms) / 1000
        }
        if now >= colorTouchUntil, let hex = renderer.color {
            colorHexDraft = hex
            hexFieldText = hex
            hexFieldIsValid = true
            selectedParentId = colorPresets?.parent(containing: hex).map { String($0.id) }
        }
        if now >= modeOverrideUntil { modeOverride = nil }
        if now >= faceIndexOverrideUntil { faceIndexOverride = nil }
    }

    func effectiveMode(status: DeviceStatus?) -> String {
        modeOverride ?? status?.renderer?.mode ?? "manual"
    }

    var isAutoMode: Bool { modeOverride == "auto" }

    func isAutoMode(status: DeviceStatus?) -> Bool {
        effectiveMode(status: status) == "auto"
    }

    func effectiveFaceIndex(status: DeviceStatus?) -> Int? {
        faceIndexOverride ?? status?.renderer?.autoFaceIndex
    }

    // MARK: Brightness

    /// Percentage view of the raw value, for the label. The raw 10…200 stays
    /// authoritative and is surfaced in Settings › Debug (§8).
    static func percent(forRaw raw: Int) -> Int {
        let clamped = clampedRaw(raw)
        let span = Double(RinaLinkConstants.brightnessMax - RinaLinkConstants.brightnessMin)
        return Int(((Double(clamped - RinaLinkConstants.brightnessMin) / span) * 100).rounded())
    }

    /// Raw brightness pinned to the firmware's accepted range.
    private static func clampedRaw(_ raw: Int) -> Int {
        min(RinaLinkConstants.brightnessMax, max(RinaLinkConstants.brightnessMin, raw))
    }

    func setBrightness(_ raw: Int, connection: BoardConnection) {
        let clamped = Self.clampedRaw(raw)
        brightnessDraft = Double(clamped)
        brightnessTouchUntil = Date().addingTimeInterval(2)
        activeConnection = connection
        brightnessSender.submit(clamped)
    }

    // MARK: Mode / face

    func toggleAutoMode(connection: BoardConnection) async {
        let epoch = connectionEpoch
        let current = effectiveMode(status: connection.status)
        modeOverride = current == "auto" ? "manual" : "auto"
        modeOverrideUntil = Date().addingTimeInterval(2)
        let token = connection.output.begin(modeOverride == "auto" ? .automatic : .manual)
        await run(connection, expectedConnectionEpoch: epoch,
                  reconcile: { $0.modeOverrideUntil = .distantPast }) { conn in
            try await conn.withOutput(token) { _ = try await conn.command(.button(button: "B3")) }
        }
    }

    /// Previous/next face. If a scroll is running, stop it first (without
    /// clearing the frame or restoring the pre-scroll mode — that's the
    /// firmware's job on the next explicit stop) so face stepping doesn't
    /// fight the scroll renderer.
    func step(face direction: Int, connection: BoardConnection) async {
        let epoch = connectionEpoch
        let token = connection.output.begin(.manual)
        let button = direction > 0 ? "B1" : "B2"
        if connection.status?.renderer?.firmwareScrollActive == true {
            await run(connection, expectedConnectionEpoch: epoch) { conn in try await conn.withOutput(token) { _ = try await conn.command(.stopScroll(restoreAuto: false, clear: false)) } }
        }
        guard epoch == connectionEpoch else { return }
        if let count = connection.status?.renderer?.autoFaceCount, count > 0 {
            let current = effectiveFaceIndex(status: connection.status) ?? 0
            faceIndexOverride = ((current + direction) % count + count) % count
            faceIndexOverrideUntil = Date().addingTimeInterval(2)
        }
        await run(connection, expectedConnectionEpoch: epoch,
                  reconcile: { $0.faceIndexOverrideUntil = .distantPast }) { conn in
            try await conn.withOutput(token) { _ = try await conn.command(.button(button: button)) }
        }
    }

    // MARK: Auto interval

    func setAutoInterval(_ seconds: Double, connection: BoardConnection) {
        let minSeconds = Double(RinaLinkConstants.autoIntervalMinMs) / 1000
        let maxSeconds = Double(RinaLinkConstants.autoIntervalMaxMs) / 1000
        let clamped = min(maxSeconds, max(minSeconds, seconds))
        autoIntervalDraft = clamped
        autoIntervalTouchUntil = Date().addingTimeInterval(2)
        activeConnection = connection
        autoIntervalSender.submit(clamped)
    }

    // MARK: Colour

    /// Re-validates the hex field on every keystroke without transmitting.
    func hexFieldChanged(_ text: String) {
        hexFieldText = text
        hexFieldIsValid = text.isEmpty || RGBHex.parseHex(text) != nil
    }

    /// Commits the hex field, if and only if it currently parses.
    func commitHexField(connection: BoardConnection) async {
        guard RGBHex.parseHex(hexFieldText) != nil else {
            hexFieldIsValid = false
            return
        }
        await setColor(hex: hexFieldText, connection: connection)
    }

    func setColor(hex: String, connection: BoardConnection) async {
        guard let (r, g, b) = RGBHex.parseHex(hex) else {
            hexFieldIsValid = false
            return
        }
        let normalized = RGBHex.formatHex(r: r, g: g, b: b)
        colorHexDraft = normalized
        hexFieldText = normalized
        hexFieldIsValid = true
        selectedParentId = colorPresets?.parent(containing: normalized).map { String($0.id) }
        colorTouchUntil = Date().addingTimeInterval(2)
        activeConnection = connection
        colorSender.submit(normalized)
    }

    // MARK: Command plumbing

    /// Runs a board command, and on failure surfaces the error *and* drops the
    /// echo-suppression window so the next firmware status snaps the UI back
    /// to the value the board actually has — the UI must never be left showing
    /// a value the board rejected (§38).
    private func run(
        _ connection: BoardConnection,
        expectedConnectionEpoch: UUID? = nil,
        reconcile: ((BoardControlCenterModel) -> Void)? = nil,
        _ body: @escaping (BoardConnection) async throws -> Void
    ) async {
        do {
            try await body(connection)
        } catch is CancellationError {
            // Superseded by a newer coalesced send; not a user-facing error.
        } catch RatePumpError.dropped {
            // Evicted by a later command with the same key; latest value wins.
        } catch {
            guard expectedConnectionEpoch == nil || expectedConnectionEpoch == connectionEpoch else { return }
            errorMessage = error.localizedDescription
            reconcile?(self)
        }
    }
}

/// Post-init weak capture cell, so escaping closures built during `init` don't
/// capture `self` before every stored property is initialised.
@MainActor
final class WeakBox<T: AnyObject> {
    weak var value: T?
    init() {}
}
