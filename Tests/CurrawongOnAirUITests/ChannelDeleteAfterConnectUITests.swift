// SPDX-License-Identifier: Apache-2.0

import XCTest

/// **BU-9 item 3.** Can a channel be deleted on macOS once the app has had the
/// channel list locked? **Transmits nothing** — it is in this target only
/// because it needs a running app.
///
/// ## The answer, measured 2026-08-21
///
/// **Yes. There is no defect in Delete.** The report — "right-click ▸ Delete is
/// greyed out and does nothing on any channel connected to this launch" — is two
/// things at once, and neither is the menu:
///
/// 1. **A failed connect leaves a modal alert up**, presented as a *sheet*. With
///    it standing, the row is still in the tree and still reads as enabled, the
///    lock label is gone, and the app says it is disconnected — but no context
///    menu can open at all. `=== with the alert up, a context menu opened:
///    false`. Only a channel that has been connected to reaches a path that ends
///    in an alert, which is the whole asymmetry with the never-connected case.
/// 2. **`app.menuItems["Delete"]` is not scoped to the context menu.** Every
///    SwiftUI app on macOS has an always-greyed `Edit ▸ Delete` in the menu bar,
///    so the query finds a disabled Delete whether or not the row's menu opened:
///    `waitForExistence` passes, `isEnabled` is `false`, `click()` does nothing.
///    That is exactly the reported signature.
///
/// Dismiss the alert and Delete opens, is enabled, and removes the row — on the
/// channel that was dialled and on the bystander alike.
///
/// ## Two traps this cost a morning to
///
/// **`app.menus` holds every menu-bar menu**, open or not, so its count is about
/// thirteen before anything has been right-clicked and `app.menus.firstMatch` is
/// the Apple menu. `app.menus.count > 0` is not "a context menu opened". The
/// row's menu is told apart by holding exactly one item, which is its whole
/// contents: Delete.
///
/// **`app.buttons["OK"].firstMatch` clicks the Touch Bar.** The macOS test host
/// exposes a Touch Bar proxy of the window's default button and `firstMatch`
/// picks it, which throws *"cannot be called with Touch Bar elements"* — a
/// failure that says nothing about the app.
///
/// ## It starts by clearing its own leftovers
///
/// The app writes its channel list to the **real** defaults, so a run that dies
/// before its cleanup edits the operator's app — and the next run then sees two
/// rows of the same name, deletes one, and reports that Delete did nothing. That
/// false negative is what made this look like a live bug for a morning. So the
/// test removes every row of its own two names before it adds anything, and
/// removes both again at the end.
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
        // Deliberately not `false`: an early failure must not skip the deletes
        // below, or the run leaves its own rows in the operator's app and the
        // next run reads them as "Delete did nothing".
        continueAfterFailure = true
    }

    func testDeleteWorksOnARowThatSatInTheListWhileItWasLocked() throws {
        let app = XCUIApplication()
        app.launch()

        // MARK: Start from a list with none of this test's own rows in it

        for name in [bystanderName, dialledName] {
            let leftovers = removeEveryRow(named: name, in: app)
            if leftovers > 0 { print("=== cleared \(leftovers) leftover '\(name)' row(s)") }
            XCTAssertEqual(
                rowCount(named: name, in: app), 0,
                "could not clear the leftover '\(name)' rows, so a delete cannot be measured")
        }

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

        // The state the defect was reported from, recorded before it is
        // dismissed: an alert is up, the row is there and enabled, and no
        // context menu can open — while an unscoped Delete query happily
        // reports a disabled item that belongs to the menu bar.
        let alertIsUp = waitUntil(timeout: 5) { self.alertOK(in: app) != nil }
        print("=== an alert was showing after the failed connect: \(alertIsUp)"
            + " (\(alertOK(in: app)?.container ?? "none"))")
        XCTAssertTrue(
            alertIsUp,
            "the failed connect left no alert, so the explanation on record for BU-9 item 3 "
            + "does not apply on this OS and the symptom needs measuring again")

        let row = self.row(named: bystanderName, in: app)
        XCTAssertTrue(row.exists, "the Bystander row left the tree while the alert was up")
        row.rightClick()
        let openedUnderAlert = waitUntil(timeout: 3) { self.openedContextMenu(in: app) != nil }
        print("=== with the alert up, a context menu opened: \(openedUnderAlert)")
        XCTAssertFalse(
            openedUnderAlert,
            "a context menu opened with the alert up, so the alert is not what suppresses it")
        if openedUnderAlert { app.typeKey(.escape, modifierFlags: []) }

        let unscoped = app.menuItems["Delete"].firstMatch
        print(
            "=== with the alert up, an UNSCOPED menuItems[\"Delete\"] matches: "
            + "\(unscoped.exists), isEnabled: \(unscoped.exists ? "\(unscoped.isEnabled)" : "n/a")")
        XCTAssertTrue(
            unscoped.exists && !unscoped.isEnabled,
            "the menu bar's greyed Edit ▸ Delete is not there to be mistaken for the row's, so "
            + "the second half of the explanation on record does not hold either")

        // Escape may have taken the sheet with the menu, so ask again rather
        // than clicking an element found before the right-click.
        if let ok = alertOK(in: app) {
            ok.button.click()
        } else {
            print("=== the alert went away with the context menu")
        }
        XCTAssertTrue(
            waitUntil(timeout: 5) { self.alertOK(in: app) == nil }, "the alert would not dismiss")

        // MARK: The actual question

        delete(channelNamed: bystanderName, in: app)
        delete(channelNamed: dialledName, in: app)
    }

    // MARK: - Deleting, with every query scoped

    /// Right-clicks the row, insists that a context menu actually opened, and
    /// only then looks for Delete inside it. Asserts on the **count** of rows
    /// with this name, not on whether one exists: a duplicate left by an earlier
    /// run makes an existence check say "Delete did nothing" when it worked.
    private func delete(channelNamed name: String, in app: XCUIApplication) {
        let before = rowCount(named: name, in: app)
        guard before > 0 else {
            XCTFail("no row for '\(name)' to delete")
            return
        }
        guard deleteOneRow(named: name, in: app) else { return }
        XCTAssertEqual(
            rowCount(named: name, in: app), before - 1,
            "the list still holds \(rowCount(named: name, in: app)) '\(name)' row(s) after Delete")
    }

    /// Deletes every row of this name, and reports how many there were. Used to
    /// clear leftovers from a run that died before its own cleanup.
    private func removeEveryRow(named name: String, in app: XCUIApplication) -> Int {
        var removed = 0
        while rowCount(named: name, in: app) > 0 {
            guard deleteOneRow(named: name, in: app) else { return removed }
            removed += 1
            guard removed < 20 else {
                XCTFail("still deleting '\(name)' rows after twenty — something is re-adding them")
                return removed
            }
        }
        return removed
    }

    /// One right-click ▸ Delete on the first row of this name. `false` if the
    /// menu never opened, Delete was missing or disabled, or the count did not
    /// fall — each of which is reported as its own failure.
    @discardableResult
    private func deleteOneRow(named name: String, in app: XCUIApplication) -> Bool {
        let before = rowCount(named: name, in: app)
        let row = self.row(named: name, in: app)
        guard waitUntil(timeout: 10, { row.exists }) else {
            XCTFail("no row for '\(name)' to delete")
            return false
        }
        XCTAssertTrue(row.isEnabled, "the row itself is disabled, so the list is still locked")

        row.rightClick()

        // Scoped to the row's own menu. Neither `app.menuItems["Delete"]` nor
        // `app.menus.firstMatch` will do: `app.menus` holds every menu-bar menu
        // as well, so its count is about thirteen before anything is
        // right-clicked and `firstMatch` is the Apple menu.
        guard waitUntil(timeout: 5, { self.openedContextMenu(in: app) != nil }),
            let menu = openedContextMenu(in: app)
        else {
            XCTFail(
                "no context menu opened on '\(name)'. This is not a disabled Delete — it is no "
                + "menu at all, which is what an unscoped menuItems[\"Delete\"] query hides.")
            return false
        }
        let delete = menu.menuItems["Delete"].firstMatch
        guard delete.waitForExistence(timeout: 5) else {
            XCTFail("the context menu on '\(name)' opened but has no Delete item")
            return false
        }
        guard delete.isEnabled else {
            XCTFail(
                "Delete is disabled in '\(name)'s own context menu while the list is unlocked")
            return false
        }
        delete.click()

        guard waitUntil(timeout: 10, { self.rowCount(named: name, in: app) < before }) else {
            XCTFail("'\(name)' — Delete was clicked and the list still holds \(before) of them")
            return false
        }
        return true
    }

    /// How many rows carry this name. The rows have no accessibility identifier,
    /// so the label is all there is to match on; the two names this test uses
    /// appear nowhere else in the app.
    private func rowCount(named name: String, in app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).count
    }

    /// The row's own context menu, if one is open.
    ///
    /// `app.menus` contains every menu in the menu bar, open or not — so its
    /// count is around thirteen before anything has been right-clicked, and
    /// `app.menus.firstMatch` is the Apple menu. The row's menu is told apart by
    /// holding exactly one item, which is its whole contents: Delete.
    private func openedContextMenu(in app: XCUIApplication) -> XCUIElement? {
        let menus = app.menus
        for index in 0..<menus.count {
            let menu = menus.element(boundBy: index)
            if menu.menuItems.count == 1, menu.menuItems["Delete"].firstMatch.exists {
                return menu
            }
        }
        return nil
    }

    /// The alert's OK button, scoped to the alert, or `nil` if no alert is up.
    ///
    /// `app.buttons["OK"].firstMatch` is **not** safe here: the macOS test host
    /// exposes a Touch Bar proxy of the window's default button, `firstMatch`
    /// picks it, and clicking it throws *"cannot be called with Touch Bar
    /// elements"* — a failure that says nothing about the app. Reports which
    /// container it was found in as well; a SwiftUI `alert` on macOS arrives as
    /// a **sheet**.
    private func alertOK(in app: XCUIApplication) -> (button: XCUIElement, container: String)? {
        let containers: [(String, XCUIElementQuery)] = [
            ("sheet", app.sheets), ("dialog", app.dialogs), ("alert", app.alerts),
        ]
        for (name, query) in containers {
            let button = query.firstMatch.buttons["OK"].firstMatch
            if button.exists { return (button, name) }
        }
        return nil
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
