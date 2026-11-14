// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **SF-1.** How long one transmission may last before the library's watchdog
/// unkeys. The library enforces it; this is the number `CompositionRoot`
/// hands over.
///
/// App-wide, not per channel, so an operator can always say what their limit
/// is. A struct so the clamp lives in the initialiser.
struct TransmitTimeout: Equatable, Sendable {
    /// Below 5 s the watchdog fires in normal use. 180 s is a common repeater
    /// time-out timer, so a longer limit here would be one the far end enforces
    /// first.
    static let range: ClosedRange<TimeInterval> = 5...180

    /// 60 s, used when nothing is stored. Deliberately shorter than
    /// `RadioCore.TransmitWatchdog.defaultTimeout`: most overs are well under a
    /// minute, and the operator is usually a guest on someone else's node. The
    /// library's default never applies, because `CompositionRoot` always hands
    /// it this type's number.
    static let `default` = TransmitTimeout(seconds: defaultSeconds)

    private static let defaultSeconds: TimeInterval = 60

    /// The timeout in seconds, always inside ``range``.
    let seconds: TimeInterval

    /// Clamped rather than rejected, and non-finite becomes the default:
    /// refusing to connect over a bad timeout is the wrong failure.
    init(seconds: TimeInterval) {
        guard seconds.isFinite else {
            self.seconds = Self.defaultSeconds
            return
        }
        self.seconds = min(max(seconds, Self.range.lowerBound), Self.range.upperBound)
    }

    /// Whole seconds, for a field and for a status line.
    var wholeSeconds: Int { Int(seconds.rounded()) }

    /// Parses typed whole seconds. Empty is the default, unparseable is `nil`,
    /// and out-of-range is clamped (`9999` becomes three minutes).
    static func parse(_ text: String) -> TransmitTimeout? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .default }
        guard let value = Int(trimmed), value > 0 else { return nil }
        return TransmitTimeout(seconds: TimeInterval(value))
    }
}
