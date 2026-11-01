import Foundation
import HackbanKit
import Security

/// Credentials per account, as generic passwords under this app's service.
enum Keychain {
    static let service = "com.hackclub.hackban-desktop"

    static func load(_ account: String) -> AccountCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AccountCredentials.self, from: data)
    }

    static func save(_ account: String, _ creds: AccountCredentials?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let creds, let data = try? JSONEncoder().encode(creds) else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Hackban sign-in"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
