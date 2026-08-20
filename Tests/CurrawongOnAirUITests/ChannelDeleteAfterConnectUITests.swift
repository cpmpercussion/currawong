// SPDX-License-Identifier: Apache-2.0

import XCTest

/// **BU-9 item 3.** Can a channel be deleted on macOS once the app has had the
/// channel list locked? **Transmits nothing** — it is in this target only
/// because it needs a running app.
///
/// ## What it does instead of going on air
///
/// The list locks whenever the session is anything but `.disconnected`, and that
/// includes `.connecting`. So the lock is armed by dialling **192.0.2.1** —
/// TEST-NET-1, reserved by RFC 5737 for documentation, routed nowhere — which
/// spends the connect timeout in `.connecting` and then fails. That is the whole
/// `false → true` transition of the rows' enabled-ness, with no credentials, no
/// node, and nothing keyed. **No PTT control is touched anywhere in this file.**
///
/// ## The channel it deletes is the one that was never connected to
///
/// "Bystander" is added first and then left alone. If the defect is really about
/// *having been connected to*, Bystander must delete fine; if it is about
/// *having existed while the list was locked*, Bystander must be as dead as the
/// other one. The headless `ChannelListContextMenuTests` says the AppKit menu
/// recovers for both, so a failure here is a fault in what the accessibility
/// tree offers rather than in the menu the platform would display.
///
/// ## Every menu query is scoped, and that is the point
///
/// `app.menuItems["Delete"]` is **not** scoped to the context menu. Every
/// SwiftUI app on macOS has an always-present, always-greyed `Edit ▸ Delete` in
/// the menu bar, so an unscoped query finds a disabled Delete whether or not the
/// row's context menu opened at all — `waitForExistence` passes, `isEnabled` is
/// `false`, and `click()` does nothing. That is exactly the reported signature,
/// which is why the queries here go through `app.menus` and why a context menu
/// that fails to open is reported as such.
///
/// ## It cleans up after itself
///
/// Both channels are added by this test and both are removed at the end. The app
/// writes its channel list to the real defaults, so a test that leaves rows
/// behind is a test that edits the operator's app.
final class ChannelDeleteAfterConnectUITests: XCTestCase {

    /// The channel that is never connected to, never selected again, and is the
    /// one whose Delete this test is really about.
    private let bystanderName = "Bystander"

    /// The channel that arms the lock. M17 rather than AllStarLink because its
    /// required fields — host, module, callsign — all carry accessibility
    /// identifiers, and because its connect timeout is short.
    private let dialledName = "BU-9 unroutable"

    /// Reserved for documentation (RFC 5737) and routed nowhere.
    private let unroutableHost = "192.0.2.1"

    private let lockLabel = "Disconnect to switch, add or delete channels."

    override func setUp() {
        continueAfterFailure = false
    }

    func testDeleteWorksOnARowThatSatInTheListWhileItWasLocked() throws {
        let app = XCUIApplication()
        app.launch()

        addChannel(named: bystanderName, in: app)
        addChannel(named: dialledName, in: app)
        pointAtNowhere(in: app)

        // MARK: Arm the lock

        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "no Connect button")
        connect.click()

        let lock = text(lockLabel, in: app)
        guard waitUntil(timeout: 20, { lock.exists }) else {
            XCTFail(
                "the repro never armed: the channel list never locked, so the connect attempt "
                + "did not reach .connecting. Check the callsign and the form, not the menu.")
            return
        }

        // MARK: Let it fail, and look at what the failure leaves on screen

        XCTAssertTrue(
            waitUntil(timeout: 40) { !lock.exists },
            "the channel list stayed locked — the connect attempt never came back")

        // A failed connect ends in a modal alert, and a modal alert is a
        // complete explanation of the reported symptom on its own: the row still
        // reads as enabled, the lock label is gone, the app says it is not
        // connected — and no context menu can open, so the only Delete in the
        // tree is the menu bar's. Recorded before it is dismissed, because this
        // is the state the defect was reported from.
        let dismiss = app.buttons["OK"].firstMatch
        let alertIsUp = dismiss.waitForExistence(timeout: 5)
        print("=== an alert was showing after the failed connect: \(alertIsUp)")

        if alertIsUp {
            let row = self.row(named: bystanderName, in: app)
            if row.exists {
                row.rightClick()
                print("=== with the alert up, open menus: \(app.menus.count)")
            }
            let unscoped = app.menuItems["Delete"].firstMatch
            print(
                "=== with the alert up, an UNSCOPED menuItems[\"Delete\"] matches: "
                + "\(unscoped.exists), isEnabled: \(unscoped.exists ? "\(unscoped.isEnabled)" : "n/a")")
            dismiss.click()
        }

        // MARK: The actual question

        delete(channelNamed: bystanderName, in: app)
        delete(channelNamed: dialledName, in: app)
    }

    // MARK: - Deleting, with every query scoped

    /// Right-clicks the row, insists that a context menu actually opened, and
    /// only then looks for Delete inside it.
    private func delete(channelNamed name: String, in app: XCUIApplication) {
        let row = self.row(named: name, in: app)
        guard waitUntil(timeout: 10, { row.exists }) else {
            XCTFail("no row for '\(name)' to delete")
            return
        }
        XCTAssertTrue(row.isEnabled, "the row itself is disabled, so the list is still locked")

        row.rightClick()

        // Scoped to the menus, not the whole app: an unscoped `menuItems`
        // query matches the menu bar's own greyed Delete and would pass here
        // whether or not this menu opened.
        guard waitUntil(timeout: 5, { app.menus.count > 0 }) else {
            XCTFail(
                "no context menu opened on '\(name)'. This is not a disabled Delete — it is no "
                + "menu at all, which is what an unscoped menuItems[\"Delete\"] query hides.")
            return
        }
        let menu = app.menus.firstMatch
        let delete = menu.menuItems["Delete"].firstMatch
        guard delete.waitForExistence(timeout: 5) else {
            XCTFail("the context menu on '\(name)' opened but has no Delete item")
            return
        }
        XCTAssertTrue(
            delete.isEnabled,
            "Delete is disabled in '\(name)'s own context menu while the list is unlocked")
        delete.click()

        XCTAssertTrue(
            waitUntil(timeout: 10) { !self.row(named: name, in: app).exists },
            "'\(name)' was still listed after Delete")
    }

    // MARK: - Driving the app

    /// Adds a channel and names it. `addChannel` saves the draft first, so the
    /// name typed for the previous channel is committed by the next add — which
    /// is how "Bystander" ends up named in the list.
    private func addChannel(named name: String, in app: XCUIApplication) {
        let add = app.buttons["Add channel"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add channel button")
        add.click()
        replace(name, in: field("connect.channelName", in: app))
    }

    /// Points the selected channel at TEST-NET-1 over M17, and makes sure there
    /// is a callsign — without overwriting a real one. The callsign is app-wide
    /// and saved, so this types only into an empty field.
    private func pointAtNowhere(in app: XCUIApplication) {
        let m17 = app.radioButtons["M17"].firstMatch
        XCTAssertTrue(m17.waitForExistence(timeout: 5), "no M17 mode control")
        m17.click()

        replace(unroutableHost, in: field("connect.host", in: app))
        replace("A", in: field("connect.module", in: app))

        let callsign = field("connect.callsign", in: app)
        let existing = callsign.value as? String ?? ""
        if existing.trimmingCharacters(in: .whitespaces).isEmpty {
            // Only reached on a machine with no callsign saved. Connect refuses
            // to leave `.disconnected` without one, and the lock would never arm.
            replace("VK1TEST", in: callsign)
        }
    }

    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(identifier)")
        return field
    }

    private func row(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// A SwiftUI `Text` arrives with an **empty** accessibility label and its
    /// string in `value`, so `app.staticTexts["…"]` matches nothing and every
    /// assertion built on it passes vacuously. Match either.
    private func text(_ string: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", string, string)).firstMatch
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }
}
