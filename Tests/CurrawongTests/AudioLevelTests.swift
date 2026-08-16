// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The transmit and receive meters, and the gain in front of one of them.
final class AudioLevelTests: XCTestCase {

    // MARK: - A clock that does not tick unless told

    /// Ballistics are a function of elapsed time, so testing them against a
    /// real clock would mean sleeping — slow, and flaky on a loaded machine.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000_000)

        var now: @Sendable () -> Date {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return current
            }
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            current = current.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    private func frame(peak: Int16, count: Int = 160) -> [Int16] {
        var samples = [Int16](repeating: 0, count: count)
        samples[count / 2] = peak
        return samples
    }

    // MARK: - Reading a level

    func testSilenceReadsAtTheFloor() {
        let meter = AudioLevelMeter()
        meter.note([Int16](repeating: 0, count: 160))

        XCTAssertEqual(meter.decibels, AudioLevelMeter.floorDB)
        XCTAssertEqual(meter.fraction, 0)
    }

    func testFullScaleReadsAtZero() {
        let meter = AudioLevelMeter()
        meter.note(frame(peak: Int16.max))

        XCTAssertEqual(meter.decibels, 0, accuracy: 0.01)
        XCTAssertEqual(meter.fraction, 1, accuracy: 0.001)
    }

    /// Half amplitude is −6 dB. The arithmetic being right is the difference
    /// between a meter and a decoration.
    func testHalfScaleReadsAtMinusSix() {
        let meter = AudioLevelMeter()
        meter.note(frame(peak: Int16.max / 2))

        XCTAssertEqual(meter.decibels, -6, accuracy: 0.1)
    }

    /// `Int16.min` has no positive counterpart, so `abs` on it traps. A single
    /// full-negative sample is an ordinary thing for audio to contain.
    func testTheMostNegativeSampleDoesNotTrap() {
        let meter = AudioLevelMeter()
        meter.note(frame(peak: Int16.min))

        XCTAssertEqual(meter.decibels, 0, accuracy: 0.01)
    }

    // MARK: - Ballistics

    /// Instant attack: a peak is shown as soon as it happens, not averaged into
    /// invisibility.
    func testALouderPeakIsTakenImmediately() {
        let clock = TestClock()
        let meter = AudioLevelMeter(now: clock.now)

        meter.note(frame(peak: Int16.max / 8))
        let quiet = meter.decibels
        meter.note(frame(peak: Int16.max))

        XCTAssertGreaterThan(meter.decibels, quiet)
        XCTAssertEqual(meter.decibels, 0, accuracy: 0.01)
    }

    /// Slow decay, at the documented rate, computed on read rather than driven
    /// by a timer — so a meter polled at any rate reads the same.
    func testTheNeedleFallsAtTheDocumentedRate() {
        let clock = TestClock()
        let meter = AudioLevelMeter(now: clock.now)

        meter.note(frame(peak: Int16.max))
        XCTAssertEqual(meter.decibels, 0, accuracy: 0.01)

        clock.advance(0.5)
        XCTAssertEqual(
            meter.decibels, -AudioLevelMeter.decayPerSecond / 2, accuracy: 0.01,
            "24 dB/s for half a second is 12 dB")

        clock.advance(10)
        XCTAssertEqual(meter.decibels, AudioLevelMeter.floorDB, "and it stops at the floor")
    }

    /// A quieter frame must not yank the needle down — it waits for the decay
    /// to reach it. Otherwise the meter reads the gaps between syllables.
    func testAQuieterFrameDoesNotPullTheNeedleDown() {
        let clock = TestClock()
        let meter = AudioLevelMeter(now: clock.now)

        meter.note(frame(peak: Int16.max))
        clock.advance(0.1)
        meter.note(frame(peak: 1))

        XCTAssertEqual(meter.decibels, -2.4, accuracy: 0.01, "decayed, not reset")
    }

    // MARK: - Clipping

    func testClippingIsHeldLongEnoughToSee() {
        let clock = TestClock()
        let meter = AudioLevelMeter(now: clock.now)

        meter.note(frame(peak: Int16.max))
        XCTAssertTrue(meter.isClipping)

        clock.advance(0.5)
        XCTAssertTrue(meter.isClipping, "one sample in eight thousand needs a hold to be seen")

        clock.advance(1.0)
        XCTAssertFalse(meter.isClipping)
    }

    func testAComfortablePeakIsNotClipping() {
        let meter = AudioLevelMeter()
        meter.note(frame(peak: Int16.max / 4))

        XCTAssertFalse(meter.isClipping)
    }

    func testResetDropsTheNeedle() {
        let meter = AudioLevelMeter()
        meter.note(frame(peak: Int16.max))

        meter.reset()

        XCTAssertEqual(meter.decibels, AudioLevelMeter.floorDB)
        XCTAssertFalse(meter.isClipping)
    }

    // MARK: - Zones

    /// The colour is the calibration, so the boundaries are worth pinning.
    func testTheZonesMatchTheDocumentedBoundaries() {
        XCTAssertEqual(LevelMeterView.Zone(decibels: -60).spokenName, "silent")
        XCTAssertEqual(LevelMeterView.Zone(decibels: -40).spokenName, "too quiet")
        XCTAssertEqual(LevelMeterView.Zone(decibels: -20).spokenName, "good level")
        XCTAssertEqual(LevelMeterView.Zone(decibels: -12).spokenName, "good level")
        XCTAssertEqual(LevelMeterView.Zone(decibels: -3).spokenName, "hot")
        XCTAssertEqual(LevelMeterView.Zone(decibels: 0).spokenName, "clipping")
    }

    // MARK: - Gain

    func testUnityGainReturnsTheFrameUntouched() {
        let original = frame(peak: 1000)
        XCTAssertEqual(TransmitGain.unity.apply(to: original), original)
    }

    func testSixDecibelsDoublesTheAmplitude() {
        let amplified = TransmitGain(decibels: 6).apply(to: frame(peak: 1000))
        XCTAssertEqual(amplified[80], 1995, accuracy: 5)
    }

    /// **The one that matters.** Multiplying without clamping wraps a loud
    /// syllable to the opposite rail, which is a click rather than distortion —
    /// far worse on the air than the clipping it came from.
    func testALoudSignalIsClampedRatherThanWrapped() {
        let amplified = TransmitGain(decibels: 30).apply(to: frame(peak: 20000))

        XCTAssertEqual(amplified[80], Int16.max, "flat-topped, not wrapped to negative")
        XCTAssertTrue(amplified.allSatisfy { $0 >= 0 }, "nothing changed sign")
    }

    func testTheMostNegativeSampleIsClampedToo() {
        let amplified = TransmitGain(decibels: 30).apply(to: frame(peak: Int16.min))
        XCTAssertEqual(amplified[80], Int16.min)
    }

    func testTheGainIsClampedToItsRange() {
        XCTAssertEqual(TransmitGain(decibels: -10).decibels, TransmitGain.range.lowerBound)
        XCTAssertEqual(TransmitGain(decibels: 999).decibels, TransmitGain.range.upperBound)
    }

    /// Gain then meter, so the meter reports what actually leaves. An operator
    /// setting a gain against a meter that ignored it would be flying blind.
    func testTheMeterSeesTheGain() {
        let quiet = frame(peak: Int16.max / 16)

        let withoutGain = AudioLevelMeter()
        withoutGain.note(TransmitGain.unity.apply(to: quiet))

        let withGain = AudioLevelMeter()
        withGain.note(TransmitGain(decibels: 12).apply(to: quiet))

        XCTAssertEqual(withGain.decibels - withoutGain.decibels, 12, accuracy: 0.1)
    }
}
