// SPDX-License-Identifier: Apache-2.0

import XCTest

/// BU-8's app half: drive a real over from Currawong and let somebody else
/// watch it end.
///
/// ## This transmits
///
/// It is a UI test only in mechanism. What it actually does is key a live M17
/// reflector under the operator's callsign, which is why this target is **not
/// in the `Currawong` scheme's `testTargets`** and never runs under `make test`
/// or in CI. It runs from the `CurrawongOnAir` scheme, on purpose, when
/// somebody means it:
///
/// ```sh
/// xcodebuild -project Currawong.xcodeproj -scheme CurrawongOnAir \
///     -derivedDataPath DerivedData -destination 'platform=macOS' test
/// ```
///
/// ## It proves nothing on its own
///
/// The whole question — does the far end see the stream *end*, or does the
/// audio just stop — is invisible from the transmitting side, which is the
/// point of BU-8. **Run an observer against the same module while this runs:**
///
/// ```sh
/// cd ../swift-hamvoip
/// swift run hamvoip-cli m17 --host m17-cbr.charlesmartin.au --module A \
///     --callsign <yours-with-a-suffix> --no-audio --duration 120
/// ```
///
/// A pass is the observer printing `RX <callsign> ended — end of over` within a
/// moment of the release. This test's own assertions only establish that the
/// app got as far as a real over: connected, keyed, stayed keyed, unkeyed.
///
/// ## Two things it needs from the machine
///
/// - **Microphone permission for Currawong.** Without it the app captures
///   nothing and an over carries no frames at all — the same shape as the
///   library CLI's `--no-audio`, which says it sends silence and sends
///   nothing. macOS prompts once, per app, and a prompt will stall this test.
///   Run it once by hand and click Allow before expecting it to be repeatable.
/// - **The app's real settings.** This is the installed app's bundle
///   identifier, so it reads and writes the same defaults the app normally
///   uses. It leaves the current channel pointed at the reflector below, in
///   M17 mode. That is not cleaned up, deliberately: making a test tidy away
///   an operator's channel is worse than leaving an obvious one behind.
final class M17EndOfOverUITests: XCTestCase {

    private let reflector = "m17-cbr.charlesmartin.au"
    private let module = "A"

    /// How long PTT is held. Long enough to be unambiguous at the observer —
    /// 40 ms per datagram, so three seconds is about 75 of them — and short
    /// enough to be nowhere near the transmit watchdog.
    private let overDuration: TimeInterval = 3

    override func setUp() {
        continueAfterFailure = false
    }

    func testAnOverEndsWhenPTTIsReleased() throws {
        let app = XCUIApplication()
        app.launch()

        selectM17Mode(in: app)

        let host = field("connect.host", in: app)
        let moduleField = field("connect.module", in: app)

        // ⚠️ This leaves the current channel pointed at the reflector below,
        // in M17 mode. Restoring it was tried and removed: the runner holds
        // keyboard focus once the test body ends, `app.activate()` does not
        // take it back, and a teardown that cannot type is a teardown that
        // fails a test which otherwise passed. Point the channel back by hand,
        // or give this test a channel of its own.

        replace(reflector, in: host)
        replace(module, in: moduleField)

        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "no Connect button")
        connect.click()

        // The link is up when the PTT control stops saying "Connect to a node
        // first" — the button exists either way, so its existence proves
        // nothing and its enabled-ness is the real signal.
        let ptt = app.descendants(matching: .any)["Push to talk"].firstMatch
        XCTAssertTrue(ptt.waitForExistence(timeout: 20), "no PTT control")
        XCTAssertTrue(
            waitUntil(timeout: 30) { ptt.isEnabled && ptt.isHittable },
            "the link never came up — PTT stayed disabled")

        // A microphone prompt is a system dialog, and it appears the first time
        // the app captures — which is the moment PTT is pressed. Report it
        // rather than timing out mysteriously behind it.
        if app.dialogs.count > 0 {
            print("=== DIALOG BEFORE PTT: \(app.dialogs.firstMatch.debugDescription)")
        }

        ptt.press(forDuration: overDuration)

        // The banner renders only while transmitting, so its disappearance is
        // the app's own statement that the over ended. Give SwiftUI a moment
        // to re-render before believing either answer.
        // Narrow, and deliberately so: a `descendants(matching: .any)` query
        // with a predicate takes minutes against this tree and times out.
        let banner = app.staticTexts["On air."].firstMatch
        let stopped = waitUntil(timeout: 5) { !banner.exists }
        print("=== TRANSMIT BANNER CLEARED AFTER RELEASE: \(stopped)")
        XCTAssertTrue(stopped, "the app still shows a transmit banner after PTT was released")

        // Nothing here can see the far end. Hold the session open long enough
        // for a human or an observer process to read its output, then hang up
        // cleanly so the reflector is not left with a dangling link.
        Thread.sleep(forTimeInterval: 3)

        let disconnect = app.buttons["Disconnect"].firstMatch
        if disconnect.exists { disconnect.click() }
    }

    // MARK: - Driving the form

    /// The mode picker is a segmented `Picker`, which surfaces as radio buttons
    /// on macOS rather than as a segmented control.
    private func selectM17Mode(in app: XCUIApplication) {
        let m17 = app.radioButtons["M17"].firstMatch
        if m17.waitForExistence(timeout: 5) {
            m17.click()
            return
        }
        let fallback = app.descendants(matching: .any)["M17"].firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 5), "no M17 mode control")
        fallback.click()
    }

    /// The form's fields carry no accessibility labels — SwiftUI gives a
    /// `TextField` its placeholder and nothing else — so the app names the
    /// three this test drives with identifiers. Placeholders would have worked
    /// today and broken the first time somebody reworded one.
    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(identifier)")
        return field
    }

    fileprivate func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }
}

/// Replaces a field's contents rather than appending to them: these come back
/// from the app's saved settings, so they are rarely empty.
private func replace(_ text: String, in field: XCUIElement) {
    field.click()
    field.typeKey("a", modifierFlags: .command)
    if text.isEmpty {
        field.typeKey(.delete, modifierFlags: [])
    } else {
        field.typeText(text)
    }
}
