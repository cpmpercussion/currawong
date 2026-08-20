// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Not a test of anything — a way to see what the accessibility tree actually
/// calls the controls, which is the only way to write queries against a
/// SwiftUI form that carries no identifiers. Kept because the next person to
/// touch the on-air test will need it too.
final class HierarchyDumpUITests: XCTestCase {
    func testDumpTheConnectForm() {
        let app = XCUIApplication()
        app.launch()
        let m17 = app.radioButtons["M17"].firstMatch
        if m17.waitForExistence(timeout: 5) { m17.click() }
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
            row.click()
        }

        let m17 = app.radioButtons["M17"].firstMatch
        if m17.waitForExistence(timeout: 5) { m17.click() }
        for (identifier, text) in [("connect.host", host), ("connect.module", module)] {
            let field = app.textFields[identifier].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(identifier)")
            replace(text, in: field)
        }
        // Typing alone does not persist: the draft reaches the channel list
        // only via connect(), addChannel() or select(). So select something
        // else — that saves the draft into the channel it is leaving — and
        // select back to prove it stuck.
        let name = env["RESTORE_CHANNEL"] ?? ""
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", M17,"))
        var other: XCUIElement?
        for index in 0..<rows.count where !rows.element(boundBy: index).label.hasPrefix(name) {
            other = rows.element(boundBy: index)
            break
        }
        XCTAssertNotNil(other, "no other channel to select, so the draft cannot be flushed")
        other?.click()
        Thread.sleep(forTimeInterval: 1)

        let restored = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        restored.click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.textFields["connect.host"].firstMatch.value as? String, host)
        XCTAssertEqual(app.textFields["connect.module"].firstMatch.value as? String, module)
    }
}
