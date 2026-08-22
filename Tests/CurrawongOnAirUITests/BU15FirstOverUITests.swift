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
/// ## What a pass and a failure mean
///
/// The hold is one continuous press. Any *interruption* of transmit inside it
/// is the dance: the operator never let go, so the strip going from
/// transmitting to not-transmitting and back is the app dropping and re-keying
/// underneath them. Zero interruptions is the fixed behaviour. The count is
/// printed on every run, so a partial improvement — three flaps down to one —
/// is visible rather than just "still failing".
final class BU15FirstOverUITests: XCTestCase {

    private let reflector = "m17-cbr.charlesmartin.au"
    private let module = "A"
    private let channelName = "BU-15 first over"

    /// Long enough to contain the whole escalation dance — the residual cost
    /// recorded under `BU-17` is about a second — with room either side, and
    /// nowhere near SF-1's 180 s watchdog.
    private let overDuration: TimeInterval = 6

    /// Fast enough to catch a flash the operator can see. The dance is on the
    /// order of a second, so 100 ms samples it about ten times.
    private let samplePeriod: TimeInterval = 0.1

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

        let connect = app.buttons["Connect to \(channelName)"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "no link button naming this channel")
        connect.activate()

        let ptt = app.descendants(matching: .any)["Push to talk"].firstMatch
        XCTAssertTrue(ptt.waitForExistence(timeout: 20), "no PTT control")
        XCTAssertTrue(
            waitUntil(timeout: 30) { ptt.isEnabled && ptt.isHittable },
            "the link never came up — PTT stayed disabled")

        // **The hold and the sampling have to overlap**, and `press(forDuration:)`
        // blocks for the whole hold. So the press goes to a background queue and
        // the samples are taken here, which is the only way to see *inside* one
        // continuous press. A test that keyed, released, and then looked would
        // see the settled state and never the dance at all.
        let holding = expectation(description: "the hold finished")
        DispatchQueue.global(qos: .userInitiated).async {
            ptt.press(forDuration: self.overDuration)
            holding.fulfill()
        }

        let samples = sampleTransmitState(in: app, for: overDuration)
        wait(for: [holding], timeout: overDuration + 30)

        // Trim to the part of the hold after transmit first came up: everything
        // before that is the app getting started, not an interruption of
        // something that was running.
        guard let firstKeyed = samples.firstIndex(of: true) else {
            XCTFail(
                "transmit never started at all during a \(overDuration)s hold — that is not "
                    + "BU-15, it is a dead PTT. Samples: \(render(samples))")
            return
        }
        let afterKeyUp = Array(samples[firstKeyed...])
        let interruptions = afterKeyUp.dropFirst().enumerated()
            .filter { !$0.element && afterKeyUp[$0.offset] }
            .count

        print("=== BU-15 first over: \(interruptions) interruption(s) inside one hold")
        print("=== BU-15 samples (\(Int(1 / samplePeriod))/s): \(render(samples))")

        XCTAssertEqual(
            interruptions, 0,
            "BU-15: transmit was interrupted \(interruptions) time(s) during a single "
                + "uninterrupted hold — the operator never let go. Samples: \(render(samples))")

        disconnectAndTidy(app)
    }

    // MARK: - Sampling

    /// Whether the transmit strip currently says the radio is keyed, sampled on
    /// a fixed period for `duration`.
    ///
    /// The strip is one combined accessibility element carrying
    /// `TransmitBanner.accessibilityDescription`. A SwiftUI `Text` can arrive
    /// with an empty label and its string in `value`, so both are checked —
    /// `M17EndOfOverUITests` reported a release it had never checked by
    /// matching neither.
    private func sampleTransmitState(in app: XCUIApplication, for duration: TimeInterval)
        -> [Bool]
    {
        let idle = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                "Not transmitting", "Not transmitting")).firstMatch
        // `TransmitBanner.accessibilityDescription` is "Transmitting. On air."
        // when keyed and "Not transmitting. Standby." when not — so the keyed
        // prefix is *"Transmitting"*, not "On air". `BEGINSWITH` is
        // case-sensitive and anchored, which is what keeps this from also
        // matching "Not transmitting"; a `CONTAINS` here would match both and
        // score every sample as keyed.
        let onAir = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                "Transmitting", "Transmitting")).firstMatch

        var samples: [Bool] = []
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            // Read "on air" positively rather than inferring it from the
            // absence of the idle strip: mid-transition neither exists for a
            // frame, and inferring would score that frame as keyed.
            if onAir.exists {
                samples.append(true)
            } else if idle.exists {
                samples.append(false)
            }
            Thread.sleep(forTimeInterval: samplePeriod)
        }
        return samples
    }

    /// `▔` keyed, `_` not — a shape that can be read at a glance in a log.
    private func render(_ samples: [Bool]) -> String {
        samples.map { $0 ? "▔" : "_" }.joined()
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
