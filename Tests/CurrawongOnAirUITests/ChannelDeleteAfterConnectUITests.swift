// SPDX-License-Identifier: Apache-2.0

import XCTest

// **macOS only.** This target gained an iOS destination on 2026-08-23 so the
// on-air M17 test could reach a device (`BU-15`). This file did not come with
// it, and should not: it is about the macOS context menu — right-click, the
// menu-bar `Edit ▸ Delete` decoy, and the modal sheet that hides both — none of
// which exist on iOS, where deletion is a swipe. Built for iOS it would be a
// test that asserts nothing.
#if os(macOS)

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
/// ## It starts from an empty channel list
///
/// It used to write to the **real** defaults, so a run that died before its
/// cleanup edited the operator's app — and the next run saw two rows of the same
/// name, deleted one, and reported that Delete did nothing. That false negative
/// is what made this look like a live bug for a morning. ``IsolatedApp`` launches
/// against a throwaway suite that is emptied first; the test asserts it really is
/// empty, and still removes its own rows at the end, which is a delete this test
/// is about anyway.
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

    /// APP-23 reworded this: switching is no longer refused, only the
    /// operations that change what the list contains. This test *arms* the lock
    /// by waiting for the label, so a stale string here does not fail loudly —
    /// it waits twenty seconds and reports that the repro never armed.
    private let lockLabel = "Disconnect to add, edit or delete channels."

    override func setUp() {
        // Deliberately not `false`: an early failure must not skip the deletes
        // below, or the run leaves its own rows in the operator's app and the
        // next run reads them as "Delete did nothing".
        continueAfterFailure = true
    }

    func testDeleteWorksOnARowThatSatInTheListWhileItWasLocked() throws {
        let app = IsolatedApp.launched()

        // MARK: Start from a list with none of this test's own rows in it

        // A statement about the isolation, not a cleanup: ``IsolatedApp`` empties
        // the suite before the app reads it, so a row already here means the app
        // is reading the operator's defaults and every count below is measuring
        // the wrong list. `removeEveryRow` is kept for the end of the test, where
        // it still proves something.
        for name in [bystanderName, dialledName] {
            XCTAssertEqual(
                rowCount(named: name, in: app), 0,
                "the app did not start from an empty channel list — see IsolatedApp")
        }

        addChannel(named: bystanderName, in: app)
        addChannel(named: dialledName, in: app)
        pointAtNowhere(in: app)
        // Committed before Connect on purpose: under the fixed model Connect may
        // *add* a channel for an unsaved edit, and this test counts rows by name.
        saveIfPossible(in: app)

        // MARK: Arm the lock

        // **APP-23: the form's Connect is gone**, and `app.buttons["Connect"]`
        // still matches the pane switcher's radio button, so this has to name
        // the destination the way the session pane's link button does (APP-17).
        let connect = app.buttons["Connect to \(dialledName)"].firstMatch
        XCTAssertTrue(
            connect.waitForExistence(timeout: 5),
            "no link button naming this channel — the session pane's Connect is the only one now")
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

        // MARK: Leave the operator's list as it was found

        for name in [bystanderName, dialledName] {
            let extra = removeEveryRow(named: name, in: app)
            if extra > 0 {
                print("=== swept \(extra) extra '\(name)' row(s) the run had created")
            }
            XCTAssertEqual(rowCount(named: name, in: app), 0, "left '\(name)' rows behind")
        }
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

    /// Adds a channel and names it, under either channel model.
    ///
    /// Before BU-9 items 1 and 2 were fixed, the name typed here reached the
    /// list only when the *next* add committed the draft. After the fix, Save is
    /// the one thing that overwrites a channel — so the name is committed here,
    /// by pressing it if it is there. Naming a channel is not what this test is
    /// about, and it should not have to know which model it is running against.
    private func addChannel(named name: String, in app: XCUIApplication) {
        let add = app.buttons["Add channel"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add channel button")
        add.click()
        replace(name, in: field("connect.channelName", in: app))
        saveIfPossible(in: app)
    }

    /// Presses Save if the form has one and it is enabled. Nothing to do on a
    /// build from before the fix, which has no Save button at all.
    private func saveIfPossible(in app: XCUIApplication) {
        let save = app.buttons["Save"].firstMatch
        guard save.exists, save.isEnabled else { return }
        save.click()
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
            // The ordinary path now: ``IsolatedApp`` wipes the suite, so there is
            // no stored identity. Connect refuses to leave `.disconnected`
            // without a callsign and the lock would never arm, so one is needed —
            // and a made-up one is safe *here* precisely because this test dials
            // TEST-NET-1 and nothing ever leaves the machine. The on-air test
            // brings the operator's own instead.
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

#endif
