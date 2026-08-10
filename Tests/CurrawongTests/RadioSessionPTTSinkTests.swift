// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// ``RadioSession`` as a ``PTTSink``: the wire between the physical inputs
/// (PT-2, PT-3, PT-4) and the microphone.
///
/// The point of these tests is that **every input's release path ends
/// transmission**, including the ones nobody presses — an accessory whose link
/// drops has no release edge, and SF-2 is the requirement that says the app
/// unkeys anyway.
@MainActor
final class RadioSessionPTTSinkTests: XCTestCase {

    private func connectedHarness() async -> SessionHarness {
        let harness = SessionHarness()
        await harness.connect()
        XCTAssertEqual(harness.session.connection, .connected)
        return harness
    }

    // MARK: - Press and release

    func testAnAccessoryPressKeysTheRadioAndRecordsItsSource() async {
        let harness = await connectedHarness()

        harness.session.pttPressed(from: .accessory)
        await harness.session.settle()

        XCTAssertTrue(harness.session.isTransmitting)
        XCTAssertEqual(harness.session.activeSource, .accessory)
        XCTAssertTrue(harness.audio.isCapturing)
    }

    func testAnAccessoryReleaseUnkeys() async {
        let harness = await connectedHarness()
        harness.session.pttPressed(from: .accessory)
        await harness.session.settle()

        harness.session.pttReleased(from: .accessory, reason: .accessoryReleased)
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.session.lastStopReason, .accessoryReleased)
        XCTAssertNil(harness.session.activeSource)
    }

    /// An ordinary release is the operator's own doing, so it must not raise a
    /// safety banner — those are for things that happened *to* them.
    func testAnAccessoryReleaseRaisesNoSafetyNotice() async {
        let harness = await connectedHarness()
        harness.session.pttPressed(from: .accessory)
        await harness.session.settle()

        harness.session.pttReleased(from: .accessory, reason: .accessoryReleased)
        await harness.session.settle()

        XCTAssertNil(harness.session.safetyNotice)
    }

    /// A press edge from an accessory while there is no connection must not
    /// stack up modal alerts — a fob in a pocket can send a great many of them,
    /// and the operator is not looking at the screen.
    func testAnAccessoryPressWhileDisconnectedIsRefusedSilently() async {
        let harness = SessionHarness()

        harness.session.pttPressed(from: .accessory)
        harness.session.pttPressed(from: .accessory)
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertNil(harness.session.alert)
    }

    /// The on-screen button is the one case where an alert is right: the
    /// operator is looking at the button they just pressed and deserves to be
    /// told why nothing happened.
    func testAnOnScreenPressWhileDisconnectedDoesAlert() async {
        let harness = SessionHarness()

        harness.session.beginTransmit()
        await harness.session.settle()

        XCTAssertEqual(harness.session.alert?.title, "Not connected")
    }

    /// The release is honoured whoever it comes from. See the note on the
    /// `PTTSink` conformance: the cost of an unnecessary stop is nothing, the
    /// cost of a swallowed one is an open microphone.
    func testAReleaseFromADifferentSourceStillUnkeys() async {
        let harness = await connectedHarness()
        harness.session.beginTransmit(from: .onScreen)
        await harness.session.settle()
        XCTAssertTrue(harness.session.isTransmitting)

        harness.session.pttReleased(from: .accessory, reason: .accessoryReleased)
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
    }

    // MARK: - SF-2

    func testAccessoryLinkLossStopsTransmissionAndSaysWhy() async {
        let harness = await connectedHarness()
        harness.session.pttPressed(from: .accessory)
        await harness.session.settle()
        XCTAssertTrue(harness.session.isTransmitting)

        harness.session.accessoryLinkLost()
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.session.lastStopReason, .accessoryLinkLost)
        XCTAssertEqual(harness.session.safetyNotice?.kind, .accessoryLinkLost)
    }

    /// SF-2 does not ask which input was holding the key. An accessory that
    /// drops off the link while the on-screen button is held still unkeys —
    /// the app has lost its ability to see release edges and guessing is not
    /// worth the risk.
    func testAccessoryLinkLossStopsAnOnScreenTransmissionToo() async {
        let harness = await connectedHarness()
        harness.session.beginTransmit(from: .onScreen)
        await harness.session.settle()

        harness.session.accessoryLinkLost()
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertEqual(harness.session.lastStopReason, .accessoryLinkLost)
    }

    /// `BLEPTTController` calls this on *every* disconnection, including ones
    /// where nothing was transmitting, so it must be silent in that case rather
    /// than alarming the operator about a transmission that never happened.
    func testAccessoryLinkLossWhileIdleIsSilent() async {
        let harness = await connectedHarness()

        harness.session.accessoryLinkLost()
        await harness.session.settle()

        XCTAssertNil(harness.session.lastStopReason)
        XCTAssertNil(harness.session.safetyNotice)
        XCTAssertFalse(harness.session.isTransmitting)
    }

    func testAccessoryLinkLossWithNoConnectionAtAllIsHarmless() async {
        let harness = SessionHarness()

        harness.session.accessoryLinkLost()
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertNil(harness.session.alert)
    }

    // MARK: - PT-4 toggle

    func testToggleKeysThenUnkeys() async {
        let harness = await connectedHarness()

        harness.session.pttToggled(from: .remoteCommand)
        await harness.session.settle()
        XCTAssertTrue(harness.session.isTransmitting)
        XCTAssertEqual(harness.session.activeSource, .remoteCommand)

        harness.session.pttToggled(from: .remoteCommand)
        await harness.session.settle()
        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertEqual(harness.session.lastStopReason, .remoteCommandToggled)
        XCTAssertNil(harness.session.activeSource)
    }

    /// The ordering trap. Two toggles with no `settle()` between them: the
    /// second arrives while the first key-up is still in flight to the client,
    /// so `isTransmitting` is still false. Read naively that looks like "not
    /// transmitting, so key up", and a double-press would latch instead of
    /// cancelling — with the operator's finger already off the button.
    func testASecondToggleInsideTheFirstsRoundTripUnkeys() async {
        let harness = await connectedHarness()

        harness.session.pttToggled(from: .remoteCommand)
        harness.session.pttToggled(from: .remoteCommand)
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.session.lastStopReason, .remoteCommandToggled)
    }

    /// PT-4's honesty requirement, as a value the banner can render: a latched
    /// source says so, a momentary one says the opposite.
    func testTheActiveSourceSaysWhetherLettingGoUnkeys() async {
        let harness = await connectedHarness()

        harness.session.pttToggled(from: .remoteCommand)
        await harness.session.settle()
        XCTAssertEqual(harness.session.activeSource?.isMomentary, false)

        harness.session.pttToggled(from: .remoteCommand)
        await harness.session.settle()

        harness.session.pttPressed(from: .accessory)
        await harness.session.settle()
        XCTAssertEqual(harness.session.activeSource?.isMomentary, true)
    }

    /// A latched transmission must not survive the operator switching the input
    /// that latched it off — which is what `RemoteCommandPTTController` calls
    /// when `setEnabled(false)` finds a transmission in progress.
    func testALatchedTransmissionIsEndedByAReleaseFromTheSameSource() async {
        let harness = await connectedHarness()
        harness.session.pttToggled(from: .remoteCommand)
        await harness.session.settle()

        harness.session.pttReleased(from: .remoteCommand, reason: .remoteCommandToggled)
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
    }

    // MARK: - Interaction with the other release paths

    /// The watchdog is the library's, and it does not know which input keyed.
    /// SF-1 must therefore work identically for a latched remote-command
    /// transmission, which is the case where the operator's hands are nowhere
    /// near the device.
    func testTheWatchdogEndsALatchedTransmission() async {
        let harness = await connectedHarness()
        harness.session.pttToggled(from: .remoteCommand)
        await harness.session.settle()

        harness.eventContinuation.yield(.transmitWatchdogExpired(.seconds(10)))
        await waitUntil("the watchdog stopped transmission") {
            harness.session.lastStopReason == .watchdogExpired
        }
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertEqual(harness.session.safetyNotice?.kind, .transmitWatchdog)
        XCTAssertNil(harness.session.activeSource)
    }

    /// SF-3 likewise: an interruption unkeys an accessory-held transmission,
    /// even though the accessory still thinks its button is down.
    func testAnInterruptionEndsAnAccessoryTransmission() async {
        let harness = await connectedHarness()
        // SF-3 signals only arrive once the session is observing them.
        harness.session.start()
        harness.session.pttPressed(from: .accessory)
        await harness.session.settle()

        harness.audio.emit(.interruptionBegan)
        await waitUntil("the interruption stopped transmission") {
            harness.session.lastStopReason == .audioInterrupted
        }
        await harness.session.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertNil(harness.session.activeSource)
    }

    /// Every reason must be classified, or a new input's stop path silently
    /// stops explaining itself to the operator.
    func testEveryStopReasonIsClassified() {
        for reason in TransmitStopReason.allCases {
            XCTAssertFalse(reason.rawValue.isEmpty, "\(reason) has no name")
        }
        XCTAssertTrue(TransmitStopReason.accessoryLinkLost.isUnexpected)
        XCTAssertFalse(TransmitStopReason.accessoryReleased.isUnexpected)
        XCTAssertFalse(TransmitStopReason.remoteCommandToggled.isUnexpected)
    }
}
