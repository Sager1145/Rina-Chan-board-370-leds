import Foundation
import RinaCore

/// Explicit left↔right eye LED mapping for the "Sync Eyes" editing mode
/// (design guide §47).
///
/// The mapping is **not** assumed to be a naive reflection of the whole board.
/// It is derived from the parts library's own layout boxes — `eye_left` sits
/// at x 2…9 and `eye_right` at x 12…19, both 8×8 on rows 1…8 — and is then
/// corroborated against the shipped part data: left-eye variants pushed
/// through the candidate mapping must reproduce the right-eye variant at the
/// same display index.
///
/// Agreement is required from a strong majority rather than every pair,
/// because some pairs are *intentionally* asymmetric — variants 122/222 are a
/// "?" and a "!" eye, not mirror images. A genuinely wrong mapping (a
/// translation instead of a reflection, or a future board that rewires the
/// eyes) disagrees on nearly every pair, so the majority test still catches
/// it; when it fails, LED-level eye sync is disabled rather than silently
/// mirroring the wrong pixels, and part-level sync still works through
/// `PartsLibrary.mirroredEyeId`.
struct EyeTopology {
    /// Logical LED index → its partner on the other eye. Symmetric: the map
    /// contains both directions.
    private let partner: [Int: Int]

    /// One entry per pair, oriented left eye → right eye. Needed when a
    /// mirror has a direction (projecting the left eye onto the right),
    /// which the symmetric `partner` map cannot express.
    let leftToRightPairs: [(left: Int, right: Int)]

    func mirroredLED(of led: Int) -> Int? { partner[led] }

    var ledCount: Int { partner.count }

    static func make(from library: PartsLibrary) -> EyeTopology? {
        guard let left = library.layout[PartGroup.leye.partType]?.first,
              let right = library.layout[PartGroup.reye.partType]?.first,
              left.w == right.w, left.h == right.h, left.y == right.y
        else { return nil }

        // Candidate mapping: the two boxes hold mirror-image artwork, so
        // column `i` from the left edge of one box pairs with column `i` from
        // the *right* edge of the other.
        var partner: [Int: Int] = [:]
        var leftToRightPairs: [(left: Int, right: Int)] = []
        for row in 0..<left.h {
            let y = left.y + row
            for column in 0..<left.w {
                let leftX = left.x + column
                let rightX = right.x + (right.w - 1 - column)
                guard let leftLED = MatrixGeometry.ledIndex(x: leftX, y: y),
                      let rightLED = MatrixGeometry.ledIndex(x: rightX, y: y)
                else { return nil }
                partner[leftLED] = rightLED
                partner[rightLED] = leftLED
                leftToRightPairs.append((left: leftLED, right: rightLED))
            }
        }
        let topology = EyeTopology(partner: partner, leftToRightPairs: leftToRightPairs)
        guard topology.matchesShippedVariants(in: library) else { return nil }
        return topology
    }

    /// Fraction of non-empty variant pairs that must mirror exactly. The
    /// shipped data agrees on 26 of 27 pairs; a wrong mapping agrees on
    /// almost none.
    private static let requiredAgreement = 0.8

    private func matchesShippedVariants(in library: PartsLibrary) -> Bool {
        let leftIds = library.ids(for: .leye)
        let rightIds = library.ids(for: .reye)
        guard leftIds.count == rightIds.count else { return false }

        var compared = 0
        var agreed = 0
        for index in leftIds.indices {
            let leftFrame = library.frame(for: library.resolvedPart(group: .leye, id: leftIds[index]))
            let rightFrame = library.frame(for: library.resolvedPart(group: .reye, id: rightIds[index]))
            guard leftFrame.litCount > 0 || rightFrame.litCount > 0 else { continue }
            compared += 1

            var projected = PackedFrame()
            var withinBoxes = true
            for led in 0..<PackedFrame.ledCount where leftFrame[led] {
                guard let mirrored = partner[led] else { withinBoxes = false; break }
                projected.set(mirrored)
            }
            // A lit LED outside the eye boxes means the boxes themselves are
            // wrong, which no amount of agreement elsewhere can excuse.
            guard withinBoxes else { return false }
            if projected == rightFrame { agreed += 1 }
        }
        guard compared >= 4 else { return false }
        return Double(agreed) / Double(compared) >= Self.requiredAgreement
    }
}
