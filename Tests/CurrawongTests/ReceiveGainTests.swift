// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// Software gain on the receive path — the counterpart of `TransmitGain`, and
/// what makes up the difference when a phone at full volume is still not loud
/// enough for the room.
final class ReceiveGainTests: XCTestCase {
    private func frame(peak: Int16) -> [Int16] { [0, peak, 0, -peak] }

    func testUnityPassesSamplesThrough() {
        let original = frame(peak: 1000)
        XCTAssertEqual(ReceiveGain.unity.apply(to: original), original)
        XCTAssertEqual(ReceiveGain.unity.decibels, 0)
    }

    /// +6 dB is a doubling of amplitude. Worth pinning as arithmetic rather than
    /// trusting the formula, because getting the 20-versus-10 wrong is silent.
    func testSixDecibelsDoublesTheAmplitude() {
        let amplified = ReceiveGain(decibels: 6).apply(to: frame(peak: 1000))

        XCTAssertEqual(amplified[1], 1995, accuracy: 2)
        XCTAssertEqual(amplified[3], -1995, accuracy: 2)
    }

    /// The clamp is the whole reason this is not a bare multiply: a wrapped
    /// sample is a click, which is worse on a speaker than the flat top it
    /// replaces.
    func testALoudFrameIsClampedRatherThanWrapped() {
        let amplified = ReceiveGain(decibels: 20).apply(to: frame(peak: 20000))

        XCTAssertEqual(amplified[1], Int16.max)
        XCTAssertEqual(amplified[3], Int16.min)
    }

    /// `Int16.min` has no positive counterpart, so it is the sample that trips a
    /// naive negation.
    func testTheMostNegativeSampleSurvives() {
        let amplified = ReceiveGain(decibels: 20).apply(to: [Int16.min])

        XCTAssertEqual(amplified[0], Int16.min)
    }

    func testTheRangeIsBoostOnly() {
        XCTAssertEqual(ReceiveGain(decibels: -10).decibels, ReceiveGain.range.lowerBound)
        XCTAssertEqual(ReceiveGain(decibels: 999).decibels, ReceiveGain.range.upperBound)
        XCTAssertEqual(
            ReceiveGain.range.lowerBound, 0,
            "turning the audio down is what the device's own volume control is for")
    }
}

/// The session's end of it: loaded once, persisted on change, and applied to the
/// audio on its way to the speaker.
@MainActor
final class RadioSessionReceiveGainTests: XCTestCase {
    func testAStoredGainIsLoaded() {
        let harness = SessionHarness(receiveGain: ReceiveGain(decibels: 9))

        XCTAssertEqual(harness.session.receiveGain, ReceiveGain(decibels: 9))
    }

    func testNoStoredGainMeansUnity() {
        XCTAssertEqual(SessionHarness().session.receiveGain, .unity)
    }

    func testChangingTheGainPersistsIt() {
        let harness = SessionHarness()

        harness.session.receiveGain = ReceiveGain(decibels: 12)

        XCTAssertEqual(harness.settingsStore.savedReceiveGain, ReceiveGain(decibels: 12))
    }

    /// The wiring that makes the slider do anything: what reaches the speaker is
    /// the amplified frame, not the one the link handed over.
    func testTheGainIsAppliedToWhatIsPlayed() async throws {
        let harness = SessionHarness(receiveGain: ReceiveGain(decibels: 6))
        await harness.connect()

        harness.audioContinuation.yield(Array(repeating: Int16(1000), count: 160))

        await waitUntil("received audio reaches the speaker") {
            !harness.audio.playedFrames.isEmpty
        }
        let played = try XCTUnwrap(harness.audio.playedFrames.first)
        XCTAssertEqual(played.count, 160)
        XCTAssertEqual(played[0], 1995, accuracy: 2)
    }

    /// Read per frame rather than snapshotted when the pump starts, so dragging
    /// the slider mid-transmission is audible on the next 20 ms.
    func testAGainChangeMidStreamAffectsLaterFrames() async throws {
        let harness = SessionHarness()
        await harness.connect()

        harness.audioContinuation.yield(Array(repeating: Int16(1000), count: 160))
        await waitUntil("the first frame is played") { !harness.audio.playedFrames.isEmpty }

        harness.session.receiveGain = ReceiveGain(decibels: 6)
        harness.audioContinuation.yield(Array(repeating: Int16(1000), count: 160))
        await waitUntil("the second frame is played") { harness.audio.playedFrames.count >= 2 }

        XCTAssertEqual(harness.audio.playedFrames[0][0], 1000, "unity when it arrived")
        XCTAssertEqual(harness.audio.playedFrames[1][0], 1995, accuracy: 2)
    }
}
