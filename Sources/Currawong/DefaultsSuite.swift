// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which `UserDefaults` the app's stores read and write — the operator's, or a
/// throwaway one a UI test asked for.
///
/// The UI tests drive the real app, so without this they write to the
/// operator's own channel list: a run that dies before cleanup leaves rows
/// behind, and a `+` tap that never gets named or deleted leaves a blank one.
/// Isolating it is a change the app has to take part in, since the app is what
/// opens the defaults.
///
/// ## The hook, and its bounds
///
/// A launch argument, read out of `UserDefaults`' own argument domain — so it can
/// only be set by whoever launched the process, never by a stored preference:
///
/// ```sh
/// Currawong -currawong-defaults-suite au.charlesmartin.currawong.uitests \
///           -currawong-defaults-reset YES
/// ```
///
/// **`#if DEBUG` only.** A release build ignores both arguments and always uses
/// `.standard`, so the hook cannot exist in a shipped binary — which is the
/// answer to "what if somebody passes this to the App Store build". The UI tests
/// run against a Debug build, as `xcodebuild test` always does.
///
/// **The Keychain is not part of this.** Secrets are keyed by account, shared
/// between channels by design (every EchoLink channel for one callsign shares
/// one), and an orphaned Keychain item is invisible and harmless — where a lost
/// password is neither. A test that stores a secret still stores it for real.
enum DefaultsSuite {
    /// Names the suite to use instead of `.standard`.
    static let suiteArgument = "currawong-defaults-suite"

    /// Empties that suite before the app reads it, so every run starts from the
    /// same place: no channels, no drafts, no identity.
    ///
    /// It is the *app* that resets rather than the test runner, because on iOS a
    /// suite that is not an app group lives in the app's own container and the
    /// runner cannot reach it. One rule, both platforms.
    static let resetArgument = "currawong-defaults-reset"

    /// **APP-33.** Starts the run with the licence acknowledgement already on
    /// file, so a test that transmits is not stopped by a sheet — the suite is
    /// wiped at every launch, and the acknowledgement is otherwise answered on
    /// screen once per install. Dismissing it would otherwise consume the
    /// first press that `BU-15` measures (cold key-down to carrier).
    ///
    /// Bounded like the two arguments above (`#if DEBUG`, and only on the
    /// custom-suite path, so no combination pre-acknowledges the operator's own
    /// defaults). The gate itself is tested from every `PTTSource` in
    /// `LicenceAcknowledgementTests`; this target is for radio behaviour.
    static let acknowledgeLicenceArgument = "currawong-licence-acknowledged"

    /// The defaults the app should use. Resolved once — both stores must get the
    /// same answer, and the reset must happen before either of them reads.
    static let resolved: UserDefaults = resolve()

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
