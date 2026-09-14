import Foundation
import RinaCore

/// The app destination that best represents the board's current firmware state.
///
/// This intentionally derives only from firmware state. It must not consult a
/// locally remembered tab or uploaded scroll metadata: those can outlive the
/// activity that produced them.
enum BoardResumeMode: Equatable, Sendable {
    case control
    case text
    case lipSync
    case performance
    case video

    /// Resolves the firmware activity represented by the freshest available
    /// status snapshot. `DeviceStatus.v` and `PreviewSync.v` are the firmware
    /// state version, so they let a newer preview supersede an older status.
    static func resolve(status: DeviceStatus, preview: PreviewSync?) -> Self? {
        let snapshot = Snapshot(status: status, preview: preview)

        // Newer firmware reports persistent ownership directly. Unlike frame
        // reasons, this survives a frozen live frame and cannot be changed by
        // a brightness or auto-interval button press.
        if let outputMode = Self(outputMode: snapshot.outputMode) {
            return outputMode
        }

        // The runtime flag is the only scroll-ownership signal. Do not infer
        // text playback from scroll frame counts, timeline metadata, or a
        // historical presentation sample: uploads persist after scrolling ends.
        if snapshot.firmwareScrollActive == true {
            return .text
        }

        guard let mode = snapshot.mode?.lowercased() else { return nil }
        switch mode {
        case "auto":
            return .control
        case "manual":
            break
        default:
            return nil
        }

        // The external live producers currently send idle frames. Other
        // playback states are firmware-owned or generic paused state, and do
        // not establish a live feature owner.
        guard snapshot.playback?.lowercased() == "idle" else {
            return .control
        }

        switch snapshot.lastReason?.split(separator: ":").first?.lowercased() {
        case "lipsync":
            return .lipSync
        case "live_preset":
            return .performance
        case "video":
            return .video
        default:
            return .control
        }
    }

    /// The identity and progress of the resumed external stream. These values
    /// come from the same firmware snapshot selected for `resolve`, so a
    /// delayed preview cannot pair a current mode with an earlier stream.
    static func streamState(status: DeviceStatus, preview: PreviewSync?) ->
        (id: String?, positionMs: Int?) {
        let snapshot = Snapshot(status: status, preview: preview)
        if snapshot.outputMode == nil, let reason = snapshot.lastReason {
            // An updated app can still attach identity to SET_FRAME reasons
            // when talking to firmware predating the dedicated fields.
            let fields = reason.split(separator: ":", omittingEmptySubsequences: false)
            if fields.count == 3, UUID(uuidString: String(fields[1])) != nil,
               let position = Int(fields[2]), position >= 0 {
                return (String(fields[1]), position)
            }
        }
        return (snapshot.outputStreamID, snapshot.outputPositionMs)
    }

    static func isPlaybackPaused(status: DeviceStatus, preview: PreviewSync?) -> Bool {
        Snapshot(status: status, preview: preview).playback == "paused"
    }

    private init?(outputMode: String?) {
        switch outputMode?.lowercased() {
        case "control": self = .control
        case "text": self = .text
        case "lipsync": self = .lipSync
        case "performance": self = .performance
        case "video": self = .video
        default: return nil
        }
    }
}

private extension BoardResumeMode {
    struct Snapshot {
        let outputMode: String?
        let outputStreamID: String?
        let outputPositionMs: Int?
        let mode: String?
        let playback: String?
        let lastReason: String?
        let firmwareScrollActive: Bool?

        init(status: DeviceStatus, preview: PreviewSync?) {
            let renderer = status.renderer
            let statusVersion = status.v ?? status.version
            let previewIsNewer: Bool
            if let statusVersion, let previewVersion = preview?.v {
                previewIsNewer = previewVersion > statusVersion
            } else {
                previewIsNewer = renderer == nil
            }

            if previewIsNewer, let preview {
                outputMode = preview.outputMode
                outputStreamID = preview.outputStreamID
                outputPositionMs = preview.outputPositionMs
                mode = preview.mode
                playback = preview.playback
                lastReason = preview.lastReason
                firmwareScrollActive = preview.firmwareScrollActive
            } else if let renderer {
                outputMode = renderer.outputMode
                outputStreamID = renderer.outputStreamID
                outputPositionMs = renderer.outputPositionMs
                mode = renderer.mode
                playback = renderer.playback
                lastReason = renderer.lastReason
                firmwareScrollActive = renderer.firmwareScrollActive
            } else if let preview {
                outputMode = preview.outputMode
                outputStreamID = preview.outputStreamID
                outputPositionMs = preview.outputPositionMs
                mode = preview.mode
                playback = preview.playback
                lastReason = preview.lastReason
                firmwareScrollActive = preview.firmwareScrollActive
            } else {
                outputMode = nil
                outputStreamID = nil
                outputPositionMs = nil
                mode = nil
                playback = nil
                lastReason = nil
                firmwareScrollActive = nil
            }
        }
    }
}
