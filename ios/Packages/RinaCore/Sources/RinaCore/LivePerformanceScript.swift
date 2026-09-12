import Foundation

/// One entry of a `.rinalive` script: at `frame` (in units of `1/fps` seconds)
/// the board's face becomes `call`.
public struct LiveKeyframe: Equatable, Sendable {
    public let frame: Int
    public let call: PartsCall

    public init(frame: Int, call: PartsCall) {
        self.frame = frame
        self.call = call
    }
}

/// A parsed keyframe-driven face performance, ported from flyAkari/RinaChanBoard's
/// `PresetLiveActivity` (GPLv3). Upstream ships these as plain-text `.txt`
/// scripts bundled alongside an audio track: each line is a millisecond-ish
/// "frame" tick (at a fixed `fps`, defaulting to upstream's constant of 10)
/// followed by the four selected-part ids for that instant, and playback is
/// driven off the audio element's `currentTime` rather than a free-running
/// timer, so the face never drifts from the voice. This type only carries the
/// parsed, resolved keyframes; `PresetLiveModel` supplies the clock.
public struct LivePerformanceScript: Equatable, Sendable {
    public let title: String?
    public let fps: Int
    /// Strictly increasing by `frame`. Never empty: enforced by `make(title:fps:keyframes:)`,
    /// the only way to construct one.
    public let keyframes: [LiveKeyframe]

    private init(title: String?, fps: Int, keyframes: [LiveKeyframe]) {
        self.title = title
        self.fps = fps
        self.keyframes = keyframes
    }

    /// The only public constructor. Throws `.empty` rather than allowing the
    /// "never empty" invariant above to be violated; every other member
    /// assumes `keyframes` is non-empty and traps otherwise.
    public static func make(title: String?, fps: Int, keyframes: [LiveKeyframe]) throws -> LivePerformanceScript {
        guard !keyframes.isEmpty else { throw LivePerformanceScriptError.empty }
        return LivePerformanceScript(title: title, fps: fps, keyframes: keyframes)
    }

    /// The wall-clock time of `keyframes[index]`, in milliseconds.
    public func timeMs(ofKeyframeAt index: Int) -> Int {
        keyframes[index].frame * 1000 / fps
    }

    /// The index of the last keyframe whose time is `<= ms`, or `nil` if `ms`
    /// is before the first keyframe. This is the lookup `PresetLiveModel`
    /// performs every clock tick against the audio player's live position.
    public func index(atMs ms: Int) -> Int? {
        guard !keyframes.isEmpty, ms >= timeMs(ofKeyframeAt: 0) else { return nil }
        var lo = 0
        var hi = keyframes.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if timeMs(ofKeyframeAt: mid) <= ms {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    /// The time of the final keyframe, in milliseconds.
    public var durationMs: Int {
        timeMs(ofKeyframeAt: keyframes.count - 1)
    }

    /// Composes every keyframe once, in order, so playback never has to call
    /// `PartsLibrary.compose(call:)` on the hot path.
    public func composedFrames(using library: PartsLibrary) -> [PackedFrame] {
        keyframes.map { library.compose(call: $0.call) }
    }
}

public enum LivePerformanceScriptError: Error, Equatable {
    case empty
    case badFps(line: Int, text: String)
    case badKeyframe(line: Int, text: String)
    case unknownPart(line: Int, group: PartGroup, value: String)
    case nonMonotonicFrame(line: Int, frame: Int)
    /// `frame` exceeded `LivePerformanceScriptParser.maxFrame`. Guards against
    /// `frame * 1000` overflowing in `timeMs(ofKeyframeAt:)`.
    case frameTooLarge(line: Int, text: String)
}

/// Parser for flyAkari/RinaChanBoard's `.rinalive`/`PresetLiveActivity` line
/// format:
/// ```
/// # comment
/// #fps 10
/// #title poppin_up
/// 0!101,201,301,400
/// 3!102,202,305,401
/// ```
/// flyAkari's `sendCurrentCode` emits a trailing comma on the wire
/// (`"3,3,7,1,"`), and its keyframe values are small display indices into
/// each group's callable id list rather than our own numeric ids, so both
/// forms are accepted (see `resolve(_:group:library:)`).
public enum LivePerformanceScriptParser {
    /// flyAkari's default playback rate (`PresetLiveActivity` ~`FPS = 10`)
    /// when a script omits `#fps`.
    public static let defaultFps = 10

    /// Generous upper bound on a keyframe's `frame` value: at 60 fps this is
    /// still ~46 hours of performance, and it leaves no headroom for
    /// `frame * 1000` (in `timeMs(ofKeyframeAt:)`) to overflow `Int`.
    public static let maxFrame = 10_000_000

    public static func parse(_ text: String, library: PartsLibrary) throws -> LivePerformanceScript {
        var fps = defaultFps
        var title: String?
        var keyframes: [LiveKeyframe] = []
        var lastFrame: Int?

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard let spaceIndex = body.firstIndex(where: { $0.isWhitespace }) else {
                    continue // a bare comment line
                }
                let directive = body[body.startIndex..<spaceIndex].lowercased()
                let value = body[spaceIndex...].trimmingCharacters(in: .whitespaces)
                switch directive {
                case "fps":
                    guard let parsed = Int(value), (1...60).contains(parsed) else {
                        throw LivePerformanceScriptError.badFps(line: lineNumber, text: line)
                    }
                    fps = parsed
                case "title":
                    title = value
                default:
                    continue // unrecognised directive: treat as a comment
                }
                continue
            }

            guard let bangIndex = line.firstIndex(of: "!") else {
                throw LivePerformanceScriptError.badKeyframe(line: lineNumber, text: line)
            }
            let frameText = line[line.startIndex..<bangIndex].trimmingCharacters(in: .whitespaces)
            guard let frame = Int(frameText), frame >= 0 else {
                throw LivePerformanceScriptError.badKeyframe(line: lineNumber, text: line)
            }
            guard frame <= maxFrame else {
                throw LivePerformanceScriptError.frameTooLarge(line: lineNumber, text: line)
            }
            if let lastFrame, frame <= lastFrame {
                throw LivePerformanceScriptError.nonMonotonicFrame(line: lineNumber, frame: frame)
            }

            var valuesText = line[line.index(after: bangIndex)...].trimmingCharacters(in: .whitespaces)
            if valuesText.hasSuffix(",") {
                valuesText.removeLast()
            }
            let rawValues = valuesText.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard rawValues.count == 4 else {
                throw LivePerformanceScriptError.badKeyframe(line: lineNumber, text: line)
            }

            let groups: [PartGroup] = [.leye, .reye, .mouth, .cheek]
            var resolved: [PartGroup: String] = [:]
            for (group, value) in zip(groups, rawValues) {
                resolved[group] = try resolve(value, group: group, library: library, line: lineNumber)
            }

            let call = PartsCall(
                leye: resolved[.leye]!, reye: resolved[.reye]!,
                mouth: resolved[.mouth]!, cheek: resolved[.cheek]!
            )
            keyframes.append(LiveKeyframe(frame: frame, call: call))
            lastFrame = frame
        }

        return try LivePerformanceScript.make(title: title, fps: fps, keyframes: keyframes)
    }

    /// Resolves one raw value against `group`'s callable id list: first as a
    /// literal id (our own scripts), then as a display index into that list
    /// (flyAkari's small sprite indices), else throws.
    private static func resolve(
        _ value: String, group: PartGroup, library: PartsLibrary, line: Int
    ) throws -> String {
        let ids = library.ids(for: group)
        if ids.contains(value) {
            return value
        }
        if let index = Int(value), index >= 0, index < ids.count {
            return library.callId(at: index, in: group)
        }
        throw LivePerformanceScriptError.unknownPart(line: line, group: group, value: value)
    }
}
