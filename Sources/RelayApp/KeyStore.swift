import Foundation
import Security
import LocalAuthentication

/// Serializes blocking Security calls away from the main actor. A denied read
/// returns without a password dialog; it never changes the item's access rules.
actor KeyStore {
    static let shared = KeyStore()
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.relay.agent", kSecAttrAccount as String: "Jev · TypeSafe"] }
    private func withoutInteraction<T>(_ body: () throws -> T) throws -> T {
        // The existing item uses the macOS file-based keychain. LAContext alone
        // does not reliably suppress that implementation's authentication UI.
        var previous = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw NSError(domain: "RelayKeychain", code: Int(errSecInteractionNotAllowed), userInfo: [NSLocalizedDescriptionKey: "Keychain access is unavailable. Use the key for this session instead."])
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try body()
    }
    func contains() -> Bool {
        (try? withoutInteraction {
        var q = query; q[kSecReturnAttributes as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
        }) ?? false
    }
    func read() -> String? {
        try? withoutInteraction {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        }
    }
    func save(_ key: String) throws {
        try withoutInteraction {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw NSError(domain: "RelayKeychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keychain could not save the key."]) }
        } else if status != errSecSuccess { throw NSError(domain: "RelayKeychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain did not allow saving the key."]) }
        }
    }
}
