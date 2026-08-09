// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Where the node secret lives.
///
/// Separate from ``SettingsStore`` because the two have genuinely different
/// requirements: settings want to be easy to read, back up and sync, and the
/// secret wants none of those things. Keeping them behind two protocols means
/// there is no single "save everything" call that could put a password in
/// `UserDefaults`, which is the migration this task exists to avoid needing
/// later.
protocol SecretStore: AnyObject, Sendable {
    /// The stored secret for an account, or `nil` if there is none.
    func secret(for account: String) throws -> String?

    /// Stores a secret, or removes it when `secret` is `nil` or empty.
    func setSecret(_ secret: String?, for account: String) throws
}

/// A failure talking to the Keychain, carrying the `OSStatus` for diagnosis.
struct KeychainError: Error, Equatable, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return message ?? "Keychain error \(status)."
    }
}

/// The real thing: a generic-password item per account, in the data protection
/// keychain.
///
/// `kSecAttrAccessibleAfterFirstUnlock` rather than `WhenUnlocked`, because
/// PD-2 gives this app the `audio` background mode and a connection is
/// expected to survive the screen locking. A secret the app cannot read while
/// locked would make a background reconnect impossible.
///
/// `kSecUseDataProtectionKeychain` is set explicitly so macOS behaves like iOS
/// — the same item semantics, no login-keychain prompt — rather than falling
/// back to the file-based keychain where the same query means something
/// subtly different.
///
/// Note that nothing in the test suite touches this type. Tests use an
/// in-memory double; a unit test that writes to the real keychain is a unit
/// test that fails on a machine without a signed host app, and worse, leaves
/// the developer's keychain dirty.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    init(service: String = "au.charlesmartin.currawong") {
        self.service = service
    }

    func secret(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func setSecret(_ secret: String?, for account: String) throws {
        guard let secret, !secret.isEmpty else {
            try delete(account: account)
            return
        }
        let data = Data(secret.utf8)

        // Update first: SecItemAdd on an existing item is errSecDuplicateItem,
        // and add-then-delete-then-add would leave a window with no secret.
        let updated = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)

        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(account: account)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: updated)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
