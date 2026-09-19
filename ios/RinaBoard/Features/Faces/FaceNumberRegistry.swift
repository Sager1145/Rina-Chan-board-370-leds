import Foundation
import Observation

/// App-local display numbers. The wire identity remains `SavedFace.id`.
/// Shared on the main actor across all app windows. Numbers are scoped by
/// "local" or the connected board's physical id (see `FaceLibraryView`'s
/// `currentScope`) and are never recycled after deletion — this is an
/// in-app convenience label, not a cross-device/cross-install protocol field.
@Observable @MainActor
final class FaceNumberRegistry {
    static let shared = FaceNumberRegistry()
    private let defaults: UserDefaults
    private let key: String
    private var ledger = FaceNumberLedger()
    private(set) var errorMessage: String?

    init(defaults: UserDefaults = .standard,
         key: String = "RinaBoard.FaceDisplayNumbers.v1") {
        self.defaults = defaults
        self.key = key
        guard let data = defaults.data(forKey: key) else { return }
        do {
            let decoded = try JSONDecoder().decode(FaceNumberLedger.self, from: data)
            guard decoded.isValid else { throw FaceNumberLedger.LedgerError.invalidArchive }
            ledger = decoded
        } catch {
            // A corrupt file must never silently renumber an existing library.
            errorMessage = NSLocalizedString("无法读取表情编号；原始 ID 仍可使用", comment: "face number registry corrupt")
        }
    }

    func ensureNumbers(for ids: [String], scope: String) {
        guard errorMessage == nil else { return }
        var candidate = ledger
        do {
            guard try candidate.ensureNumbers(for: ids, scope: scope) else { return }
            let data = try JSONEncoder().encode(candidate)
            defaults.set(data, forKey: key)
            ledger = candidate
        } catch {
            errorMessage = NSLocalizedString("无法分配表情编号", comment: "face number allocation failed")
        }
    }

    func number(for id: String, scope: String) -> Int? { ledger.number(for: id, scope: scope) }
}
