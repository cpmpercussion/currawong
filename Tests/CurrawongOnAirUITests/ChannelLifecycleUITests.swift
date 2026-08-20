// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Add a channel and delete it again, touching nothing else. **Transmits
/// nothing** — it is in this target only because it needs a running app.
///
/// It exists because the on-air test could not clean up after itself, and the
/// question "is Delete broken always, or only after a session?" is the one that
/// says whether that is a test problem or an app problem.
final class ChannelLifecycleUITests: XCTestCase {

    private let channelName = "Lifecycle probe"

    func testAChannelCanBeAddedAndDeletedWithoutConnecting() {
        let app = XCUIApplication()
        app.launch()

        let add = app.buttons["Add channel"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add channel button")
        add.click()

        let name = app.textFields["connect.channelName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no channel name field")
        replace(channelName, in: name)

        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", channelName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the new channel never appeared")

        row.rightClick()

        // Scoped to the context menu that just opened. `app.menuItems["Delete"]`
        // would also match the menu bar's own always-greyed `Edit ▸ Delete`, so
        // it passes `waitForExistence` even when no context menu opened at all —
        // and then reports `isEnabled == false` and clicks nothing. That is the
        // shape of BU-9 item 3's evidence, and it is a query fault rather than a
        // finding.
        XCTAssertTrue(
            waitUntil(timeout: 5) { app.menus.count > 0 },
            "no context menu opened on the row — not a disabled Delete, no menu at all")
        let delete = app.menus.firstMatch.menuItems["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no Delete item in the row's own menu")
        XCTAssertTrue(delete.isEnabled, "Delete is disabled on a channel never connected to")
        delete.click()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, row.exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(row.exists, "the channel was still listed after Delete")
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
