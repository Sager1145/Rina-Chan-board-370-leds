import Foundation
import Security

/// Tiny wrapper over `SecItem*` for the iPhone Personal Hotspot password
/// (RINALINK_PROTOCOL_V1 §8): iOS never exposes the Personal Hotspot
/// password to apps, so once the user types it in we keep it in the
/// Keychain (never logged, never persisted anywhere else) so re-provisioning
/// the board doesn't require re-typing it every time.
public enum KeychainStore {
    private static let service = "com.rinachan.board.hotspot"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Saves `password` under `account` (the hotspot SSID), overwriting any
    /// existing entry for the same account.
    @discardableResult
    public static func save(password: String, account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        var attributes = query(account: account)
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        guard addStatus == errSecDuplicateItem else { return false }
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query(account: account) as CFDictionary, update as CFDictionary)
        return updateStatus == errSecSuccess
    }

    /// Loads the password saved for `account`, or `nil` if none exists.
    public static func load(account: String) -> String? {
        var attributes = query(account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the password saved for `account`, if any.
    @discardableResult
    public static func delete(account: String) -> Bool {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
