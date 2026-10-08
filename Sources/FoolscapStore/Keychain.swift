import Foundation
import Security

public struct KeychainError: Error, Sendable {
    public let status: OSStatus
    public var message: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)" }
}

/// One generic-password item in the login keychain: the place for a token
/// that must not ride along in backups (Application Support and the
/// preferences both do). The data-protection keychain needs an entitlement a
/// self-signed app lacks, so this is the file-based one.
public struct KeychainItem: Sendable {
    public let service: String
    public let account: String
    public let label: String

    public init(service: String, account: String, label: String) {
        self.service = service; self.account = account; self.label = label
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The stored data, or nil when there is no such item.
    public func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return out as? Data
    }

    /// Replace the item's data, creating the item if it is not there.
    public func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    /// Remove the item; a missing item is fine.
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
