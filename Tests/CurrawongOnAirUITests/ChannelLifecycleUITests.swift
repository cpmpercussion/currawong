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
        let delete = app.menuItems["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no Delete item")
        print("=== DELETE (never connected) REPORTS isEnabled: \(delete.isEnabled)")
        delete.click()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, row.exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(row.exists, "the channel was still listed after Delete")
    }
}
