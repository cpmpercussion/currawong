// SPDX-License-Identifier: Apache-2.0

import XCTest

// **macOS only**, for the same reason as `ChannelDeleteAfterConnectUITests`:
// the delete it exercises is the macOS context menu's. See that file's note.
#if os(macOS)

/// Add a channel and delete it again, touching nothing else. **Transmits
/// nothing** — it is in this target only because it needs a running app.
///
/// It exists because the on-air test could not clean up after itself, and the
/// question "is Delete broken always, or only after a session?" is the one that
/// says whether that is a test problem or an app problem.
///
/// ## It counts rows, and it starts from an empty list
///
/// It used to edit the operator's real channel list, so a run that died before
/// its delete left a row behind — and the next run found two rows of one name,
/// deleted one, and reported that Delete did nothing. That false negative cost a
/// morning under BU-9 and came back under APP-19. ``IsolatedApp`` now launches
/// the app against a throwaway defaults suite that is emptied first, so the list
/// starts empty and the operator's own channels are never touched. Assertions are
/// on the *count* of rows, which is what makes a duplicate visible rather than
/// invisible.
///
/// ## APP-19 changed what `Add channel` does
///
/// It used to put a channel in the list on the click, which is the fault APP-19
/// fixed: one tap of `+` left a permanent blank row in the operator's own app,
/// and every dead run of this test left one. `+` now points the form at a new
/// channel and writes nothing; **Save is what puts it in the list**, and this
/// test presses it.
final class ChannelLifecycleUITests: XCTestCase {

    private let channelName = "Lifecycle probe"

    override func setUp() {
        // Deliberately not `false`: an early failure must not skip the cleanup
        // below, or the run leaves its own row in the operator's app.
        continueAfterFailure = true
    }

    func testAChannelCanBeAddedAndDeletedWithoutConnecting() {
        let app = IsolatedApp.launched()

        // The suite is wiped at launch, so this is a statement about the
        // isolation rather than a cleanup: if a row of this name is already here,
        // the app is reading the operator's defaults and every count below is
        // measuring the wrong list.
        XCTAssertEqual(
            rowCount(named: channelName, in: app), 0,
            "the app did not start from an empty channel list — see IsolatedApp")

        let add = app.buttons["Add channel"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add channel button")
        add.click()

        let name = app.textFields["connect.channelName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no channel name field")
        replace(channelName, in: name)

        // **APP-19.** The click above wrote nothing; this is what adds the row.
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "no Save button")
        XCTAssertTrue(save.isEnabled, "Save is disabled on a named new channel")
        save.click()

        XCTAssertTrue(
            waitUntil(timeout: 10) { self.rowCount(named: self.channelName, in: app) == 1 },
            "Save did not put the new channel in the list — APP-19's other half")

        XCTAssertTrue(deleteOneRow(named: channelName, in: app), "Delete did not remove the row")
        XCTAssertEqual(
            rowCount(named: channelName, in: app), 0,
            "the channel was still listed after Delete")
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
