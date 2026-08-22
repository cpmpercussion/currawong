// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// PT-1 and the safety requirements that hang off it.
///
/// The single most important test in this repository is
/// ``testEveryReleasePathEndsTransmission``: it enumerates
/// ``TransmitStopReason/allCases`` and proves that each one leaves the client
/// unkeyed and the microphone shut. A stuck open microphone into a repeater is
/// the failure mode the whole project is arranged around, and this is the
/// assertion that says it cannot happen from the app's side.
@MainActor
final class RadioSessionTransmitTests: XCTestCase {

    // MARK: The basic gesture

    func testPressTransmitsAndReleaseStops() async {
        let harness = SessionHarness()
        await harness.connect()

        harness.session.beginTransmit()
        XCTAssertTrue(harness.session.isKeyDown, "the button must respond on touch-down")
        await harness.session.settle()

        XCTAssertTrue(harness.session.isTransmitting)
        XCTAssertTrue(harness.client.isTransmitting)
        XCTAssertTrue(harness.audio.isCapturing, "the microphone must be open while transmitting")
        XCTAssertTrue(harness.client.calls.contains(.startTransmit))

        await harness.session.endTransmitAndWait(reason: .released)

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.session.isKeyDown)
        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.session.lastStopReason, .released)
    }

    func testTransmitStateIsMirroredFromTheClient() async {
        let harness = SessionHarness()
        await harness.connect()

        await harness.keyDown()
        XCTAssertTrue(TransmitStatusPresentation(state: harness.session.transmitState).isTransmitting)

        await harness.session.endTransmitAndWait(reason: .released)
        XCTAssertFalse(TransmitStatusPresentation(state: harness.session.transmitState).isTransmitting)
    }

    func testTransmittingWithoutAConnectionIsRefused() async {
        let harness = SessionHarness()

        harness.session.beginTransmit()
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertTrue(harness.client.calls.isEmpty)
        XCTAssertNotNil(harness.session.alert, "the refusal must be explained, not silent")
    }

    func testHoldingIsIdempotent() async {
        let harness = SessionHarness()
        await harness.connect()

        harness.session.beginTransmit()
        harness.session.beginTransmit()
        harness.session.beginTransmit()
        await harness.session.settle()

        XCTAssertEqual(harness.client.calls.filter { $0 == .startTransmit }.count, 1)
        XCTAssertEqual(harness.audio.startCaptureCount, 1)
    }

    func testReleaseIsIdempotentAndSafeWhenNotTransmitting() async {
        let harness = SessionHarness()
        await harness.connect()

        await harness.session.endTransmitAndWait(reason: .released)
        await harness.session.endTransmitAndWait(reason: .released)

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.client.isTransmitting)
    }

    /// A press and release faster than the client can answer must still end
    /// unkeyed. Without the serialising task chain the stop could be applied
    /// before the start and the client would be left transmitting.
    func testAPressAndReleaseInTheSameTurnEndsUnkeyed() async {
        let harness = SessionHarness()
        await harness.connect()

        harness.session.beginTransmit()
        harness.session.endTransmit(reason: .released)
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
    }

    // MARK: Every release path

    /// The one that matters. Every case of ``TransmitStopReason`` is a path
    /// somebody wired up; each is exercised here from a live transmission and
    /// must leave the client unkeyed and the microphone shut.
    func testEveryReleasePathEndsTransmission() async {
        for reason in TransmitStopReason.allCases {
            let harness = SessionHarness()
            await harness.connect()
            await harness.keyDown()
            XCTAssertTrue(harness.client.isTransmitting, "setup failed for \(reason)")

            await harness.session.endTransmitAndWait(reason: reason)

            XCTAssertFalse(
                harness.client.isTransmitting, "\(reason) left the client transmitting")
            XCTAssertFalse(
                harness.session.isTransmitting, "\(reason) left the view model transmitting")
            XCTAssertFalse(harness.session.isKeyDown, "\(reason) left the button keyed")
            XCTAssertFalse(harness.audio.isCapturing, "\(reason) left the microphone open")
            XCTAssertEqual(harness.session.lastStopReason, reason)
        }
    }

    /// The microphone is shut synchronously, before anything is awaited. An
    /// interruption must not have to queue behind a key-up that is still in
    /// flight to an actor.
    func testTheMicrophoneIsShutBeforeAnythingIsAwaited() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()
        XCTAssertTrue(harness.audio.isCapturing)

        harness.session.endTransmit(reason: .audioInterrupted)

        XCTAssertFalse(
            harness.audio.isCapturing,
            "stopCapture must have run before endTransmit returned")
    }

    // MARK: The individual entry points

    func testTheViewDisappearingEndsTransmission() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        harness.session.viewDisappeared()
        await harness.session.settle()

        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertEqual(harness.session.lastStopReason, .viewDisappeared)
    }

    func testLeavingTheForegroundEndsTransmission() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        harness.session.setForeground(false)
        await harness.session.settle()

        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.session.lastStopReason, .appBackgrounded)
    }

    /// Coming back to the foreground must never re-key. A microphone that
    /// reopens without a fresh, deliberate press is the surprise this app
    /// exists to avoid.
    func testReturningToTheForegroundDoesNotResumeTransmission() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()
        harness.session.setForeground(false)
        await harness.session.settle()

        harness.session.setForeground(true)
        await harness.session.settle()

        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
    }

    /// SF-3.
    func testAnAudioInterruptionDropsTransmitAndSaysWhy() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.interruptionBegan)

        await waitUntil("the interruption drops transmit") {
            !harness.client.isTransmitting
        }
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.session.lastStopReason, .audioInterrupted)
        XCTAssertEqual(harness.session.safetyNotice?.kind, .audioInterruption)
    }

    /// SF-3: transmission stops on a route change, without exception.
    func testARouteChangeDropsTransmit() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.routeChanged)

        await waitUntil("the route change drops transmit") {
            !harness.client.isTransmitting
        }
        XCTAssertEqual(harness.session.lastStopReason, .routeChanged)
    }

    /// SF-3's other half, and the one an operator actually feels: they never
    /// let go, so the app keys back down rather than telling them to press a
    /// button they are already pressing.
    func testARouteChangeUnderAHeldButtonResumesTransmit() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.routeChanged)

        // **The stop is waited for first, and that is not belt and braces.**
        // Waiting straight for `isTransmitting` waits for a condition that is
        // still true from the key-down above, so it returns before the session
        // has even seen the route change: the assertions then pass without the
        // recovery having happened. Found while writing APP-3's SF-4 tests,
        // which had the same shape and the same vacuous pass.
        await waitUntil("the route change drops transmit") {
            !harness.client.isTransmitting
        }
        await waitUntil("transmit comes back on its own") {
            harness.client.isTransmitting
        }
        XCTAssertTrue(harness.audio.isCapturing)
        XCTAssertNil(
            harness.session.safetyNotice,
            "a repaired route change is not something to explain to anybody")
    }

    /// The same signal with nobody holding the button is a non-event: plugging
    /// a headset in while listening is not a safety stop, and there is nothing
    /// to key back down.
    func testARouteChangeWithNoHoldNeitherResumesNorComplains() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()
        harness.session.endTransmit(reason: .released)
        await harness.session.settle()

        harness.audio.emit(.routeChanged)
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertNil(harness.session.safetyNotice)
    }

    /// A route that will not settle must not become an unbounded series of
    /// key-downs. After the allowance is spent the app gives up and says so.
    func testAFlappingRouteStopsResumingAndSaysSo() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        for _ in 0..<5 {
            harness.audio.emit(.routeChanged)
            await waitUntil("transmit stops") { !harness.client.isTransmitting }
            // Let any resume land before provoking the next change.
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertEqual(harness.session.safetyNotice?.kind, .routeChange)
    }

    /// SF-1 is not negotiable: the watchdog ends the hold, so a route change
    /// afterwards has nothing to key back down. Otherwise a held button plus a
    /// flapping route would transmit for ever.
    func testTheWatchdogEndsTheHoldSoNothingResumes() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.session.endTransmit(reason: .watchdogExpired)
        await harness.session.settle()

        harness.audio.emit(.routeChanged)
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(harness.client.isTransmitting)
    }

    /// An interruption is something else wanting the microphone — a phone call,
    /// typically. Never resumed, held button or not.
    func testAnInterruptionUnderAHeldButtonDoesNotResume() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.interruptionBegan)
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertEqual(harness.session.safetyNotice?.kind, .audioInterruption)
    }

    /// SF-3, the other edge. `shouldResume` is a hint about playback; nothing
    /// keys a transmitter on its own.
    func testAnInterruptionEndingDoesNotResumeTransmission() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.interruptionBegan)
        await waitUntil("transmit dropped") { !harness.client.isTransmitting }
        harness.audio.emit(.interruptionEnded(shouldResume: true))
        await waitUntil("the resume signal is processed") { harness.audio.stopCaptureCount >= 2 }

        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
    }

    /// SF-1's word also reaches the accessory controller: the watchdog fires
    /// precisely when no release has arrived, so it is the one event that can
    /// withdraw an accessory-keyed claim whose release is never coming — see
    /// `BLEPTTController.radioUnkeyedExternally()`.
    func testTheWatchdogExpiryTellsTheAccessoryHook() async {
        let harness = SessionHarness()
        var told = false
        harness.session.onWatchdogUnkey = { told = true }
        await harness.connect()
        await harness.keyDown()

        harness.eventContinuation.yield(.transmitWatchdogExpired(.seconds(180)))

        await waitUntil("the hook is called") { told }
        XCTAssertEqual(harness.session.lastStopReason, .watchdogExpired)
    }

    /// SF-1. The client stops itself; the app still has an open microphone and
    /// a button that thinks it is held, and the operator needs to be told.
    func testTheWatchdogExpirySurfacesAndEndsTransmission() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        harness.eventContinuation.yield(.transmitWatchdogExpired(.seconds(180)))

        await waitUntil("the watchdog notice appears") {
            harness.session.safetyNotice?.kind == .transmitWatchdog
        }
        await harness.session.settle()

        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertFalse(harness.session.isKeyDown)
        XCTAssertEqual(harness.session.lastStopReason, .watchdogExpired)
        XCTAssertTrue(
            harness.session.safetyNotice?.message.contains("3 minutes") == true,
            "the notice should say how long, got: \(harness.session.safetyNotice?.message ?? "nil")")
    }

    /// The far end hanging up mid-transmission must unkey too.
    func testALinkDroppingWhileTransmittingEndsTransmission() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        harness.eventContinuation.yield(.disconnected(reason: "The node ended the call."))

        await waitUntil("the session tears down") {
            harness.session.connection == .disconnected
        }
        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
    }

    // MARK: Disconnecting

    /// The ordering assertion: unkey, *then* hang up. A disconnect that raced
    /// the unkey could leave the far end's repeater keyed until its own
    /// timeout.
    func testDisconnectingWhileTransmittingStopsTransmitFirst() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        await harness.session.disconnect()

        let calls = harness.client.calls.filter { $0 != .send(frameCount: 160) }
        guard let stopIndex = calls.firstIndex(of: .stopTransmit),
            let disconnectIndex = calls.firstIndex(of: .disconnect)
        else {
            return XCTFail("expected both a stopTransmit and a disconnect, got \(calls)")
        }
        XCTAssertLessThan(stopIndex, disconnectIndex, "unkey must precede hang-up")
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.session.connection, .disconnected)
    }

    // MARK: Audio wiring

    func testCapturedAudioReachesTheClientWhileTransmitting() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        let frame = Array(repeating: Int16(42), count: 160)
        harness.audio.produceFrame(frame)

        XCTAssertEqual(harness.client.sentFrames, [frame])
    }

    func testNoAudioIsCapturedOnceTransmissionHasEnded() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()
        await harness.session.endTransmitAndWait(reason: .released)

        harness.audio.produceFrame(Array(repeating: Int16(42), count: 160))

        XCTAssertTrue(
            harness.client.sentFrames.isEmpty,
            "the tap must be gone, so there is nothing left to produce a frame")
    }

    /// The gain is applied on the way to the wire, not just on the meter.
    func testTheTransmitGainIsAppliedToWhatIsSent() async {
        let harness = SessionHarness()
        harness.session.transmitGain = TransmitGain(decibels: 6)
        await harness.connect()
        await harness.keyDown()

        harness.audio.produceFrame(Array(repeating: Int16(1000), count: 160))

        let sent = try? XCTUnwrap(harness.client.sentFrames.first)
        XCTAssertEqual(sent?.first ?? 0, 1995, accuracy: 5, "+6 dB doubles it")
    }

    /// **The gain applies to the transmission in progress.** It was snapshotted
    /// at key-down at first, on the reasoning that a mid-over change is audible
    /// as a swell. That reasoning lost to a simpler one once the slider moved
    /// next to the meter: an operator watching the bar while they speak and
    /// dragging the control directly beneath it will conclude the control is
    /// broken, and a swell they caused deliberately is not a defect.
    func testChangingTheGainAppliesToTheOverInProgress() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        harness.audio.produceFrame(Array(repeating: Int16(1000), count: 160))
        harness.session.transmitGain = TransmitGain(decibels: 6)
        harness.audio.produceFrame(Array(repeating: Int16(1000), count: 160))

        XCTAssertEqual(harness.client.sentFrames.first?.first, 1000, "before the change")
        XCTAssertEqual(
            Double(harness.client.sentFrames.last?.first ?? 0), 1995, accuracy: 5,
            "after it, without waiting for the next over")
    }

    /// The meter reads what left, so an operator setting a gain against it is
    /// looking at the thing the gain changes.
    func testTheTransmitMeterSeesWhatWasSent() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        XCTAssertEqual(harness.session.transmitMeter.decibels, AudioLevelMeter.floorDB)

        harness.audio.produceFrame(Array(repeating: Int16.max / 2, count: 160))

        XCTAssertEqual(harness.session.transmitMeter.decibels, -6, accuracy: 0.1)
    }

    /// Persisted on change: an operator who finds their level and loses it on
    /// relaunch has not been helped.
    func testChangingTheGainStoresIt() {
        let harness = SessionHarness()

        harness.session.transmitGain = TransmitGain(decibels: 9)

        XCTAssertEqual(harness.settingsStore.savedTransmitGain?.decibels, 9)
    }

    func testTheStoredGainIsLoadedAtInit() {
        let harness = SessionHarness(gain: TransmitGain(decibels: 15))

        XCTAssertEqual(harness.session.transmitGain.decibels, 15)
    }

    // MARK: Failing to key

    func testAMicrophoneFailureFailsClosedAndIsReported() async {
        let harness = SessionHarness()
        await harness.connect()
        harness.audio.startCaptureError = SessionHarness.AudioFailed()

        await harness.keyDown()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.session.isKeyDown, "a failed key-up must release the button")
        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.session.lastStopReason, .transmitFailed)
        XCTAssertEqual(harness.session.alert?.title, "Could not transmit")
    }

    func testAClientRefusingToKeyFailsClosedAndIsReported() async {
        let harness = SessionHarness()
        await harness.connect()
        harness.client.startTransmitError = SessionHarness.ConnectFailed()

        await harness.keyDown()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.client.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing, "the microphone must not be left open")
        XCTAssertTrue(
            harness.client.calls.contains(.stopTransmit),
            "the client must be told to unkey even though keying failed")
        XCTAssertEqual(harness.session.alert?.title, "Could not transmit")
    }

    // MARK: Notices

    func testASafetyNoticeIsClearedByAFreshPress() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()
        // An interruption rather than a route change: a route change under a
        // held button now repairs itself and leaves no notice to clear.
        harness.audio.emit(.interruptionBegan)
        await waitUntil("the notice appears") { harness.session.safetyNotice != nil }

        await harness.keyDown()

        XCTAssertNil(harness.session.safetyNotice)
    }

    func testASafetyNoticeCanBeDismissed() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()
        harness.audio.emit(.interruptionBegan)
        await waitUntil("the notice appears") { harness.session.safetyNotice != nil }

        harness.session.dismissSafetyNotice()

        XCTAssertNil(harness.session.safetyNotice)
    }

    func testAnOrdinaryReleaseRaisesNoNotice() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        await harness.session.endTransmitAndWait(reason: .released)

        XCTAssertNil(harness.session.safetyNotice)
        XCTAssertFalse(TransmitStopReason.released.isUnexpected)
    }
}
