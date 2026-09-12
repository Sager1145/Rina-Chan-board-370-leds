import CoreGraphics

/// Layout constants shared by more than one feature.
///
/// Named `AppLayout`, not `Layout`: a module-level `Layout` would shadow
/// SwiftUI's `Layout` protocol inside this target and turn any future custom
/// layout conformance into a baffling "inheritance from non-protocol type".
enum AppLayout {
    /// Apple's minimum comfortable hit target. Controls draw smaller
    /// chrome inside a frame this size — a 32pt ring, a 30pt swatch — so
    /// the touch area never shrinks with the artwork.
    static let minimumTapTarget: CGFloat = 44
}
