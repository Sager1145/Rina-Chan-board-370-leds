import Foundation

// Codable payload shapes for RinaLink JSON messages. Field names/types are
// kept exactly as emitted by the firmware (`esp32s3_firmware/src/protocol.cpp`
// / `wifi_manager.cpp` / `docs/RINALINK_PROTOCOL_V1.md`), not the old HTTP API
// spec. Every struct decodes unknown/missing keys leniently (every property is
// `Optional`, so the compiler-synthesized `Decodable` calls `decodeIfPresent`
// for each key) so firmware additions/omissions never break the app.

// MARK: - Numeric decoding helpers

/// Some firmware numeric fields could plausibly be serialized as either a
/// JSON integer or a JSON float depending on the underlying C++ type
/// (e.g. `vbat`/`vcharge` are `float`, `brightness`/`batteryPercent` are
/// integral). Decode either representation into the Swift type callers want.
enum FlexibleNumber {
    static func int(from container: KeyedDecodingContainer<Messages_CodingKeyAny>, key: Messages_CodingKeyAny) -> Int? {
        if let i = try? container.decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }
    static func double(from container: KeyedDecodingContainer<Messages_CodingKeyAny>, key: Messages_CodingKeyAny) -> Double? {
        if let d = try? container.decodeIfPresent(Double.self, forKey: key) { return d }
        if let i = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        return nil
    }
}

/// A type-erased `CodingKey` used only by `FlexibleNumber`'s helpers above so
/// they can be shared across the structs below without one enum per struct.
struct Messages_CodingKeyAny: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    init(_ stringValue: String) { self.stringValue = stringValue }
}

// MARK: - Power (`addPower()` in protocol.cpp — GET_POWER / EV_POWER / status.power)

public struct PowerStatus: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var charging: Bool?
    public var chargeValid: Bool?
    public var batteryValid: Bool?
    public var batteryPercent: Int?
    public var vbat: Double?
    public var vcharge: Double?
    public var batteryPowered: Bool?
    public var batteryDisconnected: Bool?
    public var batteryLowVoltageUnpowered: Bool?

    public init(ok: Bool? = nil, charging: Bool? = nil, chargeValid: Bool? = nil, batteryValid: Bool? = nil,
                batteryPercent: Int? = nil, vbat: Double? = nil, vcharge: Double? = nil,
                batteryPowered: Bool? = nil, batteryDisconnected: Bool? = nil,
                batteryLowVoltageUnpowered: Bool? = nil) {
        self.ok = ok
        self.charging = charging
        self.chargeValid = chargeValid
        self.batteryValid = batteryValid
        self.batteryPercent = batteryPercent
        self.vbat = vbat
        self.vcharge = vcharge
        self.batteryPowered = batteryPowered
        self.batteryDisconnected = batteryDisconnected
        self.batteryLowVoltageUnpowered = batteryLowVoltageUnpowered
    }

    private enum CodingKeys: String, CodingKey {
        case ok, charging, chargeValid, batteryValid, batteryPercent, vbat, vcharge,
             batteryPowered, batteryDisconnected, batteryLowVoltageUnpowered
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Messages_CodingKeyAny.self)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .init("ok"))
        charging = try? c.decodeIfPresent(Bool.self, forKey: .init("charging"))
        chargeValid = try? c.decodeIfPresent(Bool.self, forKey: .init("chargeValid"))
        batteryValid = try? c.decodeIfPresent(Bool.self, forKey: .init("batteryValid"))
        batteryPercent = FlexibleNumber.int(from: c, key: .init("batteryPercent"))
        vbat = FlexibleNumber.double(from: c, key: .init("vbat"))
        vcharge = FlexibleNumber.double(from: c, key: .init("vcharge"))
        batteryPowered = try? c.decodeIfPresent(Bool.self, forKey: .init("batteryPowered"))
        batteryDisconnected = try? c.decodeIfPresent(Bool.self, forKey: .init("batteryDisconnected"))
        batteryLowVoltageUnpowered = try? c.decodeIfPresent(Bool.self, forKey: .init("batteryLowVoltageUnpowered"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(ok, forKey: .ok)
        try c.encodeIfPresent(charging, forKey: .charging)
        try c.encodeIfPresent(chargeValid, forKey: .chargeValid)
        try c.encodeIfPresent(batteryValid, forKey: .batteryValid)
        try c.encodeIfPresent(batteryPercent, forKey: .batteryPercent)
        try c.encodeIfPresent(vbat, forKey: .vbat)
        try c.encodeIfPresent(vcharge, forKey: .vcharge)
        try c.encodeIfPresent(batteryPowered, forKey: .batteryPowered)
        try c.encodeIfPresent(batteryDisconnected, forKey: .batteryDisconnected)
        try c.encodeIfPresent(batteryLowVoltageUnpowered, forKey: .batteryLowVoltageUnpowered)
    }
}

// MARK: - Renderer (`buildStatusJson()`'s `renderer` object, plus `addFace`/`addScroll`
// which merge directly into that same JSON object)

public struct RendererStatus: Codable, Equatable, Sendable {
    public var color: String?
    public var brightness: Int?
    public var brightnessMin: Int?
    public var brightnessMax: Int?
    public var mode: String?
    public var playback: String?
    public var paused: Bool?
    public var autoIntervalMs: Int?
    public var autoFaceCount: Int?
    public var autoFaceIndex: Int?
    public var frameEncoding: String?
    public var frameBytes: Int?
    public var frameBits: Int?
    public var frameQueueDepth: Int?
    public var frameQueueCount: Int?
    public var lit: Int?
    public var lastReason: String?
    public var ledBackend: String?
    public var ledDma: Bool?
    public var ledRefreshUs: Int?
    public var ledRefreshMaxUs: Int?
    public var ledRefreshFail: Int?
    // addFace(): only present while an auto-face is active.
    public var autoFaceId: String?
    public var autoFaceName: String?
    // addScroll(): scroll-session state merged into the same object.
    public var firmwareScrollActive: Bool?
    public var firmwareScrollPaused: Bool?
    public var firmwareScrollUserPaused: Bool?
    public var firmwareScrollSystemPaused: Bool?
    public var restoreAutoAfterScroll: Bool?
    public var scrollFrameCount: Int?
    public var scrollFrameIndex: Int?
    public var scrollIntervalMs: Int?
    public var uiFps: Int?
    public var scrollFps: Int?
    public var scrollTimelineId: String?
    public var scrollUploadComplete: Bool?
    public var scrollHasSourceText: Bool?

    public init(color: String? = nil, brightness: Int? = nil, brightnessMin: Int? = nil, brightnessMax: Int? = nil,
                mode: String? = nil, playback: String? = nil, paused: Bool? = nil, autoIntervalMs: Int? = nil,
                autoFaceCount: Int? = nil, autoFaceIndex: Int? = nil, frameEncoding: String? = nil,
                frameBytes: Int? = nil, frameBits: Int? = nil, frameQueueDepth: Int? = nil,
                frameQueueCount: Int? = nil, lit: Int? = nil, lastReason: String? = nil, ledBackend: String? = nil,
                ledDma: Bool? = nil, ledRefreshUs: Int? = nil, ledRefreshMaxUs: Int? = nil, ledRefreshFail: Int? = nil,
                autoFaceId: String? = nil, autoFaceName: String? = nil, firmwareScrollActive: Bool? = nil,
                firmwareScrollPaused: Bool? = nil, firmwareScrollUserPaused: Bool? = nil,
                firmwareScrollSystemPaused: Bool? = nil, restoreAutoAfterScroll: Bool? = nil,
                scrollFrameCount: Int? = nil, scrollFrameIndex: Int? = nil, scrollIntervalMs: Int? = nil,
                uiFps: Int? = nil, scrollFps: Int? = nil, scrollTimelineId: String? = nil,
                scrollUploadComplete: Bool? = nil, scrollHasSourceText: Bool? = nil) {
        self.color = color
        self.brightness = brightness
        self.brightnessMin = brightnessMin
        self.brightnessMax = brightnessMax
        self.mode = mode
        self.playback = playback
        self.paused = paused
        self.autoIntervalMs = autoIntervalMs
        self.autoFaceCount = autoFaceCount
        self.autoFaceIndex = autoFaceIndex
        self.frameEncoding = frameEncoding
        self.frameBytes = frameBytes
        self.frameBits = frameBits
        self.frameQueueDepth = frameQueueDepth
        self.frameQueueCount = frameQueueCount
        self.lit = lit
        self.lastReason = lastReason
        self.ledBackend = ledBackend
        self.ledDma = ledDma
        self.ledRefreshUs = ledRefreshUs
        self.ledRefreshMaxUs = ledRefreshMaxUs
        self.ledRefreshFail = ledRefreshFail
        self.autoFaceId = autoFaceId
        self.autoFaceName = autoFaceName
        self.firmwareScrollActive = firmwareScrollActive
        self.firmwareScrollPaused = firmwareScrollPaused
        self.firmwareScrollUserPaused = firmwareScrollUserPaused
        self.firmwareScrollSystemPaused = firmwareScrollSystemPaused
        self.restoreAutoAfterScroll = restoreAutoAfterScroll
        self.scrollFrameCount = scrollFrameCount
        self.scrollFrameIndex = scrollFrameIndex
        self.scrollIntervalMs = scrollIntervalMs
        self.uiFps = uiFps
        self.scrollFps = scrollFps
        self.scrollTimelineId = scrollTimelineId
        self.scrollUploadComplete = scrollUploadComplete
        self.scrollHasSourceText = scrollHasSourceText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Messages_CodingKeyAny.self)
        color = try? c.decodeIfPresent(String.self, forKey: .init("color"))
        brightness = FlexibleNumber.int(from: c, key: .init("brightness"))
        brightnessMin = FlexibleNumber.int(from: c, key: .init("brightnessMin"))
        brightnessMax = FlexibleNumber.int(from: c, key: .init("brightnessMax"))
        mode = try? c.decodeIfPresent(String.self, forKey: .init("mode"))
        playback = try? c.decodeIfPresent(String.self, forKey: .init("playback"))
        paused = try? c.decodeIfPresent(Bool.self, forKey: .init("paused"))
        autoIntervalMs = FlexibleNumber.int(from: c, key: .init("autoIntervalMs"))
        autoFaceCount = FlexibleNumber.int(from: c, key: .init("autoFaceCount"))
        autoFaceIndex = FlexibleNumber.int(from: c, key: .init("autoFaceIndex"))
        frameEncoding = try? c.decodeIfPresent(String.self, forKey: .init("frameEncoding"))
        frameBytes = FlexibleNumber.int(from: c, key: .init("frameBytes"))
        frameBits = FlexibleNumber.int(from: c, key: .init("frameBits"))
        frameQueueDepth = FlexibleNumber.int(from: c, key: .init("frameQueueDepth"))
        frameQueueCount = FlexibleNumber.int(from: c, key: .init("frameQueueCount"))
        lit = FlexibleNumber.int(from: c, key: .init("lit"))
        lastReason = try? c.decodeIfPresent(String.self, forKey: .init("lastReason"))
        ledBackend = try? c.decodeIfPresent(String.self, forKey: .init("ledBackend"))
        ledDma = try? c.decodeIfPresent(Bool.self, forKey: .init("ledDma"))
        ledRefreshUs = FlexibleNumber.int(from: c, key: .init("ledRefreshUs"))
        ledRefreshMaxUs = FlexibleNumber.int(from: c, key: .init("ledRefreshMaxUs"))
        ledRefreshFail = FlexibleNumber.int(from: c, key: .init("ledRefreshFail"))
        autoFaceId = try? c.decodeIfPresent(String.self, forKey: .init("autoFaceId"))
        autoFaceName = try? c.decodeIfPresent(String.self, forKey: .init("autoFaceName"))
        firmwareScrollActive = try? c.decodeIfPresent(Bool.self, forKey: .init("firmwareScrollActive"))
        firmwareScrollPaused = try? c.decodeIfPresent(Bool.self, forKey: .init("firmwareScrollPaused"))
        firmwareScrollUserPaused = try? c.decodeIfPresent(Bool.self, forKey: .init("firmwareScrollUserPaused"))
        firmwareScrollSystemPaused = try? c.decodeIfPresent(Bool.self, forKey: .init("firmwareScrollSystemPaused"))
        restoreAutoAfterScroll = try? c.decodeIfPresent(Bool.self, forKey: .init("restoreAutoAfterScroll"))
        scrollFrameCount = FlexibleNumber.int(from: c, key: .init("scrollFrameCount"))
        scrollFrameIndex = FlexibleNumber.int(from: c, key: .init("scrollFrameIndex"))
        scrollIntervalMs = FlexibleNumber.int(from: c, key: .init("scrollIntervalMs"))
        uiFps = FlexibleNumber.int(from: c, key: .init("uiFps"))
        scrollFps = FlexibleNumber.int(from: c, key: .init("scrollFps"))
        scrollTimelineId = try? c.decodeIfPresent(String.self, forKey: .init("scrollTimelineId"))
        scrollUploadComplete = try? c.decodeIfPresent(Bool.self, forKey: .init("scrollUploadComplete"))
        scrollHasSourceText = try? c.decodeIfPresent(Bool.self, forKey: .init("scrollHasSourceText"))
    }

    private enum CodingKeys: String, CodingKey {
        case color, brightness, brightnessMin, brightnessMax, mode, playback, paused, autoIntervalMs,
             autoFaceCount, autoFaceIndex, frameEncoding, frameBytes, frameBits, frameQueueDepth,
             frameQueueCount, lit, lastReason, ledBackend, ledDma, ledRefreshUs, ledRefreshMaxUs,
             ledRefreshFail, autoFaceId, autoFaceName, firmwareScrollActive, firmwareScrollPaused,
             firmwareScrollUserPaused, firmwareScrollSystemPaused, restoreAutoAfterScroll,
             scrollFrameCount, scrollFrameIndex, scrollIntervalMs, uiFps, scrollFps, scrollTimelineId,
             scrollUploadComplete, scrollHasSourceText
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(brightness, forKey: .brightness)
        try c.encodeIfPresent(brightnessMin, forKey: .brightnessMin)
        try c.encodeIfPresent(brightnessMax, forKey: .brightnessMax)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(playback, forKey: .playback)
        try c.encodeIfPresent(paused, forKey: .paused)
        try c.encodeIfPresent(autoIntervalMs, forKey: .autoIntervalMs)
        try c.encodeIfPresent(autoFaceCount, forKey: .autoFaceCount)
        try c.encodeIfPresent(autoFaceIndex, forKey: .autoFaceIndex)
        try c.encodeIfPresent(frameEncoding, forKey: .frameEncoding)
        try c.encodeIfPresent(frameBytes, forKey: .frameBytes)
        try c.encodeIfPresent(frameBits, forKey: .frameBits)
        try c.encodeIfPresent(frameQueueDepth, forKey: .frameQueueDepth)
        try c.encodeIfPresent(frameQueueCount, forKey: .frameQueueCount)
        try c.encodeIfPresent(lit, forKey: .lit)
        try c.encodeIfPresent(lastReason, forKey: .lastReason)
        try c.encodeIfPresent(ledBackend, forKey: .ledBackend)
        try c.encodeIfPresent(ledDma, forKey: .ledDma)
        try c.encodeIfPresent(ledRefreshUs, forKey: .ledRefreshUs)
        try c.encodeIfPresent(ledRefreshMaxUs, forKey: .ledRefreshMaxUs)
        try c.encodeIfPresent(ledRefreshFail, forKey: .ledRefreshFail)
        try c.encodeIfPresent(autoFaceId, forKey: .autoFaceId)
        try c.encodeIfPresent(autoFaceName, forKey: .autoFaceName)
        try c.encodeIfPresent(firmwareScrollActive, forKey: .firmwareScrollActive)
        try c.encodeIfPresent(firmwareScrollPaused, forKey: .firmwareScrollPaused)
        try c.encodeIfPresent(firmwareScrollUserPaused, forKey: .firmwareScrollUserPaused)
        try c.encodeIfPresent(firmwareScrollSystemPaused, forKey: .firmwareScrollSystemPaused)
        try c.encodeIfPresent(restoreAutoAfterScroll, forKey: .restoreAutoAfterScroll)
        try c.encodeIfPresent(scrollFrameCount, forKey: .scrollFrameCount)
        try c.encodeIfPresent(scrollFrameIndex, forKey: .scrollFrameIndex)
        try c.encodeIfPresent(scrollIntervalMs, forKey: .scrollIntervalMs)
        try c.encodeIfPresent(uiFps, forKey: .uiFps)
        try c.encodeIfPresent(scrollFps, forKey: .scrollFps)
        try c.encodeIfPresent(scrollTimelineId, forKey: .scrollTimelineId)
        try c.encodeIfPresent(scrollUploadComplete, forKey: .scrollUploadComplete)
        try c.encodeIfPresent(scrollHasSourceText, forKey: .scrollHasSourceText)
    }
}

// MARK: - `matrix` / `stats` sub-objects (`buildStatusJson()`, non-`lite` only)

public struct MatrixInfo: Codable, Equatable, Sendable {
    public var leds: Int?
    public var frameBytes: Int?
    public var frameEncoding: String?

    public init(leds: Int? = nil, frameBytes: Int? = nil, frameEncoding: String? = nil) {
        self.leds = leds
        self.frameBytes = frameBytes
        self.frameEncoding = frameEncoding
    }
}

public struct StatsInfo: Codable, Equatable, Sendable {
    public var framesAccepted: Int?
    public var framesRejected: Int?
    public var framesQueued: Int?
    public var framesDequeued: Int?
    public var framesDropped: Int?
    public var commandsAccepted: Int?
    public var commandsRejected: Int?

    public init(framesAccepted: Int? = nil, framesRejected: Int? = nil, framesQueued: Int? = nil,
                framesDequeued: Int? = nil, framesDropped: Int? = nil, commandsAccepted: Int? = nil,
                commandsRejected: Int? = nil) {
        self.framesAccepted = framesAccepted
        self.framesRejected = framesRejected
        self.framesQueued = framesQueued
        self.framesDequeued = framesDequeued
        self.framesDropped = framesDropped
        self.commandsAccepted = commandsAccepted
        self.commandsRejected = commandsRejected
    }
}

// MARK: - Wi-Fi (`wifiManagerGetStatusJson()` in wifi_manager.cpp)

public struct WifiNetwork: Codable, Equatable, Sendable, Identifiable {
    public var ssid: String
    public var rssi: Int
    public var secure: Bool

    public var id: String { ssid }

    public init(ssid: String, rssi: Int, secure: Bool) {
        self.ssid = ssid
        self.rssi = rssi
        self.secure = secure
    }
}

public struct WifiStatus: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var mode: String?
    public var staConnected: Bool?
    public var ssid: String?
    public var ip: String?
    public var rssi: Int?
    public var apActive: Bool?
    public var apSsid: String?
    public var apIp: String?
    public var hostname: String?
    public var tcpPort: Int?
    public var clients: Int?

    public init(ok: Bool? = nil, mode: String? = nil, staConnected: Bool? = nil, ssid: String? = nil,
                ip: String? = nil, rssi: Int? = nil, apActive: Bool? = nil, apSsid: String? = nil,
                apIp: String? = nil, hostname: String? = nil, tcpPort: Int? = nil, clients: Int? = nil) {
        self.ok = ok
        self.mode = mode
        self.staConnected = staConnected
        self.ssid = ssid
        self.ip = ip
        self.rssi = rssi
        self.apActive = apActive
        self.apSsid = apSsid
        self.apIp = apIp
        self.hostname = hostname
        self.tcpPort = tcpPort
        self.clients = clients
    }
}

/// `CMD wifi_scan` reply: `{"ok":true,"networks":[{"ssid","rssi","secure"}]}`.
/// Distinct from `WifiStatus` (the `wifi_status`/`EV_WIFI` shape) — the
/// firmware never merges the two.
public struct WifiScanReply: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var scanning: Bool?
    public var networks: [WifiNetwork]?

    public init(ok: Bool? = nil, scanning: Bool? = nil, networks: [WifiNetwork]? = nil) {
        self.ok = ok
        self.scanning = scanning
        self.networks = networks
    }
}

// MARK: - Status (`buildStatusJson()` — GET_STATUS / EV_STATUS)

public struct DeviceStatus: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var v: Int?
    public var version: Int?
    public var device: String?
    public var uptimeMs: Int?
    public var wifi: WifiStatus?
    public var power: PowerStatus?
    public var renderer: RendererStatus?
    public var matrix: MatrixInfo?
    public var stats: StatsInfo?

    public init(ok: Bool? = nil, v: Int? = nil, version: Int? = nil, device: String? = nil,
                uptimeMs: Int? = nil, wifi: WifiStatus? = nil, power: PowerStatus? = nil,
                renderer: RendererStatus? = nil, matrix: MatrixInfo? = nil, stats: StatsInfo? = nil) {
        self.ok = ok
        self.v = v
        self.version = version
        self.device = device
        self.uptimeMs = uptimeMs
        self.wifi = wifi
        self.power = power
        self.renderer = renderer
        self.matrix = matrix
        self.stats = stats
    }
}

// MARK: - Preview sync (`buildPreviewSyncJson()` — GET_PREVIEW_SYNC / EV_PREVIEW_SYNC)

public struct PreviewSync: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var v: Int?
    public var mode: String?
    public var playback: String?
    public var autoFaceIndex: Int?
    public var autoFaceCount: Int?
    public var lastReason: String?
    public var valid: Bool?
    public var presentedSeq: Int?
    public var source: String?
    public var reason: String?
    public var scrollTimelineId: String?
    public var presentedFrameIndex: Int?
    public var presentedFrameCount: Int?
    public var frameIndex: Int?
    public var frameCount: Int?
    public var presentedAtUs: Int64?
    public var renderStartUs: Int?
    public var renderDurationUs: Int?
    public var scrollIntervalMs: Int?
    public var uiFps: Int?
    public var firmwareScrollActive: Bool?
    public var firmwareScrollPaused: Bool?
    public var firmwareScrollUserPaused: Bool?
    public var firmwareScrollSystemPaused: Bool?
    public var rateEligible: Bool?

    /// Effective playback rate in frames/sec, derived from `uiFps`/`scrollIntervalMs`
    /// for callers that want a `Double` FPS (the wire format only carries `uiFps`, an int).
    public var fps: Double? {
        if let uiFps, uiFps > 0 { return Double(uiFps) }
        if let scrollIntervalMs, scrollIntervalMs > 0 { return 1000.0 / Double(scrollIntervalMs) }
        return nil
    }

    public init(ok: Bool? = nil, v: Int? = nil, mode: String? = nil, playback: String? = nil,
                autoFaceIndex: Int? = nil, autoFaceCount: Int? = nil, lastReason: String? = nil,
                valid: Bool? = nil, presentedSeq: Int? = nil, source: String? = nil, reason: String? = nil,
                scrollTimelineId: String? = nil, presentedFrameIndex: Int? = nil, presentedFrameCount: Int? = nil,
                frameIndex: Int? = nil, frameCount: Int? = nil, presentedAtUs: Int64? = nil,
                renderStartUs: Int? = nil, renderDurationUs: Int? = nil, scrollIntervalMs: Int? = nil,
                uiFps: Int? = nil, firmwareScrollActive: Bool? = nil, firmwareScrollPaused: Bool? = nil,
                firmwareScrollUserPaused: Bool? = nil, firmwareScrollSystemPaused: Bool? = nil,
                rateEligible: Bool? = nil) {
        self.ok = ok
        self.v = v
        self.mode = mode
        self.playback = playback
        self.autoFaceIndex = autoFaceIndex
        self.autoFaceCount = autoFaceCount
        self.lastReason = lastReason
        self.valid = valid
        self.presentedSeq = presentedSeq
        self.source = source
        self.reason = reason
        self.scrollTimelineId = scrollTimelineId
        self.presentedFrameIndex = presentedFrameIndex
        self.presentedFrameCount = presentedFrameCount
        self.frameIndex = frameIndex
        self.frameCount = frameCount
        self.presentedAtUs = presentedAtUs
        self.renderStartUs = renderStartUs
        self.renderDurationUs = renderDurationUs
        self.scrollIntervalMs = scrollIntervalMs
        self.uiFps = uiFps
        self.firmwareScrollActive = firmwareScrollActive
        self.firmwareScrollPaused = firmwareScrollPaused
        self.firmwareScrollUserPaused = firmwareScrollUserPaused
        self.firmwareScrollSystemPaused = firmwareScrollSystemPaused
        self.rateEligible = rateEligible
    }

    private enum CodingKeys: String, CodingKey {
        case ok, v, mode, playback, autoFaceIndex, autoFaceCount, lastReason, valid, presentedSeq, source,
             reason, scrollTimelineId, presentedFrameIndex, presentedFrameCount, frameIndex, frameCount,
             presentedAtUs, renderStartUs, renderDurationUs, scrollIntervalMs, uiFps, firmwareScrollActive,
             firmwareScrollPaused, firmwareScrollUserPaused, firmwareScrollSystemPaused, rateEligible
    }
}

// MARK: - Scroll meta (`handleGetScrollMeta()` — GET_SCROLL_META)

public struct ScrollMeta: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var scrollTimelineId: String?
    public var hasSourceText: Bool?
    public var sourceText: String?
    public var sourceTextBytes: Int?
    public var fontId: String?
    public var generatorVersion: String?
    public var uiFps: Int?
    public var scrollIntervalMs: Int?
    public var frameCount: Int?
    public var frameIndex: Int?
    public var uploadComplete: Bool?
    public var firmwareScrollActive: Bool?
    public var firmwareScrollPaused: Bool?

    public init(ok: Bool? = nil, scrollTimelineId: String? = nil, hasSourceText: Bool? = nil,
                sourceText: String? = nil, sourceTextBytes: Int? = nil, fontId: String? = nil,
                generatorVersion: String? = nil, uiFps: Int? = nil, scrollIntervalMs: Int? = nil,
                frameCount: Int? = nil, frameIndex: Int? = nil, uploadComplete: Bool? = nil,
                firmwareScrollActive: Bool? = nil, firmwareScrollPaused: Bool? = nil) {
        self.ok = ok
        self.scrollTimelineId = scrollTimelineId
        self.hasSourceText = hasSourceText
        self.sourceText = sourceText
        self.sourceTextBytes = sourceTextBytes
        self.fontId = fontId
        self.generatorVersion = generatorVersion
        self.uiFps = uiFps
        self.scrollIntervalMs = scrollIntervalMs
        self.frameCount = frameCount
        self.frameIndex = frameIndex
        self.uploadComplete = uploadComplete
        self.firmwareScrollActive = firmwareScrollActive
        self.firmwareScrollPaused = firmwareScrollPaused
    }
}

// MARK: - `CMD` generic reply (`reply()` in protocol.cpp)

public struct CommandReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var code: Int?
    public var v: Int?
    public var cmd: String?
    public var color: String?
    public var brightness: Int?
    public var mode: String?
    public var playback: String?
    public var paused: Bool?
    public var autoIntervalMs: Int?
    public var autoFaceIndex: Int?
    public var frameBytes: Int?
    public var frameEncoding: String?
    public var queueCount: Int?
    public var lastReason: String?
    public var lit: Int?
    public var autoFaceId: String?
    public var autoFaceName: String?
    public var firmwareScrollActive: Bool?
    public var firmwareScrollPaused: Bool?
    public var firmwareScrollUserPaused: Bool?
    public var firmwareScrollSystemPaused: Bool?
    public var restoreAutoAfterScroll: Bool?
    public var scrollFrameCount: Int?
    public var scrollFrameIndex: Int?
    public var scrollIntervalMs: Int?
    public var uiFps: Int?
    public var scrollFps: Int?
    public var scrollTimelineId: String?
    public var scrollUploadComplete: Bool?
    public var scrollHasSourceText: Bool?

    public init(ok: Bool, error: String? = nil, code: Int? = nil, v: Int? = nil, cmd: String? = nil,
                color: String? = nil, brightness: Int? = nil, mode: String? = nil, playback: String? = nil,
                paused: Bool? = nil, autoIntervalMs: Int? = nil, autoFaceIndex: Int? = nil,
                frameBytes: Int? = nil, frameEncoding: String? = nil, queueCount: Int? = nil,
                lastReason: String? = nil, lit: Int? = nil, autoFaceId: String? = nil, autoFaceName: String? = nil,
                firmwareScrollActive: Bool? = nil, firmwareScrollPaused: Bool? = nil,
                firmwareScrollUserPaused: Bool? = nil, firmwareScrollSystemPaused: Bool? = nil,
                restoreAutoAfterScroll: Bool? = nil, scrollFrameCount: Int? = nil, scrollFrameIndex: Int? = nil,
                scrollIntervalMs: Int? = nil, uiFps: Int? = nil, scrollFps: Int? = nil,
                scrollTimelineId: String? = nil, scrollUploadComplete: Bool? = nil,
                scrollHasSourceText: Bool? = nil) {
        self.ok = ok
        self.error = error
        self.code = code
        self.v = v
        self.cmd = cmd
        self.color = color
        self.brightness = brightness
        self.mode = mode
        self.playback = playback
        self.paused = paused
        self.autoIntervalMs = autoIntervalMs
        self.autoFaceIndex = autoFaceIndex
        self.frameBytes = frameBytes
        self.frameEncoding = frameEncoding
        self.queueCount = queueCount
        self.lastReason = lastReason
        self.lit = lit
        self.autoFaceId = autoFaceId
        self.autoFaceName = autoFaceName
        self.firmwareScrollActive = firmwareScrollActive
        self.firmwareScrollPaused = firmwareScrollPaused
        self.firmwareScrollUserPaused = firmwareScrollUserPaused
        self.firmwareScrollSystemPaused = firmwareScrollSystemPaused
        self.restoreAutoAfterScroll = restoreAutoAfterScroll
        self.scrollFrameCount = scrollFrameCount
        self.scrollFrameIndex = scrollFrameIndex
        self.scrollIntervalMs = scrollIntervalMs
        self.uiFps = uiFps
        self.scrollFps = scrollFps
        self.scrollTimelineId = scrollTimelineId
        self.scrollUploadComplete = scrollUploadComplete
        self.scrollHasSourceText = scrollHasSourceText
    }
}

public struct ErrorReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String
    public var code: Int?
    public var expectedOffset: Int?

    public init(ok: Bool = false, error: String, code: Int? = nil, expectedOffset: Int? = nil) {
        self.ok = ok
        self.error = error
        self.code = code
        self.expectedOffset = expectedOffset
    }
}

// MARK: - Blob transfer replies (§3.3)

public struct BlobBeginReply: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var chunkMax: Int?
    public var offset: Int?

    public init(ok: Bool? = nil, chunkMax: Int? = nil, offset: Int? = nil) {
        self.ok = ok
        self.chunkMax = chunkMax
        self.offset = offset
    }
}

public struct BlobChunkReply: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var offset: Int?
    public var frames: Int?

    public init(ok: Bool? = nil, offset: Int? = nil, frames: Int? = nil) {
        self.ok = ok
        self.offset = offset
        self.frames = frames
    }
}

/// Reply to `BLOB_END` for `kind: "scroll"`.
public struct ScrollUploadReply: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var frames: Int?
    public var chunkFrames: Int?
    public var append: Bool?
    public var started: Bool?
    public var timelineId: String?
    public var uploadComplete: Bool?
    public var frameBytes: Int?
    public var scrollIntervalMs: Int?
    public var uiFps: Int?
    public var scrollFps: Int?
    /// `kind:"scroll_bitmap"` only (§7.1): the bitmap width the firmware expanded.
    public var width: Int?
    /// `kind:"scroll_bitmap"` only (§7.1): leading dark frames rotated to the
    /// end so index 0 is the first lit frame (0 when nothing lit).
    public var rotation: Int?

    public init(ok: Bool? = nil, frames: Int? = nil, chunkFrames: Int? = nil, append: Bool? = nil,
                started: Bool? = nil, timelineId: String? = nil, uploadComplete: Bool? = nil,
                frameBytes: Int? = nil, scrollIntervalMs: Int? = nil, uiFps: Int? = nil, scrollFps: Int? = nil,
                width: Int? = nil, rotation: Int? = nil) {
        self.ok = ok
        self.frames = frames
        self.chunkFrames = chunkFrames
        self.append = append
        self.started = started
        self.timelineId = timelineId
        self.uploadComplete = uploadComplete
        self.frameBytes = frameBytes
        self.scrollIntervalMs = scrollIntervalMs
        self.uiFps = uiFps
        self.scrollFps = scrollFps
        self.width = width
        self.rotation = rotation
    }
}

/// Reply to the incremental saved-face `CMD`s (§7.2): `face_rename`,
/// `face_reorder`, `face_delete`, `face_upsert`, `faces_clear_user`.
public struct FaceOpReply: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var v: Int?
    public var gen: Int?
    public var count: Int?

    public init(ok: Bool? = nil, v: Int? = nil, gen: Int? = nil, count: Int? = nil) {
        self.ok = ok
        self.v = v
        self.gen = gen
        self.count = count
    }
}

/// Reply to `BLOB_END` for `kind: "faces"`.
public struct FacesUploadReply: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var v: Int?
    public var path: String?
    public var bytes: Int?

    public init(ok: Bool? = nil, v: Int? = nil, path: String? = nil, bytes: Int? = nil) {
        self.ok = ok
        self.v = v
        self.path = path
        self.bytes = bytes
    }
}

// MARK: - `CMD get_info` (`handleGetInfo()`)

public struct DeviceInfo: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var device: String?
    public var fw: String?
    public var build: String?
    public var ledBackend: String?
    public var ledDma: Bool?
    public var heapFree: Int?
    public var psramFree: Int?
    public var psramSize: Int?
    public var uptimeMs: Int?
    public var proto: Int?

    public init(ok: Bool? = nil, device: String? = nil, fw: String? = nil, build: String? = nil,
                ledBackend: String? = nil, ledDma: Bool? = nil, heapFree: Int? = nil, psramFree: Int? = nil,
                psramSize: Int? = nil, uptimeMs: Int? = nil, proto: Int? = nil) {
        self.ok = ok
        self.device = device
        self.fw = fw
        self.build = build
        self.ledBackend = ledBackend
        self.ledDma = ledDma
        self.heapFree = heapFree
        self.psramFree = psramFree
        self.psramSize = psramSize
        self.uptimeMs = uptimeMs
        self.proto = proto
    }
}

// MARK: - `EV_LOG` (0x94) — `{"level":"I","tag":"…","msg":"…"}`, docs §3.5

public struct RinaLogEvent: Codable, Equatable, Sendable {
    public var level: String?
    public var tag: String?
    public var msg: String?

    public init(level: String? = nil, tag: String? = nil, msg: String? = nil) {
        self.level = level
        self.tag = tag
        self.msg = msg
    }
}
