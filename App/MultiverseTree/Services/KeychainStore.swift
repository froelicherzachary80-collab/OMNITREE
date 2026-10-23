import Foundation
import Security

/// Minimal Keychain wrapper for the database encryption key and API keys.
/// Items are device-only (`…ThisDeviceOnly`) so they never sync or appear in backups.
enum KeychainStore {
    static let service = "com.multiversetree.app"

    static func data(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func set(_ data: Data?, for account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let data else { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func string(_ account: String) -> String? { data(account).flatMap { String(data: $0, encoding: .utf8) } }
    static func setString(_ s: String?, for account: String) { set(s.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, for: account) }

    /// 256-bit key for AES-GCM encryption of private person data. Created on first launch.
    static func databaseKey() -> Data {
        if let k = data("db-field-key"), k.count == 32 { return k }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes)
        set(key, for: "db-field-key")
        return key
    }
}
