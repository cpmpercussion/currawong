// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **PT-3.** What the operator taught the app about their accessory.
///
/// Two signals. That is the entire model of a Bluetooth PTT button, and it is
/// deliberately the entire model: no vendor, no service whitelist, no product
/// table to maintain and go stale. Whatever the accessory sends when the button
/// goes down is `press`; whatever it sends when the button comes up is
/// `release`.
///
/// ## The invariant
///
/// `press != release`. A mapping whose two signals are identical cannot tell
/// keying from unkeying, so at runtime it would key the radio and never unkey
/// it — a stuck-open-microphone generator. The initialiser therefore **fails**
/// rather than storing one, and ``isUsable`` re-checks the invariant after
/// decoding, because a synthesised `init(from:)` does not run the initialiser
/// and a file on disk is not a trusted source.
struct BLEPTTMapping: Codable, Equatable, Sendable {
    let accessoryID: UUID
    let accessoryName: String?
    let press: BLESignal
    let release: BLESignal

    /// Fails when the two signals cannot be told apart. See the note above:
    /// this is the one construction the type refuses to represent.
    init?(accessoryID: UUID, accessoryName: String?, press: BLESignal, release: BLESignal) {
        guard press != release else { return nil }
        self.accessoryID = accessoryID
        self.accessoryName = accessoryName
        self.press = press
        self.release = release
    }

    /// Whether this mapping can distinguish a press from a release. Always
    /// true for anything the initialiser produced; checked again on load.
    var isUsable: Bool { press != release }

    var accessoryDisplayName: String { accessoryName ?? "Bluetooth accessory" }

    /// Whether both edges come from the same characteristic. Common — a fob
    /// that reports `01` down and `00` up — and worth showing the operator, so
    /// the learn-mode summary is recognisable as *their* device.
    var usesOneCharacteristic: Bool { press.path == release.path }
}

/// **PT-3, the state machine.** Learn mode with no view attached.
///
/// A value type, driven entirely by notifications in and one "nothing else
/// arrived" nudge from the operator, so every awkward device shape can be
/// replayed in a unit test in three lines.
///
/// ## The shapes it has to survive
///
/// * **One characteristic, two payloads** (`01` down, `00` up). The common
///   case; learned in two steps.
/// * **Two characteristics.** Equally fine — a signal is a *path plus* a
///   payload, so nothing here assumes they share a path.
/// * **A payload that repeats while the button is held.** The press signal is
///   latched, and every later notification identical to it is counted and
///   ignored rather than mistaken for the release.
/// * **Press and release that look the same.** Unlearnable, and it says so.
///   This is the important one: silently accepting it would produce a mapping
///   that keys and never unkeys. See ``Problem/pressAndReleaseAreIndistinguishable``.
/// * **A payload that does not repeat** — a sequence counter in the bytes, say.
///   Caught by the confirmation pass, because a mapping that matches by exact
///   bytes would never match again.
///
/// ## Why there is a confirmation pass
///
/// After the first press and release, the operator is asked to do it once more.
/// The second pass must produce the *same two signals*. It costs one extra
/// press and it is the only way to catch an accessory whose payload varies —
/// which at runtime would look like an accessory that keys and then ignores
/// every release.
struct PTTLearner: Equatable {

    /// Where the operator is in the sequence. The UI renders this and nothing
    /// else.
    enum Step: Equatable {
        /// "Press and hold the button on your accessory."
        case awaitingPress
        /// "Now let go."
        case awaitingRelease
        /// "Press and hold once more."
        case confirmingPress
        /// "And let go once more."
        case confirmingRelease
        /// Done. The mapping is ready to save.
        case learned(BLEPTTMapping)
        /// This accessory cannot be used as a momentary PTT.
        case unlearnable(Problem)
    }

    /// Why an accessory could not be learned. Every one of these is shown to
    /// the operator as a sentence; none of them is silent.
    enum Problem: String, Equatable, Sendable {
        /// Nothing at all arrived. Either the accessory does not notify, or the
        /// button pressed was not the one wired to a characteristic.
        case noPressObserved

        /// A press was seen but nothing different ever followed it. The
        /// accessory reports that the button went down and never that it came
        /// up, so a momentary PTT built on it would key and stay keyed.
        case noReleaseObserved

        /// Press and release produce byte-for-byte the same notification. The
        /// app cannot tell them apart, so it will not pretend to.
        case pressAndReleaseAreIndistinguishable

        /// The confirmation pass produced something different. The accessory's
        /// payload is not stable — a counter or a timestamp in the bytes —
        /// and an exact-match mapping would stop working immediately.
        case unstablePayload

        var message: String {
            switch self {
            case .noPressObserved:
                return
                    "Nothing arrived from the accessory. It may not report button presses over "
                    + "Bluetooth LE notifications, or another button may be the one that does."
            case .noReleaseObserved:
                return
                    "The accessory reported the button going down but never coming back up. "
                    + "Currawong will not use it: a push-to-talk that cannot see the release would "
                    + "leave you transmitting."
            case .pressAndReleaseAreIndistinguishable:
                return
                    "Press and release send exactly the same thing, so Currawong cannot tell them "
                    + "apart. This accessory cannot be used as a momentary push-to-talk."
            case .unstablePayload:
                return
                    "The second press sent something different from the first, so the accessory's "
                    + "messages are not repeatable. Currawong cannot match them reliably."
            }
        }
    }

    /// One distinct signal and how many times it arrived.
    struct ObservedSignal: Equatable, Identifiable {
        let signal: BLESignal
        var count: Int

        var id: BLESignal { signal }
    }

    let accessoryID: UUID
    let accessoryName: String?

    private(set) var step: Step = .awaitingPress
    private(set) var press: BLESignal?
    private(set) var release: BLESignal?

    /// Every distinct signal seen, in order of first arrival, with how many
    /// times it arrived. Shown in the learn-mode UI so an operator whose
    /// accessory is chattering can see that it is, rather than staring at a
    /// screen that says nothing is happening.
    private(set) var observed: [ObservedSignal] = []

    init(accessoryID: UUID, accessoryName: String?) {
        self.accessoryID = accessoryID
        self.accessoryName = accessoryName
    }

    var isFinished: Bool {
        switch step {
        case .learned, .unlearnable: return true
        case .awaitingPress, .awaitingRelease, .confirmingPress, .confirmingRelease: return false
        }
    }

    var mapping: BLEPTTMapping? {
        if case .learned(let mapping) = step { return mapping }
        return nil
    }

    var problem: Problem? {
        if case .unlearnable(let problem) = step { return problem }
        return nil
    }

    // MARK: - Driving it

    /// A notification arrived from the accessory being learned.
    mutating func observe(_ signal: BLESignal) {
        guard !isFinished else { return }
        record(signal)

        switch step {
        case .awaitingPress:
            press = signal
            step = .awaitingRelease

        case .awaitingRelease:
            // A repeat of the press is the accessory saying "still held". It is
            // not the release, and treating it as one would produce a mapping
            // that unkeys the instant it keys.
            guard signal != press else { return }
            release = signal
            step = .confirmingPress

        case .confirmingPress:
            if signal == press {
                step = .confirmingRelease
            } else if signal == release {
                // The tail of the first release, arriving late. Ignore it.
                return
            } else if isOnAMappedPath(signal) {
                step = .unlearnable(.unstablePayload)
            }
            // Anything on an unrelated characteristic — a battery level, a
            // heartbeat — is none of this state machine's business.

        case .confirmingRelease:
            if signal == release {
                finish()
            } else if signal == press {
                return  // Still held; the accessory repeats.
            } else if isOnAMappedPath(signal) {
                step = .unlearnable(.unstablePayload)
            }

        case .learned, .unlearnable:
            return
        }
    }

    /// The operator says they have finished pressing and releasing and nothing
    /// new appeared.
    ///
    /// This is the only way out of ``Step/awaitingRelease`` for an accessory
    /// whose press and release are identical: the app cannot distinguish "still
    /// held, repeating" from "released, same payload" by watching, so it asks.
    mutating func nothingElseArrived() {
        guard !isFinished else { return }
        switch step {
        case .awaitingPress:
            step = .unlearnable(.noPressObserved)
        case .awaitingRelease:
            // If the press signal came back after being latched, the accessory
            // *is* saying something on release — the same thing it said on
            // press. That is the indistinguishable case, and it is worth naming
            // separately from silence, because the fix is different: one needs
            // a different accessory, the other needs a different button.
            let pressCount = press.map { count(of: $0) } ?? 0
            step = .unlearnable(
                pressCount > 1 ? .pressAndReleaseAreIndistinguishable : .noReleaseObserved)
        case .confirmingPress, .confirmingRelease:
            step = .unlearnable(.unstablePayload)
        case .learned, .unlearnable:
            return
        }
    }

    // MARK: - Private

    private mutating func finish() {
        guard let press, let release,
            let mapping = BLEPTTMapping(
                accessoryID: accessoryID,
                accessoryName: accessoryName,
                press: press,
                release: release)
        else {
            // Unreachable by construction — `release` is only ever set to a
            // signal that differs from `press` — but the failure mode of being
            // wrong about that is a stuck microphone, so it is checked rather
            // than asserted.
            step = .unlearnable(.pressAndReleaseAreIndistinguishable)
            return
        }
        step = .learned(mapping)
    }

    private mutating func record(_ signal: BLESignal) {
        if let index = observed.firstIndex(where: { $0.signal == signal }) {
            observed[index].count += 1
        } else {
            observed.append(ObservedSignal(signal: signal, count: 1))
        }
    }

    private func count(of signal: BLESignal) -> Int {
        observed.first(where: { $0.signal == signal })?.count ?? 0
    }

    private func isOnAMappedPath(_ signal: BLESignal) -> Bool {
        signal.path == press?.path || signal.path == release?.path
    }
}

/// Where a learned mapping and the PT-4 preference live between launches.
///
/// A protocol for the same reason ``SettingsStore`` is one: a unit test that
/// writes to `UserDefaults.standard` leaks into every later run on the machine.
protocol PTTSettingsStore: AnyObject, Sendable {
    func loadMapping() -> BLEPTTMapping?
    func saveMapping(_ mapping: BLEPTTMapping?)
    func loadRemoteCommandEnabled() -> Bool
    func saveRemoteCommandEnabled(_ enabled: Bool)
}

/// `UserDefaults`-backed PTT settings. Two independent keys rather than one
/// blob, so the two controllers that own these preferences can never overwrite
/// each other's half.
final class UserDefaultsPTTSettingsStore: PTTSettingsStore, @unchecked Sendable {
    private static let mappingKey = "au.charlesmartin.currawong.blePTTMapping"
    private static let remoteKey = "au.charlesmartin.currawong.remoteCommandPTT"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadMapping() -> BLEPTTMapping? {
        guard let data = defaults.data(forKey: Self.mappingKey),
            let mapping = try? JSONDecoder().decode(BLEPTTMapping.self, from: data)
        else { return nil }
        // A stored mapping is not a trusted source: an older build, a hand-edited
        // plist or a sync conflict could produce one whose two signals match,
        // and that is the one shape that must never reach the runtime matcher.
        return mapping.isUsable ? mapping : nil
    }

    func saveMapping(_ mapping: BLEPTTMapping?) {
        guard let mapping, mapping.isUsable else {
            defaults.removeObject(forKey: Self.mappingKey)
            return
        }
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        defaults.set(data, forKey: Self.mappingKey)
    }

    func loadRemoteCommandEnabled() -> Bool {
        defaults.bool(forKey: Self.remoteKey)
    }

    func saveRemoteCommandEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.remoteKey)
    }
}
