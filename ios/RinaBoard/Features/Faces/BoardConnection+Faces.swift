import Foundation
import RinaCore

/// Faces-tab-only helpers layered on `BoardConnection` (FEATURE_INVENTORY §B).
/// Kept separate from the shared service so ownership stays with this feature.
extension BoardConnection {
    /// `apply_saved_face{index, id}` (B10): `index` is the position of the
    /// face in the firmware-sorted (order, array-index) face list; `id`, when
    /// given, lets newer firmware apply the face by its stable id regardless
    /// of `index` (older firmware ignores it and falls back to `index`).
    @discardableResult
    public func applySavedFace(index: Int, id: String? = nil) async throws -> CommandReply {
        try await command(.applySavedFace(index: index, id: id, reason: nil, playback: nil))
    }
}
