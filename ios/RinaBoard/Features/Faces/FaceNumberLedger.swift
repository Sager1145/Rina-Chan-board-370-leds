import Foundation

/// Pure, Codable allocation state; independent of SwiftUI and Observation.
/// Display numbers (e.g. F000017) are a stable, app-local convenience over
/// `SavedFace.id`: assigned once per id/scope, never reassigned by a rename
/// or a reorder, and never recycled after a delete.
struct FaceNumberLedger: Codable {
    private struct Bucket: Codable {
        var next = 1
        var byID: [String: Int] = [:]
    }
    private var version = 1
    private var scopes: [String: Bucket] = [:]

    var isValid: Bool {
        version == 1 && scopes.values.allSatisfy { bucket in
            bucket.next > 0
                && bucket.byID.values.allSatisfy { $0 > 0 && $0 < bucket.next }
                && Set(bucket.byID.values).count == bucket.byID.count
        }
    }

    @discardableResult
    mutating func ensureNumbers(for ids: [String], scope: String) throws -> Bool {
        guard isValid else { throw LedgerError.invalidArchive }
        var bucket = scopes[scope] ?? Bucket()
        var changed = false
        for id in ids where bucket.byID[id] == nil {
            guard bucket.next < Int.max else { throw LedgerError.overflow }
            bucket.byID[id] = bucket.next
            bucket.next += 1
            changed = true
        }
        if changed { scopes[scope] = bucket }
        return changed
    }

    func number(for id: String, scope: String) -> Int? { scopes[scope]?.byID[id] }
    enum LedgerError: Error { case invalidArchive, overflow }
}
