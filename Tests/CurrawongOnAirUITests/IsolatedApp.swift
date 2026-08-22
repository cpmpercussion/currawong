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

    /// The environment variable a caller sets to say which callsign may go on
    /// the air. See ``operatorCallsign()``.
    static let callsignVariable = "CURRAWONG_ONAIR_CALLSIGN"

    /// The operator's own callsign — from the environment, or failing that the
    /// app's **real** defaults.
    ///
    /// A test that transmits must not invent one. The suite is wiped at launch,
    /// so the callsign field comes up empty; typing something made up would put
    /// a callsign on the air that belongs to nobody, or to somebody else.
    ///
    /// ## Why the environment comes first, added 2026-08-23
    ///
    /// The defaults route **only works on macOS**, where the runner and the app
    /// share the user's preference domain. On iOS they are separate sandboxed
    /// apps and the runner cannot read the app's container at all, so on the
    /// device — the one platform where `BU-15` is visible — this returned nil
    /// and the test could not run.
    ///
    /// The variable also makes the opt-in explicit, which is worth having on
    /// both platforms: a callsign is public information, but *transmitting*
    /// under somebody's callsign is not something a checkout should do because
    /// a test target happened to get run. Nothing here is committed — the value
    /// is supplied per run:
    ///
    /// ```sh
    /// xcodebuild ... TEST_RUNNER_CURRAWONG_ONAIR_CALLSIGN=<yours>
    /// ```
    ///
    /// `xcodebuild` strips the `TEST_RUNNER_` prefix and passes the rest into
    /// the runner's environment, which is the only route into a UI test process
    /// on a device.
    static func operatorCallsign() -> String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment[callsignVariable],
            !fromEnvironment.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return fromEnvironment.trimmingCharacters(in: .whitespaces).uppercased()
        }
        #if os(macOS)
            guard
                let real = UserDefaults(suiteName: "au.charlesmartin.currawong"),
                let data = real.data(forKey: "au.charlesmartin.currawong.operatorIdentity"),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let callsign = json["callsign"] as? String,
                !callsign.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return callsign
        #else
            return nil
        #endif
    }

    /// The callsign, or a skip explaining how to supply one.
    ///
    /// **A skip rather than a failure.** This whole target is opt-in — it is
    /// kept out of the `Currawong` scheme precisely so it never runs by
    /// accident — and "you did not tell me who is transmitting" is the target
    /// not being configured, not the app being broken. A red test there would
    /// say the app has a fault, which is a lie, and the loud thing to do about
    /// an unconfigured opt-in is to refuse to transmit, which a skip does.
    static func requireOperatorCallsign() throws -> String {
        guard let callsign = operatorCallsign() else {
            throw XCTSkip(
                "This test transmits, and no callsign was given, so it will not. Set "
                    + "\(callsignVariable) — pass "
                    + "TEST_RUNNER_\(callsignVariable)=<yours> to xcodebuild — or, on "
                    + "macOS only, set your callsign in Currawong first.")
        }
        return callsign
    }
}
