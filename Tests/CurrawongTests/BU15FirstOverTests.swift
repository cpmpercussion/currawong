// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// **`BU-15`: the first transmit of an over must key once and stay keyed.**
///
/// The fault, measured on melchior on 2026-08-23 in one 6.4 s hold with no
/// accessory attached: press PTT, wait 0.8 s, the strip goes red, goes back to
/// not-red, then red again and finally transmits at 1.47 s. Two key-downs in
/// one hold, 385 ms of speech lost, and a `SafetyNotice` telling the operator
/// to press and hold a button they had never released.
///
/// Nothing was broken. Escalating the audio session to the radio policy is a
/// route change, iOS posts it, and SF-3 requires that transmission drop on a
/// route change — so it dropped the transmission the escalation was enabling.
///
/// The fix is an ordering, not an exception: the escalation happens *before*
/// anything is keyed, and the key-down waits for the cascade it causes to go
/// quiet. There is then no transmission for SF-3 to drop, so nothing has to be
/// distinguished from an unplugged accessory and SF-3 keeps its full force —
/// which the last test here is about.
///
/// These drive the cascade through the seam. The device is what confirms the
/// real one: the simulator posts no route-change notification for a category
/// change it demonstrably performs (`BU15SessionProbeTests`, 2026-08-23), so a
/// simulator run of the on-air test would pass against an unfixed app.
@MainActor
final class BU15FirstOverTests: XCTestCase {

    /// Emits `count` route changes from inside `settleRoute()`, waiting after
    /// each one until the session has **handled** it — which is the whole
    /// point: the signals have to be *delivered and handled* inside the awaited
    /// call, the reentrancy discipline the workspace `CLAUDE.md` asks for.
    /// Common-ordering delivery — before the press, or after the key-down —
    /// would miss this entirely.
    ///
    /// **It used to sleep 20 ms between signals and hope.** `emit` yields into
    /// an `AsyncStream` and returns; the session handles the signal later, on
    /// the main actor, whenever its consumer task is scheduled. On a machine
    /// with a core to spare that is well inside 20 ms — and on a loaded CI
    /// runner it is not, so the tail of the cascade was handled *after*
    /// `settleRoute()` returned and `routePreparationInFlight` had been
    /// cleared. SF-3 then did what SF-3 does to a signal outside preparation:
    /// dropped the hold and scheduled a repair, producing the second key-down
    /// this file exists to assert the absence of. The test failed with `BU-15`'s
    /// own symptom, on `main`, intermittently, having found nothing.
    ///
    /// Waiting on the session's own counter instead of on a clock makes the
    /// delivery a fact rather than a hope, and turns the interesting case —
    /// a signal that never lands during preparation at all — into a named
    /// failure instead of a confusing one.
    private func cascade(
        _ count: Int, on harness: SessionHarness,
        file: StaticString = #filePath, line: UInt = #line
    ) -> @Sendable () async -> Void {
        let audio = harness.audio
        let session = harness.session!
        return {
            for signal in 1...count {
                audio.emit(.routeChanged)
                await Self.waitUntilHandled(signal, by: session, file: file, line: line)
            }
        }
    }

    /// Waits until the session has counted the `n`th signal of a cascade as
    /// having arrived during preparation.
    ///
    /// Off the main actor by necessity — this runs inside `settleRoute()`,
    /// which the session is awaiting, so the main actor is free and hopping to
    /// it is what lets the consumer task run at all.
    private static func waitUntilHandled(
        _ n: Int, by session: RadioSession, file: StaticString, line: UInt
    ) async {
        // The same twenty seconds `waitUntil` allows, and for the same
        // reason: the budget has to cover a CI runner that stops scheduling
        // work, not just one that is busy. See the note there.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if await MainActor.run(body: { session.routeSignalsDuringPreparation }) >= n {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail(
            "the session never handled signal \(n) of the cascade as a preparation signal",
            file: file, line: line)
    }

    /// The fault itself. One press, a five-signal cascade landing while the
    /// route is being prepared, and exactly one key-down comes out.
    func testTheCascadeDuringPreparationCostsNeitherAKeyDownNorANotice() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        harness.audio.onSettleRoute = cascade(5, on: harness)

        await harness.keyDown()

        XCTAssertTrue(harness.client.isTransmitting)
        XCTAssertEqual(
            harness.client.calls.filter { $0 == .startTransmit }.count, 1,
            "one press, one key-down — the second one is BU-15")
        XCTAssertEqual(
            harness.client.calls.filter { $0 == .stopTransmit }.count, 0,
            "and no unkey in the middle of it")
        XCTAssertEqual(harness.audio.startCaptureCount, 1)
        XCTAssertNil(
            harness.session.safetyNotice,
            "nothing happened that the operator has to do anything about")
        XCTAssertNil(harness.session.lastStopReason)
        XCTAssertEqual(
            harness.session.keyDownsInCurrentHold, 1,
            "the instrument the device test reads must agree: one press, one key-down")
    }

    /// The ordering that makes the above safe to claim. The cascade cannot
    /// arrive under a live carrier because the carrier does not exist yet:
    /// preparation completes before `startTransmit()` is called.
    func testTheRouteIsPreparedBeforeAnythingIsKeyed() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()

        let keyedDuringPreparation = SessionHarness.Counter()
        let client = harness.client
        harness.audio.onSettleRoute = { [self] in
            if client.calls.contains(.startTransmit) { keyedDuringPreparation.bump() }
            await cascade(2, on: harness)()
        }

        await harness.keyDown()

        XCTAssertEqual(
            keyedDuringPreparation.value, 0,
            "the link must not be keyed while the route is still moving")
        XCTAssertEqual(harness.audio.settleRouteCount, 1)
        XCTAssertTrue(harness.client.isTransmitting)
    }

    /// A tap so short it ends while the route is settling. Nothing may go on
    /// air afterwards — that is `BU-16`'s rule, and preparation is one more
    /// suspension it has to hold across.
    func testAReleaseWhileTheRouteSettlesNeverKeysTheLink() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()

        let session = harness.session!
        harness.audio.onSettleRoute = {
            await MainActor.run { session.endTransmit(reason: .released) }
        }

        await harness.keyDown()

        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(
            harness.client.calls.contains(.startTransmit),
            "a release during preparation is a press that never reaches the air")
        XCTAssertEqual(
            harness.audio.startCaptureCount, 1,
            "the microphone opens before the carrier now — that is the fix")
        XCTAssertFalse(
            harness.audio.isCapturing,
            "but it must be shut again, and nothing captured in that window went anywhere")
        XCTAssertGreaterThan(
            harness.audio.stopCaptureCount, 0,
            "and the route still has to be handed back (BU-14)")
    }

    /// **The window closes.** The same hold that tolerated the cascade during
    /// preparation must still drop on a route change once it is on air — an
    /// accessory being unplugged mid-over is exactly what SF-3 is for, and this
    /// is the test that says the fix narrowed nothing.
    func testARouteChangeAfterPreparationStillDropsTransmit() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        harness.audio.onSettleRoute = cascade(3, on: harness)

        await harness.keyDown()
        XCTAssertTrue(harness.client.isTransmitting)

        // Nothing is preparing now, so this one is somebody pulling a plug.
        harness.audio.emit(.routeChanged)

        // **Waited for on the client's call log, not on `isTransmitting`.**
        // The drop and the repair are 300 ms apart, and `!isTransmitting` is
        // true only in that gap: a poll that does not land inside it sees a
        // transmitting client before and after, waits out the whole five-second
        // timeout and reports that SF-3 never fired. `calls` only ever grows,
        // so this cannot be missed by looking a moment too late.
        await waitUntil("SF-3 drops transmit") {
            harness.client.calls.contains(.stopTransmit)
        }
        XCTAssertEqual(harness.session.lastStopReason, .routeChanged)

        // And the instrument counts it, which is what makes it an instrument:
        // the operator never let go, so SF-3's repair keys back down, and *that*
        // is the second key-down `BU-15` was about. Here it is a real route
        // change earning one, rather than the app's own escalation.
        //
        // The wait is on the counter this line is about to assert, because the
        // client is keyed *before* the session counts it: `startTransmit()` is
        // awaited, and `keyDownsInCurrentHold += 1` happens when that call
        // resumes. Waiting on the client and then reading the counter is a race
        // across that resumption, and it lost — 1 instead of 2, reproduced
        // locally on an idle machine.
        await waitUntil("the hold is repaired") {
            harness.session.keyDownsInCurrentHold == 2
        }
        XCTAssertTrue(harness.client.isTransmitting)
    }

    /// **The un-cancelled resume.** Each signal of a cascade used to leave its
    /// own resume task running, so the app could key back down off a resume
    /// scheduled before the hold ended — 115 ms after telling the operator that
    /// transmission had stopped. SF-1 is where that matters: a watchdog unkey
    /// must not be undone by a resume already in the air.
    func testAWatchdogUnkeyCancelsAResumeAlreadyScheduled() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.routeChanged)

        // **Waited for on the instrument, not on the gap.** The signal is
        // counted, the hold dropped and the repair scheduled in one synchronous
        // region, so `routeSignalsWhileTransmitting` reaching 1 says all three
        // have happened — and it only ever grows. Waiting on `!isTransmitting`
        // instead was waiting on the 300 ms *gap* between the drop and the
        // repair, which a poll arriving late misses entirely: this test then
        // spent its whole timeout waiting for a drop that had already happened
        // and been repaired, which is the five-second failure seen on `main`.
        await waitUntil("SF-3 drops transmit and schedules a repair") {
            harness.session.routeSignalsWhileTransmitting == 1
        }

        // Inside the 300 ms settle, so the resume is scheduled and pending.
        harness.session.endTransmit(reason: .watchdogExpired)
        await harness.settleAll()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(
            harness.client.isTransmitting,
            "a watchdog unkey is final — nothing keys back down after it")
    }
}
