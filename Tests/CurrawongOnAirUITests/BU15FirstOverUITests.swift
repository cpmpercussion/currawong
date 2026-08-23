// SPDX-License-Identifier: Apache-2.0

import XCTest

/// **`BU-15`, measured rather than watched.** The first transmit of an over
/// does a visible dance — press PTT, a pause, the strip flashes red, goes back
/// to not-red, then red and actually transmitting. This counts the flashes.
///
/// ## Why this has to be a device test
///
/// `BU-15`'s iOS trigger is `escalateForCapture()`'s `listening` → `radio`
/// category change: SF-3 sees the resulting route change, correctly treats it
/// as real, and `resumeAcrossRouteChange()` drops transmit and keys back down.
///
/// **The simulator cannot show this.** Measured 2026-08-23 by
/// `BU15SessionProbeTests`: the simulator performs the route change — the
/// built-in mic enters and leaves `currentRoute.inputs` on cue — but posts no
/// `routeChangeNotification` for it at all, so SF-3 never fires and the first
/// over looks perfectly clean. A simulator run of this test would pass against
/// an unfixed app. That is the whole reason this target gained an iOS
/// destination.
///
/// On macOS the trigger is different — the SCO bring-up swapping the A2DP
/// device for the HFP device — so this test is meaningful there too, but only
/// with a Bluetooth accessory connected. With no accessory, macOS has no
/// trigger and this passes vacuously, which is why the count is reported
/// either way rather than only asserted.
///
/// ## This transmits
///
/// Same terms as `M17EndOfOverUITests`: opt-in target, own scheme, and a
/// callsign that has to be supplied rather than invented. See
/// ``IsolatedApp/requireOperatorCallsign()``.
///
/// ```sh
/// xcodebuild -project Currawong.xcodeproj -scheme CurrawongOnAir \
///     -derivedDataPath DerivedData -allowProvisioningUpdates \
///     -destination 'platform=iOS,id=<melchior>' \
///     -only-testing:CurrawongOnAirUITests/BU15FirstOverUITests \
///     TEST_RUNNER_CURRAWONG_ONAIR_CALLSIGN=<yours> test
/// ```
///
/// ## What this asserts, and how it manages to
///
/// **A test cannot watch the app during its own gesture.**
/// `press(forDuration:)` blocks the main thread, and every route off it is
/// refused — a backgrounded press throws `Must be called on the main thread`,
/// and backgrounded sampling throws `Activity cannot be used after its scope
/// has completed`, or `Current context must not be nil` if you wrap it in an
/// activity of its own. All three were tried on the device on 2026-08-23.
///
/// So the count outlives the press instead. `RadioSession.keyDownsInCurrentHold`
/// is reset only by a press the *operator* makes, so after the release it still
/// holds the number of times the radio was keyed inside that one hold, and the
/// transmit strip carries it as an accessibility value in DEBUG builds. **One
/// press must produce exactly one key-down**; two is `BU-15`.
///
/// That replaces the log-reading this test used to depend on, which needed
/// `sudo log collect` in a real terminal within a few minutes of the run (see
/// `scripts/bu15-measure.sh` §8 of `docs/HANDOFF-BU15.md`). The script still
/// exists and is still the way to see the *timing* — this is the way to see the
/// *count*, unattended.
///
/// It also still prints the window it happened in, and asserts that the key
/// comes back up when the operator lets go: a stuck key is the failure this app
/// exists to prevent.
final class BU15FirstOverUITests: XCTestCase {

    private let reflector = "m17-cbr.charlesmartin.au"
    private let module = "A"
    private let channelName = "BU-15 first over"

    /// Long enough to contain the whole escalation dance — the residual cost
    /// recorded under `BU-17` is about a second — with room either side, and
    /// nowhere near SF-1's 180 s watchdog.
    private let overDuration: TimeInterval = 6

    override func setUp() {
        continueAfterFailure = false
    }

    func testTheFirstOverKeysOnceAndStaysKeyed() throws {
        let callsign = try IsolatedApp.requireOperatorCallsign()
        let app = IsolatedApp.launched()

        addChannel(named: channelName, in: app)
        selectM17Mode(in: app)
        replace(callsign, in: field("connect.callsign", in: app))
        replace(reflector, in: field("connect.host", in: app))
        replace(module, in: field("connect.module", in: app))

        showSessionPane(in: app)
        let connect = app.buttons["Connect to \(channelName)"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "no link button naming this channel")
        connect.activate()

        let ptt = app.descendants(matching: .any)["Push to talk"].firstMatch
        XCTAssertTrue(ptt.waitForExistence(timeout: 20), "no PTT control")
        XCTAssertTrue(
            waitUntil(timeout: 30) { ptt.isEnabled && ptt.isHittable },
            "the link never came up — PTT stayed disabled")

        // **One clean hold, and the clock around it.**
        //
        // The dance happens *inside* the press, and XCUITest cannot watch it:
        // `press(forDuration:)` blocks the main thread for the whole hold, and
        // XCTest refuses UI queries from anywhere else. Both ways round were
        // tried on the device, 2026-08-23, and both throw —
        // `Must be called on the main thread` for a backgrounded press, and
        // `Activity cannot be used after its scope has completed` (then
        // `Current context must not be nil`) for backgrounded sampling, with or
        // without an explicit `XCTContext.runActivity`.
        //
        // So the count is read *after* the release instead, off the transmit
        // strip's accessibility value, from a counter the app resets only on a
        // fresh operator press. See the type note.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let began = Date()
        print("=== BU-15 hold began \(formatter.string(from: began))")
        ptt.press(forDuration: overDuration)
        let ended = Date()
        print("=== BU-15 hold ended \(formatter.string(from: ended))")
        print(
            "=== BU-15 window \(formatter.string(from: began)) .. "
                + "\(formatter.string(from: ended))")

        // What this test *can* see: the app is unkeyed once the operator lets
        // go. A stuck key is the failure this whole app exists to prevent, so
        // it is worth asserting even though it is not what BU-15 is about.
        let idleStrip = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                "Not transmitting", "Not transmitting")).firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 5) { idleStrip.exists },
            "the transmit strip still does not say the radio is unkeyed after PTT was released")

        // **`BU-15` itself.** One continuous hold, one key-down. Before the fix
        // this was 2: the escalation to the radio policy happened under a live
        // carrier, iOS posted the route change it caused, and SF-3 correctly
        // dropped the transmission the escalation was enabling.
        let strip = app.descendants(matching: .any)["session.transmitStrip"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "no transmit strip")
        let keyDowns = keyDownsInHold(from: strip)
        // The whole trace, printed whether or not the assertion holds: where
        // the route changes landed is what says *why*. `prep=` are the
        // escalation's own, ignored while nothing was on air; `tx=` are the ones
        // that reached SF-3 with the radio keyed, and every one of those is a
        // drop the operator saw.
        print("=== BU-15 trace: \((strip.value as? String) ?? "unreadable")")
        XCTAssertEqual(
            keyDowns, 1,
            "one press must key the radio once — more than one is the BU-15 dance")

        // **The second over, inside the hand-back linger — `BU-16`'s fast
        // path.** Nothing has moved the route since the first over: the session
        // is still on the radio policy and the engine's input unit is still up,
        // so `settleRoute()` must find nothing to wait for. `prepMs` is printed
        // rather than asserted — it is a wall-clock number on a phone, and the
        // invariant worth pinning is the key-down count.
        ptt.press(forDuration: 2)
        _ = waitUntil(timeout: 5) { idleStrip.exists }
        let warm = (strip.value as? String) ?? "unreadable"
        print("=== BU-15 warm over: \(warm)")
        XCTAssertEqual(
            keyDownsInHold(from: strip), 1,
            "an over inside the linger must key once too")

        disconnectAndTidy(app)
    }

    /// Reads the DEBUG-only `keyDowns=N` the transmit strip carries as its
    /// accessibility value. `nil` rather than a failure if it is absent, so the
    /// caller can say *why* — a release build of the app is the likely reason,
    /// and "unreadable" is a more useful report than "0".
    private func keyDownsInHold(from strip: XCUIElement) -> Int? {
        guard let value = strip.value as? String else { return nil }
        for field in value.split(separator: " ") where field.hasPrefix("keyDowns=") {
            return Int(field.dropFirst("keyDowns=".count))
        }
        return nil
    }

    // MARK: - Session

    private func disconnectAndTidy(_ app: XCUIApplication) {
        let disconnect = app.buttons["Disconnect"].firstMatch
        if disconnect.exists { disconnect.activate() }
        _ = waitUntil(timeout: 30) {
            !app.staticTexts["Disconnect to add, edit or delete channels."].exists
        }
    }

    // MARK: - The test's own channel

    private func addChannel(named name: String, in app: XCUIApplication) {
        let add = app.buttons["Add channel"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add channel button")
        add.activate()
        replace(name, in: field("connect.channelName", in: app))
    }

    private func selectM17Mode(in app: XCUIApplication) {
        let candidates = [
            app.radioButtons["M17"].firstMatch,
            app.segmentedControls.buttons["M17"].firstMatch,
            app.buttons["M17"].firstMatch,
            app.descendants(matching: .any)["M17"].firstMatch,
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 2) {
            candidate.activate()
            return
        }
        XCTFail("no M17 mode control")
    }

    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(identifier)")
        return field
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
