// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The number pad can be put away.
///
/// The iOS number pad has no return key. Settings' transmit watchdog field
/// used it bare, so once the operator had typed a number the keyboard stayed
/// up over the rest of the screen, and the only way out was to focus a field
/// with a full keyboard and press return there. The field now carries a Done
/// button in the keyboard's toolbar (`numberPadWithDone()`).
///
/// **It transmits nothing and connects to nothing.** It is in this target
/// because this is the target that drives the real app; it needs no observer
/// and no credential. iOS only: macOS has no software keyboard to dismiss.
final class SettingsKeyboardUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testTheNumberPadHasADoneButtonThatDismissesIt() throws {
        #if os(macOS)
            throw XCTSkip("iOS only: there is no software keyboard on macOS.")
        #else
            let app = IsolatedApp.launched()
            // Never put on the air: this test opens Settings and nothing else,
            // so first run's question gets a placeholder when no callsign was
            // supplied.
            giveCallsign(IsolatedApp.operatorCallsign() ?? "N0CALL", in: app)

            let settings = app.tabBars.buttons["Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "no Settings tab")
            settings.tap()

            let field = app.textFields["settings.transmitTimeout"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "no transmit watchdog field")
            field.tap()

            let keyboard = app.keyboards.element(boundBy: 0)
            XCTAssertTrue(
                keyboard.waitForExistence(timeout: 5),
                "no software keyboard. In the Simulator, I/O > Keyboard > Connect Hardware "
                    + "Keyboard must be off for this test to mean anything.")

            let done = app.buttons["keyboard.done"].firstMatch
            XCTAssertTrue(
                done.waitForExistence(timeout: 5),
                "the number pad has no Done button, so it cannot be dismissed")
            done.tap()

            let deadline = Date().addingTimeInterval(5)
            while keyboard.exists, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            XCTAssertFalse(keyboard.exists, "Done did not put the keyboard away")
        #endif
    }
}
