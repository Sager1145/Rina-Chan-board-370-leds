import Foundation

/// The wire format between the iPhone app and its Apple Watch companion.
///
/// Compiled into both the `RinaBoard` (iOS) and `RinaBoardWatch` targets —
/// this folder is a filesystem-synchronized group listed by both — so the two
/// sides can never disagree about a field name. Everything here is a plain
/// `Codable` value: WatchConnectivity carries property-list dictionaries, so
/// each message travels as one JSON `Data` blob under `WatchLinkCodec.payloadKey`
/// next to a version number, which keeps the transport layer a single
/// encode/decode call on either side.
///
/// The watch never pairs with a board itself: every command below is executed
/// by the phone against the boards *it* is connected to, and every snapshot is
/// the phone's view of that state.
enum WatchLinkCodec {
    static let version = 1
    static let versionKey = "v"
    static let payloadKey = "rinaWatchLink"

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }

    /// Wraps an encoded payload in the dictionary WatchConnectivity carries.
    static func envelope(_ payload: Data) -> [String: Any] {
        [versionKey: version, payloadKey: payload]
    }

    /// The payload of an envelope, or `nil` when the dictionary is not ours
    /// (or comes from a newer, incompatible version).
    static func payload(in envelope: [String: Any]) -> Data? {
        guard let v = envelope[versionKey] as? Int, v == version else { return nil }
        return envelope[payloadKey] as? Data
    }
}

/// Which of the phone's boards the watch is driving. The watch keeps its own
/// choice on the phone side (`WatchLinkService.selectedTargetID`); selecting a
/// board here never changes the phone's own "控制对象"/active session, so the
/// phone keeps running whatever it was doing on its board.
struct WatchTargetChoice: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// Whatever the phone is currently controlling (its active board, or
        /// its synced group). The default.
        case phone
        case board
        case group
    }

    /// `phone` for the follow-the-phone entry, `board:<session id>` or
    /// `group:<group id>` otherwise.
    var id: String
    var kind: Kind
    var name: String
    var isConnected: Bool
    /// Boards: 1. Groups: connected members / all members.
    var connectedCount: Int
    var memberCount: Int

    static let phoneID = "phone"
}

/// The phone's view of the watch's target, pushed to the watch whenever any
/// of it changes and returned as the reply to every command.
struct WatchBoardSnapshot: Codable, Equatable, Sendable {
    struct Board: Codable, Equatable, Sendable {
        var name: String
        var isConnected: Bool
        var batteryPercent: Int?
        var isCharging: Bool
        /// Groups only: how many members the readouts and commands reach.
        var connectedCount: Int
        var memberCount: Int
    }

    struct ColorSwatch: Codable, Equatable, Sendable, Identifiable {
        var id: String { hex }
        var name: String
        var hex: String
    }

    struct Controls: Codable, Equatable, Sendable {
        var brightnessRaw: Int
        var brightnessMin: Int
        var brightnessMax: Int
        var isAutoMode: Bool
        var autoIntervalSeconds: Double
        var autoIntervalMinSeconds: Double
        var autoIntervalMaxSeconds: Double
        var colorHex: String
        var faceIndex: Int?
        var faceCount: Int?
        var presets: [ColorSwatch]
        /// True while the target board is running a scroll — the only time the
        /// speed control does anything.
        var isScrollActive: Bool
        var scrollFps: Int?
        var scrollFpsMin: Int
        var scrollFpsMax: Int
    }

    struct LipSync: Codable, Equatable, Sendable {
        enum Permission: String, Codable, Sendable {
            case undetermined, granted, denied
        }
        var isRunning: Bool
        var isStarting: Bool
        /// Mirrors `LipSyncModel.canEditOptions`: the sensitivity may only move
        /// while no analysis loop is reading it.
        var canEditOptions: Bool
        var sensitivityDb: Double
        var sensitivityMinDb: Double
        var sensitivityMaxDb: Double
        var permission: Permission
        /// False when the target cannot take lip sync from the watch (an
        /// unsynced group has no single board for the phone's microphone to
        /// drive).
        var isAvailable: Bool
    }

    var targets: [WatchTargetChoice]
    var selectedTargetID: String
    var board: Board
    var controls: Controls
    var lipSync: LipSync
    var errorMessage: String?
}

/// One action from the watch. The phone executes it against the watch's
/// selected target and replies with a fresh `WatchBoardSnapshot`.
enum WatchCommand: Codable, Equatable, Sendable {
    case requestState
    case selectTarget(id: String)
    case setBrightness(raw: Int)
    case stepFace(direction: Int)
    case setAutoMode(enabled: Bool)
    case setAutoInterval(seconds: Double)
    case setColor(hex: String)
    case setScrollFps(fps: Int)
    case lipSyncStart
    case lipSyncStop
    case setLipSyncSensitivity(db: Double)
}
