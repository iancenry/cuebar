import Foundation
import Security

/// One key, in the login keychain, under Cuebar's own service name.
///
/// `kSecAttrAccessibleWhenUnlocked`: a rehearsal tool does not need a key at
/// 3am while the Mac is asleep, and a key that can be read while the machine
/// is locked is a key that leaks with a stolen laptop.
enum Keychain {
    static let service = "com.cuebar.scripttools"

    /// Whether a key exists, without reading it.
    ///
    /// A settings pane needs to say "a key is saved" and nothing more, and the
    /// cheapest way to be sure is not to fetch the secret into a property to
    /// find out — the pane lives as long as the window is open.
    static func hasKey(_ account: String) -> Bool {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
        #else
        return false
        #endif
    }

    static func read(_ account: String) -> String? {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    @discardableResult
    static func write(_ secret: String, _ account: String) -> Bool {
        #if os(macOS)
        guard let data = secret.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    static func delete(_ account: String) {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}