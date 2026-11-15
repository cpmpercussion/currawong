// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which `UserDefaults` the app's stores use — the operator's, or a throwaway
/// suite a UI test asked for, so tests driving the real app leave the
/// operator's channel list alone.
///
/// Set by launch argument (the argument domain, so never by a stored
/// preference):
///
/// ```sh
/// Currawong -currawong-defaults-suite au.charlesmartin.currawong.uitests \
///           -currawong-defaults-reset YES
/// ```
///
/// **`#if DEBUG` only**: a release build always uses `.standard`.
///
/// The Keychain follows the suite: a named suite gets a Keychain service of the
/// same name, emptied by the same reset, so a test that types a secret into the
/// app cannot overwrite or delete the operator's. See ``secretStore``.
enum DefaultsSuite {
    /// Names the suite to use instead of `.standard`.
    static let suiteArgument = "currawong-defaults-suite"

    /// Empties that suite before the app reads it. The app does this because
    /// on iOS the test runner cannot reach the app's container.
    static let resetArgument = "currawong-defaults-reset"

    /// **APP-33.** Pre-acknowledges the licence in the test suite, so a
    /// transmitting UI test is not stopped by the sheet. `#if DEBUG` and
    /// custom-suite only, so it can never touch the operator's own defaults.
    static let acknowledgeLicenceArgument = "currawong-licence-acknowledged"

    /// The defaults the app should use. Resolved once, so both stores agree and
    /// the reset precedes any read.
    static let resolved: UserDefaults = resolve()

    /// The secret store to match ``resolved``: the operator's Keychain items,
    /// or a throwaway service when a UI test named a suite.
    static let secretStore: KeychainSecretStore = {
        guard let service = secretService() else { return KeychainSecretStore() }
        let store = KeychainSecretStore(service: service)
        if UserDefaults.standard.bool(forKey: resetArgument) { store.removeAll() }
        return store
    }()

    /// The Keychain service a named suite uses, or `nil` for the operator's
    /// own. The suite's name, so the two cannot be pointed at different places.
    static func secretService(reading source: UserDefaults = .standard) -> String? {
        #if DEBUG
        guard let name = source.string(forKey: suiteArgument), !name.isEmpty else { return nil }
        return name
        #else
        return nil
        #endif
    }

    /// - Parameter source: where to look for the launch arguments. The argument
    ///   domain is part of `.standard`; a test passes its own.
    static func resolve(reading source: UserDefaults = .standard) -> UserDefaults {
        #if DEBUG
        guard
            let name = source.string(forKey: suiteArgument),
            !name.isEmpty,
            let suite = UserDefaults(suiteName: name)
        else { return .standard }

        if source.bool(forKey: resetArgument) {
            suite.removePersistentDomain(forName: name)
        }
        // After the reset, or it would be the first thing wiped.
        if source.bool(forKey: acknowledgeLicenceArgument) {
            suite.set(
                LicenceAcknowledgement.currentVersion,
                forKey: UserDefaultsSettingsStore.licenceAcknowledgementKey)
        }
        return suite
        #else
        return .standard
        #endif
    }
}
