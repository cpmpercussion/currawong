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
        let m17 = app.radioButtons["M17"].firstMatch
        if m17.waitForExistence(timeout: 5) { m17.activate() }
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

        // Select the channel by name first. Without this the edits land on
        // whatever the draft happens to be — which is the same trap the on-air
        // test fell into.
        if let name = env["RESTORE_CHANNEL"] {
            let row = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "no channel named \(name)")
            row.activate()
        }

        let m17 = app.radioButtons["M17"].firstMatch
        if m17.waitForExistence(timeout: 5) { m17.activate() }
        for (identifier, text) in [("connect.host", host), ("connect.module", module)] {
            let field = app.textFields[identifier].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(identifier)")
            replace(text, in: field)
        }
        // Typing alone does not reach the channel list: since BU-9 only Save
        // and Connect write to it, and since APP-19 `Add channel` does not
        // either. Selecting *stashes* the edit against the channel it is
        // leaving, which is enough for what this dump needs — so select
        // something else and select back to prove the draft stuck.
        let name = env["RESTORE_CHANNEL"] ?? ""
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", M17,"))
        var other: XCUIElement?
        for index in 0..<rows.count where !rows.element(boundBy: index).label.hasPrefix(name) {
            other = rows.element(boundBy: index)
            break
        }
        XCTAssertNotNil(other, "no other channel to select, so the draft cannot be flushed")
        other?.activate()
        Thread.sleep(forTimeInterval: 1)

        let restored = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        restored.activate()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.textFields["connect.host"].firstMatch.value as? String, host)
        XCTAssertEqual(app.textFields["connect.module"].firstMatch.value as? String, module)
    }
}
