import AVFoundation
import Foundation

/// All app audio-session and microphone lifecycle operations share one FIFO
/// queue: AVAudioSession activation can block, and must never block the UI.
enum AudioSessionWork {
    static let queue = DispatchQueue(label: "rina.audio-session", qos: .userInitiated)
}

/// Playback holders are accessed only on AudioSessionWork.queue.
enum PlaybackAudioSession {
    enum Holder: Hashable, Sendable {
        case performance, video
    }

    nonisolated(unsafe) private static var holders = Set<Holder>()

    @MainActor
    static func acquire(_ holder: Holder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            AudioSessionWork.queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default)
                    try session.setActive(true)
                    holders.insert(holder)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func release(_ holder: Holder) {
        AudioSessionWork.queue.async {
            guard holders.remove(holder) != nil, holders.isEmpty,
                  AVAudioSession.sharedInstance().category == .playback else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
