// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the operator taught the app about their accessory (PT-3): the signal
/// it sends on press and the one it sends on release, and nothing else.
///
/// **Invariant: `press != release`.** Identical signals would key the radio and
/// never unkey it. The initialiser fails rather than build one, and
/// ``isUsable`` re-checks after decoding, which bypasses the initialiser.
struct BLEPTTMapping: Codable, Equatable, Sendable {
    let accessoryID: UUID
    let accessoryName: String?
    let press: BLESignal
    let release: BLESignal

    /// Fails when the two signals are identical.
    init?(accessoryID: UUID, accessoryName: String?, press: BLESignal, release: BLESignal) {
        guard press != release else { return nil }
        self.accessoryID = accessoryID
        self.accessoryName = accessoryName
        self.press = press
        self.release = release
    }

    /// Whether press and release differ. Checked again on load.
    var isUsable: Bool { press != release }

    var accessoryDisplayName: String { accessoryName ?? "Bluetooth accessory" }

    /// Whether both edges come from one characteristic, for the learn-mode
    /// summary.
    var usesOneCharacteristic: Bool { press.path == release.path }
}

/// Learn mode's state machine (PT-3), as a value type driven by notifications
/// and the operator's "nothing else arrived".
///
/// Handles one or two characteristics, and a press payload that repeats while
/// held (latched, not mistaken for the release). Refuses press and release that
/// look the same, which would key and never unkey. The confirmation pass (a
/// second press and release must match the first) catches payloads that vary,
/// which an exact-match mapping would stop matching.
struct PTTLearner: Equatable {

    /// Where the operator is in the sequence; what the UI renders.
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

    /// Why an accessory could not be learned, each shown as a sentence.
    enum Problem: String, Equatable, Sendable {
        /// Nothing arrived.
        case noPressObserved

        /// A press, but no release: a PTT built on it would stay keyed.
        case noReleaseObserved

        /// Press and release send identical notifications.
        case pressAndReleaseAreIndistinguishable

        /// The confirmation pass differed: the payload is not stable.
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

    /// Every distinct signal seen, in order, with counts. Shown in the UI.
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
            // A repeated press means "still held", not the release.
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
            // Unrelated characteristics are ignored.

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

    /// The operator pressed and released and nothing new appeared — the only
    /// way to tell "still held, repeating" from "released, same payload".
    mutating func nothingElseArrived() {
        guard !isFinished else { return }
        switch step {
        case .awaitingPress:
            step = .unlearnable(.noPressObserved)
        case .awaitingRelease:
            // A press that came back means release sends the same thing, which
            // needs a different accessory; silence may need a different button.
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
            // Unreachable by construction, but being wrong would mean a stuck
            // microphone, so it is checked rather than asserted.
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

/// Persistence for the learned mapping and the PT-4 preference. A protocol so
/// tests do not write to `UserDefaults.standard`.
protocol PTTSettingsStore: AnyObject, Sendable {
    func loadMapping() -> BLEPTTMapping?
    func saveMapping(_ mapping: BLEPTTMapping?)
    func loadRemoteCommandEnabled() -> Bool
    func saveRemoteCommandEnabled(_ enabled: Bool)
}

/// `UserDefaults`-backed PTT settings. Two keys, not one blob, so the two
/// controllers cannot overwrite each other's half.
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
        // Stored data is untrusted; matching signals must never reach runtime.
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
