// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The app under test, pointed at a **throwaway defaults suite** instead of the
/// operator's own.
///
/// ## Why every test in this target uses this
///
/// These tests drive the real app, so until now they edited the operator's real
/// channel list — and twice that cost more than the tests were worth:
///
/// * A run that died before its cleanup left a row behind, and the next run found
///   two rows of one name, deleted one, and reported that **Delete did nothing**.
///   That false negative was read as a live bug for a morning under BU-9, and it
///   came back under APP-19.
/// * The blank "Unnamed channel" rows APP-19 was opened for were made *here* — a
///   `+` tap in a run that never got as far as naming or deleting it.
///
/// One launch argument fixes the class: see ``DefaultsSuite`` in the app. The
/// suite is emptied by the app before it reads anything, so every run starts from
/// no channels, no drafts and no stored identity — which is also why a test that
/// needs the operator's callsign has to bring it, below.
enum IsolatedApp {

    /// Not an app group and not the app's own domain: a separate suite, so
    /// nothing here can reach `au.charlesmartin.currawong`.
    static let suiteName = "au.charlesmartin.currawong.uitests"

    /// - Parameter reset: whether to empty the suite first. `true` for anything
    ///   that counts rows; `false` for a test that wants to launch twice and
    ///   check that something survived.
    static func launched(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-currawong-defaults-suite", suiteName]
        if reset {
            app.launchArguments += ["-currawong-defaults-reset", "YES"]
        }
        app.launch()
        return app
    }

    /// The operator's own callsign, read out of the app's **real** defaults.
    ///
    /// A test that transmits must not invent one. The suite is wiped at launch, so
    /// the callsign field comes up empty; typing something made up would put a
    /// callsign on the air that belongs to nobody, or to somebody else. The runner
    /// and the app share the user's preference domain on macOS, which is where
    /// this target runs, so the honest answer is available — and where it is not,
    /// the caller fails the test rather than guessing.
    static func operatorCallsign() -> String? {
        guard
            let real = UserDefaults(suiteName: "au.charlesmartin.currawong"),
            let data = real.data(forKey: "au.charlesmartin.currawong.operatorIdentity"),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let callsign = json["callsign"] as? String,
            !callsign.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return callsign
    }
}
