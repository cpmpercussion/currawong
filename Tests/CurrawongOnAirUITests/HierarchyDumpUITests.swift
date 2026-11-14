// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Not a test of anything — a way to see what the accessibility tree actually
/// calls the controls, which is the only way to write queries against a
/// SwiftUI form that carries no identifiers. Kept because the next person to
/// touch the on-air test will need it too.
final class HierarchyDumpUITests: XCTestCase {
    func testDumpTheConnectForm() {
        // Isolated like everything else here: dumping the tree used to mean
        // launching against the operator's real channel list, and the dump then
        // named their channels in the build log.
        let app = IsolatedApp.launched()
        giveCallsign("N0CALL", in: app)
        addM17Channel(
            named: "Dump probe", host: "m17-cbr.charlesmartin.au", module: "A", in: app)
        Thread.sleep(forTimeInterval: 1)
        print("=== TEXT FIELDS ===")
        for field in app.textFields.allElementsBoundByIndex {
            print("field: id=\(field.identifier) label=\(field.label) value=\(String(describing: field.value))")
        }
        print("=== BUTTONS ===")
        for button in app.buttons.allElementsBoundByIndex {
            print("button: id=\(button.identifier) label=\(button.label)")
        }
        print("=== FULL TREE ===")
        print(app.debugDescription)
    }

    /// The tree at the point the on-air tests actually fail: form filled, and
    /// looking for the link button. Transmits nothing — it stops before
    /// connecting.
    func testDumpAfterFillingTheForm() {
        let app = IsolatedApp.launched()

        giveCallsign("N0CALL", in: app)
        addM17Channel(
            named: "Dump probe", host: "m17-cbr.charlesmartin.au", module: "A", in: app)

        showSessionPane(in: app)
        Thread.sleep(forTimeInterval: 1)

        print("=== BUTTONS, after switching to the session pane ===")
        for button in app.buttons.allElementsBoundByIndex {
            print("button: id=\(button.identifier) label=\(button.label)")
        }
        let link = app.buttons["Connect to Dump probe"].firstMatch
        print("=== link button: exists=\(link.exists)")

        print("=== SESSION TREE ===")
        print(app.debugDescription)
    }
}

/// One-off: put a channel's host and module back to given values. Not part of
/// any suite's meaning — a repair tool for when the on-air test has left a
/// channel pointed at a test reflector.
final class ChannelRestoreUITests: XCTestCase {
    func testRestoreChannelFromEnvironment() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["RESTORE_HOST"], let module = env["RESTORE_MODULE"] else {
            throw XCTSkip("set RESTORE_HOST and RESTORE_MODULE to use this")
        }
        let app = XCUIApplication()
        app.launch()

        // Select the channel by name first, or the edits land on whichever
        // channel is selected.
        if let name = env["RESTORE_CHANNEL"] {
            let row = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "no channel named \(name)")
            row.activate()
        }

        for (identifier, text) in [("connect.host", host), ("connect.module", module)] {
            let field = app.textFields[identifier].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(identifier)")
            replace(text, in: field)
        }
        // Edits are saved as they are typed, so there is nothing to commit.
        XCTAssertEqual(app.textFields["connect.host"].firstMatch.value as? String, host)
        XCTAssertEqual(app.textFields["connect.module"].firstMatch.value as? String, module)
    }
}
