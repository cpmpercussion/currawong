// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A peak-reading level meter, in dBFS.
///
/// One of these sits on each audio path: what the microphone is sending, and
/// what the far end is sending back. They exist because "am I too quiet?" is
/// otherwise unanswerable without another operator's help — which on a repeater
/// means asking a stranger for a radio check every time you change a setting.
///
/// ## Written from the audio thread, read from the main one
///
/// ``note(_:)`` is called by the capture tap, fifty times a second, on a
/// real-time thread. It takes a short uncontended lock, scans 160 samples for a
/// peak, and returns — no allocation, no logging, nothing that can block. The
/// same policy `CapturedFrameRelay` follows, for the same reason: an `await` or
/// a malloc on that thread manufactures dropouts that then get blamed on the
/// network.
///
/// ## Ballistics
///
/// Instant attack, timed decay. A meter that fell as slowly as it rose would
/// miss a peak, and one that fell instantly would be an unreadable flicker at
/// fifty updates a second. ``decayPerSecond`` is 24 dB/s, which is in the range
/// broadcast peak-programme meters use and is slow enough to read on a phone
/// held at arm's length.
///
/// Decay is computed on *read* from a timestamp rather than driven by a timer,
/// so the reading is correct whether it is polled at 60 Hz or once a second,
/// and a meter nobody is looking at costs nothing.
final class AudioLevelMeter: @unchecked Sendable {
    /// Quieter than this reads as silence. Speech peaks well above it and room
    /// noise on a phone microphone sits below it, so it is also roughly the
    /// line between "nothing is arriving" and "something is".
    static let floorDB: Double = -54

    /// How fast the needle falls, in dB per second.
    static let decayPerSecond: Double = 24

    /// A sample this close to full scale is treated as clipped. Not 32767: a
    /// converter or a codec will round, and a signal riding the rail is already
    /// distorting before it reaches the exact maximum.
    static let clipThreshold: Int32 = 32000

    private let lock = NSLock()
    private var heldDB: Double = AudioLevelMeter.floorDB
    private var heldAt: Date = .distantPast
    private var clippedAt: Date = .distantPast

    /// A clock, injectable so the ballistics can be tested without sleeping.
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Records one frame's peak. **Called on the audio thread.**
    func note(_ frame: [Int16]) {
        var peak: Int32 = 0
        for sample in frame {
            // `magnitude` rather than `abs`: Int16.min has no positive
            // counterpart, and `abs` on it traps.
            let magnitude = Int32(sample.magnitude)
            if magnitude > peak { peak = magnitude }
        }

        let db = Self.decibels(forPeak: peak)
        let stamp = now()

        lock.lock()
        // Attack is instant, so a louder reading always wins; a quieter one has
        // to wait for the decay to bring the needle down to it.
        let decayed = Self.decayed(from: heldDB, since: heldAt, to: stamp)
        heldDB = max(decayed, db)
        heldAt = stamp
        if peak >= Self.clipThreshold { clippedAt = stamp }
        lock.unlock()
    }

    /// The current reading in dBFS, decayed to now. ``floorDB`` when silent.
    var decibels: Double {
        lock.lock()
        defer { lock.unlock() }
        return Self.decayed(from: heldDB, since: heldAt, to: now())
    }

    /// The reading as `0...1` across ``floorDB`` to full scale, for a bar.
    ///
    /// Linear in dB rather than in amplitude. A linear-amplitude bar spends
    /// nearly all its travel in the top 6 dB and shows speech as a twitch near
    /// zero, which is why every meter worth reading is scaled this way.
    var fraction: Double { Self.fraction(ofDecibels: decibels) }

    /// Whether the signal hit the rail recently enough to still matter.
    ///
    /// Held for a moment rather than reported instantaneously: a clip is one
    /// sample out of eight thousand, and an indicator that honest would flash
    /// too briefly to see.
    var isClipping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return now().timeIntervalSince(clippedAt) < 1.0
    }

    /// Drops the needle to the floor. Called when a path closes, so a stale
    /// reading does not sit on screen implying audio that stopped.
    func reset() {
        lock.lock()
        heldDB = Self.floorDB
        heldAt = .distantPast
        clippedAt = .distantPast
        lock.unlock()
    }

    // MARK: - The arithmetic

    static func decibels(forPeak peak: Int32) -> Double {
        guard peak > 0 else { return floorDB }
        let db = 20 * log10(Double(peak) / Double(Int16.max))
        return max(db, floorDB)
    }

    static func fraction(ofDecibels db: Double) -> Double {
        min(max((db - floorDB) / -floorDB, 0), 1)
    }

    private static func decayed(from db: Double, since: Date, to now: Date) -> Double {
        let elapsed = now.timeIntervalSince(since)
        guard elapsed > 0, elapsed.isFinite else { return db }
        return max(db - decayPerSecond * elapsed, floorDB)
    }
}

/// Software gain on the transmit path, in dB.
///
/// **Why this exists at all.** `AVAudioSession.inputGain` is only writable when
/// `isInputGainSettable` says so, which on an iPhone's built-in microphone it
/// does not — the input level is the system's business and an app does not get
/// a say. So the only place left to make a quiet operator louder is the samples
/// themselves, after capture and before the codec.
///
/// **Hard-limited, deliberately.** Multiplying 16-bit samples without clamping
/// wraps a loud syllable around to the opposite rail, which is not distortion
/// but a click — far worse on the air than the clipping it came from. Every
/// sample is clamped to the Int16 range, so the worst this can do is flat-top a
/// peak.
///
/// This is a fixed gain and not compression: what goes up is the whole signal,
/// room noise included. That is the honest trade and it is why the meter
/// matters — the operator can see how much headroom they have left rather than
/// guessing.
struct TransmitGain: Equatable, Sendable {
    /// Decibels of gain. `0` passes samples through untouched.
    var decibels: Double

    /// The useful range. Zero is "leave it alone"; +30 dB is enough to rescue a
    /// microphone that is genuinely far away, and beyond that the noise floor
    /// arrives before the speech does.
    static let range: ClosedRange<Double> = 0...30

    static let unity = TransmitGain(decibels: 0)

    init(decibels: Double) {
        self.decibels = min(max(decibels, Self.range.lowerBound), Self.range.upperBound)
    }

    /// The linear multiplier this gain represents.
    var multiplier: Double { pow(10, decibels / 20) }

    /// Applies the gain. Returns the frame unchanged at unity, so the common
    /// case allocates nothing.
    func apply(to frame: [Int16]) -> [Int16] {
        guard decibels > 0 else { return frame }
        let multiplier = self.multiplier
        return frame.map { sample in
            let amplified = (Double(sample) * multiplier).rounded()
            // Clamped in Double before narrowing: `Int16(exactly:)` on an
            // out-of-range value is nil and `Int16(_:)` traps, and this runs on
            // the audio thread where a trap is a crash mid-transmission.
            return Int16(min(max(amplified, Double(Int16.min)), Double(Int16.max)))
        }
    }
}
