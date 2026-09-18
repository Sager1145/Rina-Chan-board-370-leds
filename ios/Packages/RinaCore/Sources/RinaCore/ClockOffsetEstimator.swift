import Foundation

/// One `clock_sample` round trip (BOARD_GROUP_SPEC.md §1.3/§2): `m1`/`m4` are
/// phone monotonic microseconds around the request, `b2`/`b3` are the board's
/// `rxUs`/`txUs` from the reply.
public struct ClockSample: Sendable, Equatable {
    public let m1: Int64
    public let b2: Int64
    public let b3: Int64
    public let m4: Int64

    public init(m1: Int64, b2: Int64, b3: Int64, m4: Int64) {
        self.m1 = m1
        self.b2 = b2
        self.b3 = b3
        self.m4 = m4
    }

    /// `(m4 - m1) - (b3 - b2)`.
    public var rttUs: Int64 { (m4 - m1) - (b3 - b2) }
    /// `((b2 - m1) + (b3 - m4)) / 2`; board time = phone time + `offsetUs`.
    public var offsetUs: Int64 { ((b2 - m1) + (b3 - m4)) / 2 }
}

/// Estimates a board's clock offset from a rolling window of `clock_sample`
/// round trips (BOARD_GROUP_SPEC.md §2): the estimate is the offset of the
/// minimum-RTT sample among the last `maxSamples` (default 8). All samples
/// are discarded whenever the board's `bootId` changes (a reboot/deep-sleep
/// wake invalidates any previous offset).
public struct ClockOffsetEstimator: Sendable, Equatable {
    public let maxSamples: Int
    public private(set) var bootId: String?
    public private(set) var samples: [ClockSample] = []

    public init(maxSamples: Int = 8) {
        self.maxSamples = maxSamples
    }

    /// Records `sample` for `bootId`. If `bootId` differs from the last one
    /// seen, all previous samples are discarded first (asymmetric-delay
    /// history from a prior boot must never leak into the new estimate).
    public mutating func addSample(_ sample: ClockSample, bootId: String) {
        if self.bootId != bootId {
            samples.removeAll()
            self.bootId = bootId
        }
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Discards all recorded samples without forgetting `bootId`. Callers use
    /// this before a fresh re-anchor sampling burst (BOARD_GROUP_SPEC §3's
    /// periodic re-anchor) so a stale low-RTT sample from a much earlier
    /// burst can't keep winning the "minimum RTT of the last `maxSamples`"
    /// selection over a fresher, more representative one.
    public mutating func removeAllSamples() {
        samples.removeAll()
    }

    private var bestSample: ClockSample? {
        samples.min { $0.rttUs < $1.rttUs }
    }

    /// RTT of the minimum-RTT sample among the last `maxSamples`, or `nil` with no samples.
    public var bestRttUs: Int64? { bestSample?.rttUs }
    /// Offset of the minimum-RTT sample among the last `maxSamples`, or `nil` with no samples.
    public var offsetUs: Int64? { bestSample?.offsetUs }

    /// Maps a phone monotonic time to the corresponding board time (`board = phone + offsetUs`).
    public func boardTime(forPhone phoneUs: Int64) -> Int64? {
        guard let offsetUs else { return nil }
        return phoneUs + offsetUs
    }

    /// Maps a board time back to the corresponding phone monotonic time.
    public func phoneTime(forBoard boardUs: Int64) -> Int64? {
        guard let offsetUs else { return nil }
        return boardUs - offsetUs
    }
}
