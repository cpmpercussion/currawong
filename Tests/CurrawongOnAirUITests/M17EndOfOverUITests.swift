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
        type(reflector, intoFieldLabelled: "Host", in: app)
        type(module, intoFieldLabelled: "Module", in: app)

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

        ptt.press(forDuration: overDuration)

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

    /// Replaces a field's contents rather than appending to them: these fields
    /// come back from the app's saved settings, so they are rarely empty.
    private func type(_ text: String, intoFieldLabelled label: String, in app: XCUIApplication) {
        let field = app.textFields[label].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field labelled \(label)")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
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
