import Foundation
import RinaCore

/// Faces-tab-only helpers layered on `BoardConnection` (FEATURE_INVENTORY §B).
/// Kept separate from the shared service so ownership stays with this feature.
extension BoardConnection {
    /// `apply_saved_face{index}` (B10): `index` is the position of the face in
    /// the firmware-sorted (order, array-index) face list.
    @discardableResult
    public func applySavedFace(index: Int) async throws -> CommandReply {
        try await command(.applySavedFace(index: index, reason: nil, playback: nil))
    }

    /// Loads the on-board face library (B10), falling back to the bundled
    /// default set when the board can't be reached.
    public func loadFaceDocument(bundle: Bundle = .main) async -> FaceDocument {
        if let data = try? await getFaces(), let doc = try? FaceDocument(jsonData: data) {
            return doc
        }
        return (try? RinaResources.defaultFaces(bundle: bundle)) ?? FaceDocument()
    }
}
