import Foundation
import os

/// Signposts for Instruments (Points of Interest / os_signpost). Intervals cost
/// almost nothing when no profiler is attached.
enum RinaPerf {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: .pointsOfInterest)
}
