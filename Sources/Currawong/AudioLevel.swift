// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A peak-reading level meter in dBFS, one per audio path.
///
/// ``note(_:)`` runs on the real-time capture thread, so it takes a short
/// uncontended lock and never allocates, logs or blocks.
///
/// Instant attack, timed decay. Decay is computed on read from a timestamp,
/// not by a timer, so any polling rate reads correctly and an unwatched meter
/// costs nothing.
final class AudioLevelMeter: @unchecked Sendable {
    /// Quieter than this reads as silence: above phone room noise, below
    /// speech peaks.
    static let floorDB: Double = -54

    /// How fast the needle falls, in dB per second, as broadcast peak meters do.
    static let decayPerSecond: Double = 24

    /// A sample this close to full scale counts as clipped. Below 32767,
    /// because a signal riding the rail is distorting before it reaches it.
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
            // `magnitude`, not `abs`, which traps on Int16.min.
            let magnitude = Int32(sample.magnitude)
            if magnitude > peak { peak = magnitude }
        }

        let db = Self.decibels(forPeak: peak)
        let stamp = now()

        lock.lock()
        // A louder reading wins at once; a quieter one waits for the decay.
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

    /// The reading as `0...1` from ``floorDB`` to full scale, linear in dB: a
    /// linear-amplitude bar shows speech as a twitch near zero.
    var fraction: Double { Self.fraction(ofDecibels: decibels) }

    /// Whether the signal clipped in the last second. Held, because a single
    /// clipped sample would flash too briefly to see.
    var isClipping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return now().timeIntervalSince(clippedAt) < 1.0
    }

    /// Drops the needle to the floor when a path closes, so a stale reading
    /// does not imply audio.
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

/// A gain setting behind a lock, written on the main actor and read per frame
/// off it: by the capture tap for transmit, by a detached task for receive.
/// A box rather than a snapshot at key-down, so the slider works mid-over.
final class GainBox<Gain: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Gain

    init(_ gain: Gain) {
        self.stored = gain
    }

    var gain: Gain {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// Software gain on the transmit path, in dB, applied between capture and the
/// codec: `AVAudioSession.inputGain` is not settable on an iPhone's built-in
/// microphone. A fixed, clamped gain (see `amplify`), not compression, so room
/// noise rises too.
struct TransmitGain: Equatable, Sendable {
    /// Decibels of gain. `0` passes samples through untouched.
    var decibels: Double

    /// Beyond +30 dB the noise floor arrives before the speech.
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
        amplify(frame, by: decibels)
    }
}

/// Software gain on the receive path, in dB, for when a phone at full volume
/// is still too quiet after the library's leveller (AU-4). Same clamp and trade
/// as ``TransmitGain``.
///
/// Boost only: turning audio down is the device volume's job, and a software
/// attenuator would be a second volume knob the system knows nothing about.
struct ReceiveGain: Equatable, Sendable {
    /// Decibels of gain. `0` passes samples through untouched.
    var decibels: Double

    /// Beyond +20 dB the far end's hiss dominates.
    static let range: ClosedRange<Double> = 0...20

    static let unity = ReceiveGain(decibels: 0)

    init(decibels: Double) {
        self.decibels = min(max(decibels, Self.range.lowerBound), Self.range.upperBound)
    }

    /// The linear multiplier this gain represents.
    var multiplier: Double { pow(10, decibels / 20) }

    /// Applies the gain. Returns the frame unchanged at unity, so the common
    /// case allocates nothing.
    func apply(to frame: [Int16]) -> [Int16] {
        amplify(frame, by: decibels)
    }
}

/// The sample arithmetic both gains share. Clamped, so a loud syllable
/// flat-tops rather than wrapping to the opposite rail, and clamped in `Double`
/// before narrowing, because `Int16(_:)` traps out of range and a trap here is
/// a crash mid-transmission.
private func amplify(_ frame: [Int16], by decibels: Double) -> [Int16] {
    guard decibels > 0 else { return frame }
    let multiplier = pow(10, decibels / 20)
    return frame.map { sample in
        let amplified = (Double(sample) * multiplier).rounded()
        return Int16(min(max(amplified, Double(Int16.min)), Double(Int16.max)))
    }
}
