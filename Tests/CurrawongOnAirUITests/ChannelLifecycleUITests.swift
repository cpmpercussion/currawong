// SPDX-License-Identifier: Apache-2.0

import XCTest

// **macOS only**, for the same reason as `ChannelDeleteAfterConnectUITests`:
// the delete it exercises is the macOS context menu's. See that file's note.
#if os(macOS)

/// The channel lifecycle from a first launch: give a callsign, add a channel,
/// edit it, delete it. **Transmits nothing** — it is in this target only
/// because it needs a running app.
///
/// ## It counts rows, and it starts from an empty list
///
/// ``IsolatedApp`` launches the app against a throwaway defaults suite that is
/// emptied first, so the list starts empty and the operator's own channels are
/// never touched. Assertions are on the *count* of rows: a run against a list
/// that already held a row of this name would otherwise delete one, find the
/// other, and report that Delete did nothing.
final class ChannelLifecycleUITests: XCTestCase {

    private let channelName = "Lifecycle probe"
    private let renamed = "Renamed probe"

    override func setUp() {
        // Deliberately not `false`: an early failure must not skip the cleanup
        // below, or the run leaves its own row in the suite.
        continueAfterFailure = true
    }

    func testAChannelCanBeAddedEditedAndDeletedWithoutConnecting() {
        let app = IsolatedApp.launched()

        // First run asks for a callsign before anything else is on screen.
        XCTAssertTrue(
            app.textFields["welcome.callsign"].firstMatch.waitForExistence(timeout: 10),
            "a launch with no stored callsign did not ask for one")
        XCTAssertFalse(
            app.buttons["Add channel"].firstMatch.exists,
            "the channel list was reachable before a callsign was given")
        // Made up, and safe: nothing in this test connects.
        giveCallsign("VK1TEST", in: app)

        // A statement about the isolation rather than a cleanup: a row of this
        // name already here means the app is reading the operator's defaults.
        XCTAssertEqual(
            rowCount(named: channelName, in: app), 0,
            "the app did not start from an empty channel list — see IsolatedApp")

        // Backing out of `Add channel` leaves nothing behind.
        let add = app.buttons["Add channel"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add channel button")
        add.click()
        let cancel = app.buttons["addChannel.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Add channel has no Cancel")
        cancel.click()
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", M17,")).count, 0,
            "a cancelled Add channel left a row")

        addM17Channel(named: channelName, host: "192.0.2.1", module: "A", in: app)
        XCTAssertTrue(
            waitUntil(timeout: 10) { self.rowCount(named: self.channelName, in: app) == 1 },
            "Add did not put the new channel in the list")

        // An edit is saved as it is typed: the row follows the form, and there
        // is no Save to press.
        XCTAssertFalse(app.buttons["Save"].firstMatch.exists, "the form still has a Save button")
        let name = app.textFields["connect.channelName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no channel name field beside the list")
        replace(renamed, in: name)
        XCTAssertTrue(
            waitUntil(timeout: 10) { self.rowCount(named: self.renamed, in: app) == 1 },
            "renaming the channel in the form did not rename its row")
        XCTAssertEqual(rowCount(named: channelName, in: app), 0, "the old name is still listed")

        XCTAssertTrue(deleteOneRow(named: renamed, in: app), "Delete did not remove the row")
        XCTAssertEqual(
            rowCount(named: renamed, in: app), 0,
            "the channel was still listed after Delete")
    }

    /// APP-42's done-when, in the running app: a callsign and a tap in the
    /// reflector list give a channel the link button will connect to, with no
    /// address typed and Settings never opened. Stops before connecting.
    ///
    /// **Needs the internet**: the list is the M17 Project's published file,
    /// and which reflector comes first is whatever it says that day, so the
    /// assertions are about there being a new M17 row and not about its name.
    func testAReflectorChosenFromTheListBecomesAChannel() throws {
        let app = IsolatedApp.launched()
        giveCallsign("VK1TEST", in: app)

        let add = app.buttons["Add channel"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add channel button")
        add.click()
        let network = app.buttons["addChannel.network.m17"].firstMatch
        XCTAssertTrue(network.waitForExistence(timeout: 5), "Add channel did not offer M17")
        network.click()

        // A module button is labelled "Add <reflector> module <letter>".
        let module = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Add ", " module ")
        ).firstMatch
        guard module.waitForExistence(timeout: 30) else {
            throw XCTSkip("the reflector list did not load — no network, or the file has moved")
        }
        module.click()

        let m17Rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", M17,"))
        XCTAssertTrue(
            waitUntil(timeout: 10) { m17Rows.count == 1 },
            "choosing a module did not add exactly one M17 channel")
        XCTAssertFalse(
            app.buttons["addChannel.cancel"].firstMatch.exists,
            "the Add channel sheet stayed up after a module was chosen")

        let connect = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Connect to ")).firstMatch
        XCTAssertTrue(
            connect.waitForExistence(timeout: 5),
            "no link button for the channel that was just chosen")
        XCTAssertTrue(connect.isEnabled)

        // Leave the suite as it was found.
        let label = m17Rows.firstMatch.label
        let name = String(label.prefix(while: { $0 != "," }))
        XCTAssertTrue(deleteOneRow(named: name, in: app), "could not delete the chosen channel")
    }

    // MARK: - Rows

    private func rowCount(named name: String, in app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).count
    }

    private func row(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// One right-click ▸ Delete on the first row of this name. `false` if the
    /// menu never opened, Delete was missing or disabled, or the count did not
    /// fall.
    @discardableResult
    private func deleteOneRow(named name: String, in app: XCUIApplication) -> Bool {
        let before = rowCount(named: name, in: app)
        guard before > 0 else { return false }

        row(named: name, in: app).rightClick()

        guard let menu = openedRowMenu(in: app) else {
            XCTFail("no context menu opened on '\(name)' — not a disabled Delete, no menu at all")
            return false
        }

        let delete = menu.menuItems["Delete"].firstMatch
        guard delete.waitForExistence(timeout: 5) else {
            XCTFail("no Delete item in the row's own menu")
            return false
        }
        guard delete.isEnabled else {
            XCTFail("Delete is disabled on a channel never connected to")
            return false
        }
        delete.click()

        return waitUntil(timeout: 10) { self.rowCount(named: name, in: app) == before - 1 }
    }

    /// The row's own context menu, if one is open.
    ///
    /// **`app.menus` is not a scope.** It holds every menu in the menu bar, open
    /// or not — its count is about thirteen before anything has been
    /// right-clicked, and `app.menus.firstMatch` is the *Apple* menu. So
    /// `app.menus.count > 0` is not "a context menu opened", which is what this
    /// test used to assert: it passed on a machine whose automation grant had
    /// lapsed and failed the moment it could really right-click.
    /// `app.menuItems["Delete"]` is no better — it matches the menu bar's own
    /// always-greyed `Edit ▸ Delete`, and so reports a disabled Delete whether
    /// or not a context menu is up. Both halves of BU-9 item 3 were this.
    ///
    /// The row's menu is told apart by its contents: exactly one item, Delete.
    /// The same rule `ChannelDeleteAfterConnectUITests` uses.
    private func openedRowMenu(in app: XCUIApplication) -> XCUIElement? {
        var found: XCUIElement?
        _ = waitUntil(timeout: 5) {
            let menus = app.menus
            for index in 0..<menus.count {
                let menu = menus.element(boundBy: index)
                if menu.menuItems.count == 1, menu.menuItems["Delete"].firstMatch.exists {
                    found = menu
                    return true
                }
            }
            return false
        }
        return found
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
