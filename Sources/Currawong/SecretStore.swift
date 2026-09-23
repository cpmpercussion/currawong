// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Where the node secret lives.
///
/// Separate from ``SettingsStore`` so no single "save everything" call could
/// put a password in `UserDefaults`.
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
/// `kSecAttrAccessibleAfterFirstUnlock`, not `WhenUnlocked`: a connection
/// survives the screen locking (PD-2), so a background reconnect must be able
/// to read the secret. `kSecUseDataProtectionKeychain` makes macOS use the
/// same item semantics as iOS. Tests use an in-memory double.
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
