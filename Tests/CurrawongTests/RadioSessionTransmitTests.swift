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

    /// SF-3.
    func testARouteChangeDropsTransmitAndSaysWhy() async {
        let harness = SessionHarness()
        harness.session.start()
        await harness.connect()
        await harness.keyDown()

        harness.audio.emit(.routeChanged)

        await waitUntil("the route change drops transmit") {
            !harness.client.isTransmitting
        }
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.session.lastStopReason, .routeChanged)
        XCTAssertEqual(harness.session.safetyNotice?.kind, .routeChange)
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
        harness.audio.emit(.routeChanged)
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
