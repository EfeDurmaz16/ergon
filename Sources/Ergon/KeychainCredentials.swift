#if canImport(Security)
import Foundation
import Security

/// Credentials in the system keychain.
///
/// This is the platform half of the credential story: the protocol is portable,
/// the storage is not. Another platform implements ``CredentialStore`` against
/// its own keystore and nothing else changes.
///
/// Items are stored with `kSecAttrAccessibleAfterFirstUnlock` so a background
/// refresh still works after a reboot, but nothing is readable while the device
/// has never been unlocked, and nothing syncs to iCloud: a key the user pasted
/// on their phone stays on their phone.
public struct KeychainCredentials: CredentialStore {
    /// Namespaces the items so one app's keys cannot collide with another's.
    public let service: String

    public init(service: String = "dev.efedurmaz.Ergon") {
        self.service = service
    }

    public func credential(named name: String) async -> String? {
        var query = baseQuery(for: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores or replaces a credential. Update is attempted first so replacing
    /// a rotated key does not require the caller to delete it, and so a
    /// half-finished rotation cannot leave the account disconnected.
    public func save(_ secret: String, named name: String) throws {
        let data = Data(secret.utf8)
        let updated = SecItemUpdate(baseQuery(for: name) as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }

        var attributes = baseQuery(for: name)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw ErgonError.generation("Could not save the credential (\(added)).")
        }
    }

    /// Removes a credential. Disconnecting a service must actually remove the
    /// secret, not just stop using it.
    public func remove(named name: String) {
        SecItemDelete(baseQuery(for: name) as CFDictionary)
    }

    private func baseQuery(for name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }
}
#endif
