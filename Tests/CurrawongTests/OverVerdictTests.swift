// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// How a whole over is judged from its frame peaks.
///
/// The frames are synthetic, at known levels, so each test pins one rule. The
/// thresholds are the transmit meter's own zones and have not been tuned
/// against recordings.
final class OverVerdictTests: XCTestCase {
    /// One 20 ms frame whose peak is `amplitude`.
    private func frame(_ amplitude: Int16) -> [Int16] {
        Array(repeating: amplitude, count: 160)
    }

    private func accumulator(_ frames: [(count: Int, amplitude: Int16)]) -> OverLevelAccumulator {
        let accumulator = OverLevelAccumulator()
        for (count, amplitude) in frames {
            for _ in 0..<count { accumulator.note(frame(amplitude)) }
        }
        return accumulator
    }

    // MARK: The zones

    func testSpeechAtMinusTwelveIsGood() throws {
        let verdict = try XCTUnwrap(accumulator([(50, Int16.max / 4)]).verdict())

        XCTAssertEqual(verdict.zone, .good)
        XCTAssertEqual(verdict.decibels, -12, accuracy: 1)
    }

    func testSpeechAtMinusFortyIsTooQuiet() throws {
        let verdict = try XCTUnwrap(accumulator([(50, 300)]).verdict())

        XCTAssertEqual(verdict.zone, .low)
    }

    func testSpeechAtMinusFourIsHot() throws {
        let verdict = try XCTUnwrap(accumulator([(50, 20_000)]).verdict())

        XCTAssertEqual(verdict.zone, .hot)
    }

    // MARK: Clipping

    func testAFewClippedFramesMakeTheOverClipping() throws {
        let verdict = try XCTUnwrap(
            accumulator([(50, Int16.max / 4), (3, Int16.max)]).verdict())

        XCTAssertEqual(verdict.zone, .clipping)
    }

    /// One plosive in an otherwise good over does not condemn it.
    func testOneClippedFrameDoesNot() throws {
        let verdict = try XCTUnwrap(
            accumulator([(50, Int16.max / 4), (1, Int16.max)]).verdict())

        XCTAssertEqual(verdict.zone, .good)
    }

    // MARK: Speech is mostly gaps

    /// Four fifths room noise and one fifth speech is still judged on the
    /// speech, which is why the verdict follows the loud tenth and not the
    /// average.
    func testTheVerdictFollowsTheLoudPartOfTheOver() throws {
        let verdict = try XCTUnwrap(
            accumulator([(80, 100), (20, Int16.max / 4)]).verdict())

        XCTAssertEqual(verdict.zone, .good)
    }

    // MARK: Nothing to judge

    func testAVeryShortOverGetsNoVerdict() {
        XCTAssertNil(accumulator([(10, Int16.max / 4)]).verdict())
    }

    /// A second of nothing at all is worth saying: the microphone is not
    /// delivering sound.
    func testALongSilentOverIsSilent() throws {
        let verdict = try XCTUnwrap(accumulator([(60, 0)]).verdict())

        XCTAssertEqual(verdict.zone, .silent)
    }

    func testAShortSilentOverGetsNoVerdict() {
        XCTAssertNil(accumulator([(20, 0)]).verdict())
    }

    func testResetEmptiesIt() {
        let accumulator = accumulator([(50, Int16.max / 4)])

        accumulator.reset()

        XCTAssertNil(accumulator.verdict())
    }

    // MARK: What to do about it

    func testAGoodOverNeedsNoAdvice() {
        let verdict = OverVerdict(zone: .good, decibels: -12)

        XCTAssertNil(verdict.advice(gain: TransmitGain(decibels: 6)))
    }

    func testAQuietOverSaysToRaiseTheGain() {
        let verdict = OverVerdict(zone: .low, decibels: -40)

        XCTAssertEqual(
            verdict.advice(gain: TransmitGain(decibels: 6)),
            "Raise the microphone gain, or speak closer.")
    }

    /// A slider at its end cannot be moved further, so the advice does not
    /// send the operator to it.
    func testAQuietOverAtFullGainSaysToSpeakCloser() {
        let verdict = OverVerdict(zone: .low, decibels: -40)
        let full = TransmitGain(decibels: TransmitGain.range.upperBound)

        XCTAssertEqual(verdict.advice(gain: full), "Speak closer to the microphone.")
    }

    func testAHotOverSaysToLowerTheGain() {
        let verdict = OverVerdict(zone: .hot, decibels: -3)

        XCTAssertEqual(
            verdict.advice(gain: TransmitGain(decibels: 6)), "Lower the microphone gain.")
    }

    func testAHotOverWithNoGainSaysToSpeakMoreSoftly() {
        let verdict = OverVerdict(zone: .clipping, decibels: 0)
        let none = TransmitGain(decibels: TransmitGain.range.lowerBound)

        XCTAssertEqual(
            verdict.advice(gain: none), "Speak more softly, or further from the microphone.")
    }
}

/// The verdict as the session publishes it: set when an over ends, gone when
/// the next begins.
@MainActor
final class RadioSessionOverVerdictTests: XCTestCase {
    private func speak(_ harness: SessionHarness, frames: Int = 50) {
        for _ in 0..<frames {
            harness.audio.produceFrame(Array(repeating: Int16.max / 4, count: 160))
        }
    }

    func testReleasingAfterAnOverPublishesItsVerdict() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()
        XCTAssertNil(harness.session.lastOverVerdict)

        speak(harness)
        harness.session.endTransmit(reason: .released)

        XCTAssertEqual(harness.session.lastOverVerdict?.zone, .good)
    }

    func testTheNextPressClearsIt() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()
        speak(harness)
        harness.session.endTransmit(reason: .released)
        await harness.session.settle()

        await harness.keyDown()

        XCTAssertNil(harness.session.lastOverVerdict, "a stale verdict must not sit over a live meter")
    }

    /// Each over is judged alone: the second is not weighed with the first.
    func testEachOverIsJudgedOnItsOwn() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()
        speak(harness)
        harness.session.endTransmit(reason: .released)
        await harness.session.settle()

        await harness.keyDown()
        for _ in 0..<50 {
            harness.audio.produceFrame(Array(repeating: 300, count: 160))
        }
        harness.session.endTransmit(reason: .released)

        XCTAssertEqual(harness.session.lastOverVerdict?.zone, .low)
    }

    func testATapTooShortToJudgeLeavesNoVerdict() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()

        speak(harness, frames: 5)
        harness.session.endTransmit(reason: .released)

        XCTAssertNil(harness.session.lastOverVerdict)
    }
}
