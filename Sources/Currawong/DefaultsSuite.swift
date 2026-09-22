// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which `UserDefaults` the app's stores read and write — the operator's, or a
/// throwaway one a UI test asked for.
///
/// ## Why the app needs to know about this at all
///
/// The UI tests drive the **real app**, so until now they edited the operator's
/// real channel list. Two things went wrong with that, both of them expensive:
///
/// 1. **A run that dies before its cleanup leaves rows behind**, and the next run
///    finds two rows of one name, deletes one, and reports that Delete did
///    nothing. That false negative was read as a live bug for a morning under
///    BU-9, and it recurred under APP-19.
/// 2. **The blank rows APP-19 was opened for came from these tests** — a `+` tap
///    that never got as far as being named or deleted.
///
/// Both are the same fault: a test writing to the operator's data. Isolating it
/// is a change the app has to take part in, because the app is what opens the
/// defaults.
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
    /// file, so a test that transmits is not stopped by a sheet.
    ///
    /// ## Why a bypass exists at all, and what bounds it
    ///
    /// The acknowledgement is answered on screen, once per install, and the
    /// suite is wiped at every launch — so without this the on-air tests would
    /// each have to spend their **first press** raising a sheet and dismissing
    /// it. That press is the one `BU-15` measures (cold key-down, press to
    /// carrier), and spending it on a dialogue would change the thing those
    /// tests exist to observe.
    ///
    /// Three things keep it honest:
    ///
    /// * **`#if DEBUG` only**, like the two arguments above, so it cannot exist
    ///   in a shipped binary.
    /// * **It only runs on the custom-suite path.** The write below happens
    ///   inside the `guard` that has already found a named suite, so there is no
    ///   argument combination that pre-acknowledges the *operator's* defaults.
    /// * **The gate itself is tested elsewhere**, properly, from every
    ///   `PTTSource` — see `LicenceAcknowledgementTests`. This target is for
    ///   radio behaviour, and a test target that cannot key a radio tests
    ///   nothing.
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
