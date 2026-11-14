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

/// How one over sounded, as a single word and the level behind it.
struct OverVerdict: Equatable, Sendable {
    /// Where the over sat, on the transmit meter's own scale.
    let zone: LevelMeterView.Zone

    /// The level the loudest tenth of the over reached, in dBFS.
    let decibels: Double

    /// What to do about it, given the gain the over was sent with. `nil` when
    /// the level was good. The gain decides the wording because a slider
    /// already at its end cannot be moved further.
    func advice(gain: TransmitGain) -> String? {
        switch zone {
        case .good:
            return nil
        case .silent:
            return "No sound reached the microphone."
        case .low:
            return gain.decibels < TransmitGain.range.upperBound
                ? "Raise the microphone gain, or speak closer."
                : "Speak closer to the microphone."
        case .hot, .clipping:
            return gain.decibels > TransmitGain.range.lowerBound
                ? "Lower the microphone gain."
                : "Speak more softly, or further from the microphone."
        }
    }
}

/// Collects one over's frame peaks so it can be judged as a whole, which a
/// decaying meter cannot do.
///
/// ``note(_:)`` runs on the real-time capture thread beside
/// ``AudioLevelMeter/note(_:)`` and keeps to the same rules: a short
/// uncontended lock, and a fixed histogram so nothing is allocated.
final class OverLevelAccumulator: @unchecked Sendable {
    /// Fewer frames than this above the floor is too little speech to judge:
    /// about half a second at 20 ms a frame.
    static let minimumFrames = 25

    /// This many clipped frames make the over clipping, however the rest sat.
    /// More than one, so a single plosive does not decide it.
    static let clippedFramesForClipping = 3

    /// The share of frames louder than the level reported. Speech is mostly
    /// gaps and quiet syllables, so the verdict follows its loud tenth, which
    /// is what the meter's zones were drawn for.
    static let loudShare = 0.1

    /// One bin per decibel from the meter's floor up to full scale.
    private static let binCount = Int(-AudioLevelMeter.floorDB) + 1

    private let lock = NSLock()
    private var bins = [Int](repeating: 0, count: OverLevelAccumulator.binCount)
    private var framesAboveFloor = 0
    private var framesInAll = 0
    private var clippedFrames = 0

    /// Records one frame's peak. **Called on the audio thread.**
    func note(_ frame: [Int16]) {
        var peak: Int32 = 0
        for sample in frame {
            let magnitude = Int32(sample.magnitude)
            if magnitude > peak { peak = magnitude }
        }
        let db = AudioLevelMeter.decibels(forPeak: peak)

        lock.lock()
        framesInAll += 1
        if db > AudioLevelMeter.floorDB {
            framesAboveFloor += 1
            let bin = min(Int(db - AudioLevelMeter.floorDB), Self.binCount - 1)
            bins[bin] += 1
        }
        if peak >= AudioLevelMeter.clipThreshold { clippedFrames += 1 }
        lock.unlock()
    }

    /// Empties it for the next over.
    func reset() {
        lock.lock()
        for index in bins.indices { bins[index] = 0 }
        framesAboveFloor = 0
        framesInAll = 0
        clippedFrames = 0
        lock.unlock()
    }

    /// The over so far, judged. `nil` when it was too short to say anything.
    func verdict() -> OverVerdict? {
        lock.lock()
        defer { lock.unlock() }

        guard framesAboveFloor >= Self.minimumFrames else {
            // Long enough to have spoken, and nothing but silence arrived.
            return framesInAll >= Self.minimumFrames * 2 && framesAboveFloor == 0
                ? OverVerdict(zone: .silent, decibels: AudioLevelMeter.floorDB)
                : nil
        }

        // Walk down from the top until the loud share has been passed.
        let wanted = max(1, Int((Double(framesAboveFloor) * Self.loudShare).rounded(.up)))
        var seen = 0
        var level = AudioLevelMeter.floorDB
        for bin in bins.indices.reversed() {
            seen += bins[bin]
            if seen >= wanted {
                level = AudioLevelMeter.floorDB + Double(bin)
                break
            }
        }

        let zone: LevelMeterView.Zone =
            clippedFrames >= Self.clippedFramesForClipping
            ? .clipping : LevelMeterView.Zone(decibels: level)
        return OverVerdict(zone: zone, decibels: level)
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
