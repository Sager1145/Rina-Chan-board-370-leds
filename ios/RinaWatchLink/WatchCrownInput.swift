import Foundation

/// Keeps confirmed phone snapshots separate from crown/button input. Only
/// user input returns a changed command value; synchronization moves the
/// crown origin without quantizing the confirmed value or sending anything.
struct WatchCrownInput {
    private(set) var crownValue: Double
    let range: ClosedRange<Double>
    let step: Double

    init(value: Double, range: ClosedRange<Double>, step: Double) {
        crownValue = value
        self.range = range
        self.step = step
    }

    mutating func synchronize(_ confirmedValue: Double) {
        crownValue = confirmedValue
    }

    mutating func turn(to raw: Double, confirmedValue: Double) -> Double? {
        crownValue = raw
        let next = snapped(raw)
        return next == confirmedValue ? nil : next
    }

    mutating func adjust(by delta: Double, confirmedValue: Double) -> Double? {
        let next = snapped(confirmedValue + delta)
        crownValue = next
        return next == confirmedValue ? nil : next
    }

    private func snapped(_ raw: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, raw))
        let steps = ((clamped - range.lowerBound) / step).rounded()
        return min(range.upperBound, range.lowerBound + steps * step)
    }
}
