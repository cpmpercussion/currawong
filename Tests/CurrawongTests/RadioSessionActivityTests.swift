// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// **APP-3, SF-4.** The lock-screen transmit indicator, driven from
/// ``RadioSession``.
///
/// The requirement is not "show a Live Activity". It is that transmit state is
/// visible without unlocking the device *and never wrong*, and the second half
/// is the hard one: an activity still claiming TX after transmission stopped is
/// worse than none at all, because it is a safety display that lies and an
/// operator who catches it lying stops reading it.
///
/// So the test that matters here is ``testEveryStopReasonTakesTheIndicatorDown``,
/// the SF-4 counterpart to
/// ``RadioSessionTransmitTests/testEveryReleasePathEndsTransmission``: it walks
/// ``TransmitStopReason/allCases`` and proves each one leaves the lock screen
/// empty. Everything else in this file drives one of the six named paths — 
/// release, watchdog (SF-1), accessory loss (SF-2), interruption and route
/// change (SF-3), disconnection — and one that is not a stop at all, the
/// route-change recovery that must *not* take the banner down.
@MainActor
final class RadioSessionActivityTests: XCTestCase {

    // MARK: Up, and honest

    func testKeyingUpShowsTheChannelOnTheLockScreen() async {
        let harness = SessionHarness()
        await harness.connect()

        await harness.keyDown()

        XCTAssertTrue(harness.activityPresenter.isShowing)
        let shown = harness.activityPresenter.shownState
        XCTAssertEqual(shown?.isOnAir, true)
        XCTAssertEqual(shown?.detail, PTTSource.onScreen.holdDescription)

        guard case .start(let request)? = harness.activityPresenter.calls.first else {
            return XCTFail("no activity was started")
        }
        XCTAssertEqual(request.channel, SessionHarness.goodSettings.displayName)
        XCTAssertEqual(request.mode, RadioMode.allStarLink.displayName)
    }

    /// `isOnAir` follows the *client*, not the button. An indicator that goes
    /// red on touch-down is red before anything is on air, which is the same
    /// class of lie as one that stays red after the microphone shuts.
    func testTheIndicatorWaitsForTheClientRatherThanTheButton() async {
        let harness = SessionHarness()
        await harness.connect()

        harness.session.beginTransmit()
        XCTAssertTrue(harness.session.isKeyDown, "setup: the button responds on touch-down")
        await harness.session.settleActivity()
        XCTAssertFalse(
            harness.activityPresenter.isShowing,
            "the lock screen must not claim TX before the client is keyed")

        await harness.settleAll()
        XCTAssertTrue(harness.activityPresenter.isShowing)
    }

    /// PT-4. A latched transmission says so, because the operator cannot see the
    /// button and letting go of it will not unkey them.
    func testALatchedTransmissionSaysSoOnTheLockScreen() async {
        let harness = SessionHarness()
        await harness.connect()

        harness.session.beginTransmit(from: .remoteCommand)
        await harness.settleAll()

        XCTAssertEqual(
            harness.activityPresenter.shownState?.detail, PTTSource.remoteCommand.holdDescription)
    }

    /// SF-1's leash, on the lock screen. The widget renders the countdown from
    /// this date, so it costs no ActivityKit updates — but only if the date is
    /// actually there.
    func testTheWatchdogDeadlineTravelsWithTheIndicator() async {
        let harness = SessionHarness(timeout: TransmitTimeout(seconds: 60))
        await harness.connect()

        await harness.keyDown()

        guard let deadline = harness.activityPresenter.shownState?.watchdogDeadline else {
            return XCTFail("SF-1's deadline never reached the lock screen")
        }
        XCTAssertEqual(deadline.timeIntervalSinceNow, 60, accuracy: 5)
    }

    // MARK: Down — the six paths

    /// **The one that matters.** Every way transmission can end, and the lock
    /// screen empty afterwards in each of them. A case here that fails is a
    /// stuck TX indicator on a locked phone.
    func testEveryStopReasonTakesTheIndicatorDown() async {
        for reason in TransmitStopReason.allCases {
            let harness = SessionHarness()
            await harness.connect()
            await harness.keyDown()
            XCTAssertTrue(
                harness.activityPresenter.isShowing, "setup failed for \(reason)")

            harness.session.endTransmit(reason: reason)
            await harness.settleAll()

            XCTAssertFalse(
                harness.activityPresenter.isShowing,
                "\(reason) left a transmit indicator on the lock screen")
            XCTAssertNil(
                harness.activityPresenter.visibleState,
                "\(reason) left the lock screen claiming TX")
        }
    }

    /// Path 1: the ordinary release.
    func testReleaseEndsTheIndicator() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        harness.session.pttReleased(from: .onScreen, reason: .released)
        await harness.settleAll()

        XCTAssertFalse(harness.activityPresenter.isShowing)
    }

    /// Path 2: SF-1. The library unkeys itself and tells the app; the app has to
    /// take the lock screen down with the microphone.
    func testTheWatchdogEndsTheIndicator() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.eventContinuation.yield(.transmitWatchdogExpired(.seconds(180)))

        await waitUntil("the watchdog takes the lock screen down") {
            !harness.activityPresenter.isShowing
        }
    }

    /// Path 3: SF-2. The accessory that might have been holding the key fell off
    /// the link, so nobody can answer "is the button still down?" — and this is
    /// the case where the lock screen is the *only* place the operator would
    /// have seen it, because the phone is in a pocket.
    func testAccessoryLinkLossEndsTheIndicator() async {
        let harness = SessionHarness()
        await harness.connect()
        harness.session.beginTransmit(from: .accessory)
        await harness.settleAll()
        XCTAssertTrue(harness.activityPresenter.isShowing, "setup: keyed by the accessory")

        harness.session.accessoryLinkLost()
        await harness.settleAll()

        XCTAssertFalse(harness.activityPresenter.isShowing)
        XCTAssertEqual(harness.session.lastStopReason, .accessoryLinkLost)
    }

    /// Path 4: SF-3, the interruption half. Never resumed, so the indicator goes
    /// and stays gone.
    func testAnInterruptionEndsTheIndicator() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.interruptionBegan)

        await waitUntil("the interruption takes the lock screen down") {
            !harness.activityPresenter.isShowing
        }
        XCTAssertEqual(harness.session.lastStopReason, .audioInterrupted)
    }

    /// Path 6: the operator hangs up.
    func testDisconnectingEndsTheIndicator() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        await harness.session.disconnect()
        await harness.settleAll()

        XCTAssertFalse(harness.activityPresenter.isShowing)
    }

    /// Path 6's other half: the far end, or the transport, ended the call. The
    /// operator did nothing, so nothing would have prompted them to look.
    func testALostLinkEndsTheIndicator() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.eventContinuation.yield(.disconnected(reason: "the node ended the call"))

        await waitUntil("a dropped link takes the lock screen down") {
            !harness.activityPresenter.isShowing
        }
    }

    /// Locking the phone backgrounds the app, which unkeys — so the indicator
    /// must go with it. Worth its own test because this is the transition SF-4
    /// is named after, and the wrong reading of the requirement ("the banner
    /// appears when the screen locks") would leave it up.
    func testBackgroundingEndsTheIndicator() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        harness.session.setForeground(false)
        await harness.settleAll()

        XCTAssertFalse(harness.activityPresenter.isShowing)
        XCTAssertEqual(harness.session.lastStopReason, .appBackgrounded)
    }

    /// Path 7: app termination. A Live Activity outlives the process that
    /// requested it, so a Currawong killed mid-over leaves a banner claiming TX
    /// with nothing behind it. ``RadioSession/start()`` is the launch hook that
    /// clears it, and it must run before anything can key up.
    func testStartingUpClearsAnActivityLeftByAPreviousRun() async {
        let harness = SessionHarness()

        harness.session.start()
        await harness.session.settleActivity()

        XCTAssertEqual(harness.activityPresenter.calls, [.endOrphans])
    }

    /// A key-down that failed took nothing on air, so there must be nothing on
    /// the lock screen either — and the hold is over, so a later route change
    /// has nothing to key back down.
    func testAFailedKeyDownShowsNothing() async {
        let harness = SessionHarness()
        await harness.connect()
        harness.audio.startCaptureError = SessionHarness.AudioFailed()

        await harness.keyDown()

        XCTAssertFalse(harness.activityPresenter.isShowing)
        XCTAssertEqual(harness.session.lastStopReason, .transmitFailed)
    }

    // MARK: Path 5 — SF-3's route change, which is not simply a stop

    /// **The case that changed on 2026-08-20.** A route change under a held
    /// button no longer ends the over: ``RadioSession`` keys back down once the
    /// audio graph settles. So "ends on SF-3" means "ends when the hold ends",
    /// and the indicator must survive the gap in the middle without blinking
    /// off and back on — an indicator that flickers is one the operator learns
    /// to disbelieve.
    func testARouteChangeUnderAHeldButtonDoesNotRestartTheIndicator() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()
        XCTAssertEqual(harness.activityPresenter.startCount, 1, "setup")

        // **Both waits, in this order.** Waiting only for the recovery waits for
        // a condition that is already true — transmit has not stopped yet — and
        // asserts on a route change the session has not seen. That reads as a
        // pass and proves nothing.
        harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
        await waitUntil("the route change drops transmit") { !harness.client.isTransmitting }
        await waitUntil("transmit comes back on its own") { harness.client.isTransmitting }
        await harness.settleAll()

        XCTAssertEqual(
            harness.activityPresenter.startCount, 1,
            "the lock-screen indicator was torn down and rebuilt across the route change")
        XCTAssertEqual(harness.activityPresenter.endCount, 0)
        XCTAssertTrue(harness.activityPresenter.isShowing)
        XCTAssertEqual(harness.activityPresenter.shownState?.isOnAir, true)
    }

    // MARK: - The idle gate on BU-14's repair

    /// **The safety-relevant half of `BU-14`'s repair.** Rebuilding the
    /// accessory link means disconnecting it, and SF-2 makes a disconnection
    /// unkey unconditionally — so a repair fired during an over would be a way of
    /// dropping the operator mid-sentence.
    ///
    /// The guard is here rather than in `BLEPTTController` because this is the
    /// class that knows whether anything is on air. Nothing downstream suppresses
    /// SF-2; the hook simply is not called.
    func testARouteChangeUnderAHeldButtonDoesNotAskForARepair() async {
        let harness = SessionHarness()
        var repairRequests = 0
        harness.session.onIdleAudioRouteChange = { repairRequests += 1 }
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        // Both waits, in this order, for the reason the tests above give: the
        // recovery condition is already true before the session has seen
        // anything.
        harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
        await waitUntil("the route change drops transmit") { !harness.client.isTransmitting }
        await waitUntil("transmit comes back on its own") { harness.client.isTransmitting }
        await harness.settleAll()

        XCTAssertEqual(
            repairRequests, 0,
            "a repair was requested while the operator was holding the button")
    }

    /// **A route change just after an over is exactly when a repair is wanted.**
    ///
    /// This test previously asserted the opposite, on the reasoning that a link
    /// which had just carried a press could not need rebuilding. That was wrong:
    /// the press proves the link was alive *before* the over, and the accessory
    /// link dies on the way **down**, during the unkey. Measured 2026-08-22 — the
    /// route-change bursts land 1.3 s and 2.5 s after key-up, a quiet period
    /// swallowed both, and the button stayed dead for 113 seconds.
    ///
    /// It also used to pass for the wrong reason: `settleAll()` returns before the
    /// signal has been consumed, so it read the counter too early. Hence the
    /// explicit wait.
    func testARouteChangeJustAfterAnOverDoesAskForARepair() async {
        let harness = SessionHarness()
        var repairRequests = 0
        harness.session.onIdleAudioRouteChange = { repairRequests += 1 }
        harness.session.start()
        await harness.connect()

        await harness.keyDown()
        harness.session.endTransmit(reason: .released)
        await harness.settleAll()
        XCTAssertFalse(harness.client.isTransmitting, "setup: the over has ended")

        // The route change that unkeying itself causes — and the moment the link
        // needs rebuilding.
        harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
        await waitUntil("the repair is requested") { repairRequests == 1 }
    }

    /// And the other side of it: with nothing keyed, a route change is exactly
    /// when the link should be rebuilt, because the button is needed for the
    /// *next* press and this is the moment nobody is using it.
    func testARouteChangeWhileIdleAsksForARepair() async {
        let harness = SessionHarness()
        var repairRequests = 0
        harness.session.onIdleAudioRouteChange = { repairRequests += 1 }
        harness.session.start()
        await harness.connect()

        harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
        await waitUntil("the repair is requested") { repairRequests == 1 }
        await harness.settleAll()

        XCTAssertEqual(repairRequests, 1)
        XCTAssertFalse(harness.client.isTransmitting, "nothing should have keyed")
    }

    /// It stays up, but it does not lie: during the gap nothing is on air and it
    /// says so. Red means "your voice is going out", and it may not be shown
    /// over a microphone that is shut, however briefly.
    func testTheIndicatorAdmitsItIsNotOnAirDuringTheGap() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        // **Both waits, in this order.** Waiting only for the recovery waits for
        // a condition that is already true — transmit has not stopped yet — and
        // asserts on a route change the session has not seen. That reads as a
        // pass and proves nothing.
        harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
        await waitUntil("the route change drops transmit") { !harness.client.isTransmitting }
        await waitUntil("transmit comes back on its own") { harness.client.isTransmitting }
        await harness.settleAll()

        XCTAssertEqual(
            harness.activityPresenter.shownStates.map(\.isOnAir), [true, false, true],
            "the indicator must go honest across the gap rather than holding TX up")
    }

    /// The elapsed clock measures the *hold*, so a resume under a button that was
    /// never released does not restart it. An over that looks younger than it is
    /// is an over the operator will let run longer.
    func testTheElapsedClockSurvivesTheResume() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()
        let began = harness.activityPresenter.shownState?.holdBegan

        harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
        await waitUntil("the route change drops transmit") { !harness.client.isTransmitting }
        await waitUntil("transmit comes back on its own") { harness.client.isTransmitting }
        await harness.settleAll()

        XCTAssertNotNil(began)
        XCTAssertEqual(harness.activityPresenter.shownState?.holdBegan, began)
    }

    /// Letting go during the gap ends it. This is the "ends when the hold ends"
    /// reading of SF-3, and the one path where the hold outlives the
    /// transmission.
    func testReleasingDuringTheGapEndsTheIndicator() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
        await waitUntil("the route change drops transmit") { !harness.client.isTransmitting }
        harness.session.endTransmit(reason: .released)
        await harness.settleAll()

        XCTAssertFalse(harness.activityPresenter.isShowing)

        // And it does not come back on its own, because there is no hold left.
        try? await Task.sleep(nanoseconds: 500_000_000)
        await harness.settleAll()
        XCTAssertFalse(
            harness.activityPresenter.isShowing,
            "the resume keyed back down under a button nobody was holding")
    }

    /// A route that will not settle spends its allowance and gives up. At that
    /// point nothing is going to key back down, so the indicator must end rather
    /// than sit there saying "keying back down" for ever.
    func testAFlappingRouteEndsTheIndicatorWhenItGivesUp() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        for _ in 0..<5 {
            harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
            await waitUntil("transmit stops") { !harness.client.isTransmitting }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        await harness.settleAll()

        XCTAssertFalse(harness.client.isTransmitting, "setup: the app gave up resuming")
        XCTAssertFalse(
            harness.activityPresenter.isShowing,
            "a route change that cannot be repaired must not leave an indicator up")
    }

    /// A route change with nobody holding the button is a non-event — plugging a
    /// headset in while listening. Nothing was showing and nothing starts.
    func testARouteChangeWithNoHoldShowsNothing() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()

        harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
        try? await Task.sleep(nanoseconds: 500_000_000)
        await harness.settleAll()

        XCTAssertEqual(
            harness.activityPresenter.startCount, 0,
            "a route change nobody was transmitting through started an indicator")
        XCTAssertFalse(harness.activityPresenter.isShowing)
    }

    /// SF-1 outranks the repair. The watchdog ends the hold, so there is nothing
    /// to key back down and nothing to keep on the lock screen — otherwise a
    /// held button plus a flapping route would hold a banner up indefinitely.
    func testTheWatchdogBeatsAPendingResume() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.routeChanged(.oldDeviceUnavailable))
        await waitUntil("the route change drops transmit") { !harness.client.isTransmitting }
        harness.session.endTransmit(reason: .watchdogExpired)
        await harness.settleAll()

        XCTAssertFalse(harness.activityPresenter.isShowing)

        try? await Task.sleep(nanoseconds: 500_000_000)
        await harness.settleAll()
        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.activityPresenter.isShowing)
    }
}
