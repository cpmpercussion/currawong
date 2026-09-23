// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **SF-1.** How long one transmission may last before the library's watchdog
/// unkeys. The library enforces it; this is the number `CompositionRoot`
/// hands over.
///
/// App-wide, not per channel, so an operator can always say what their limit
/// is. A struct so the clamp lives in the initialiser.
struct TransmitTimeout: Equatable, Sendable {
    /// Below 5 s the watchdog fires in normal use; 600 s is longer than any
    /// legitimate over.
    static let range: ClosedRange<TimeInterval> = 5...600

    /// 180 s, matching `RadioCore.TransmitWatchdog.defaultTimeout`, which is
    /// the authority if they differ. Used when nothing is stored.
    static let `default` = TransmitTimeout(seconds: 180)

    /// The timeout in seconds, always inside ``range``.
    let seconds: TimeInterval

    /// Clamped rather than rejected, and non-finite becomes the default:
    /// refusing to connect over a bad timeout is the wrong failure.
    init(seconds: TimeInterval) {
        guard seconds.isFinite else {
            self.seconds = 180
            return
        }
        self.seconds = min(max(seconds, Self.range.lowerBound), Self.range.upperBound)
    }

    /// Whole seconds, for a field and for a status line.
    var wholeSeconds: Int { Int(seconds.rounded()) }

    /// Parses typed whole seconds. Empty is the default, unparseable is `nil`,
    /// and out-of-range is clamped (`9999` becomes ten minutes).
    static func parse(_ text: String) -> TransmitTimeout? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .default }
        guard let value = Int(trimmed), value > 0 else { return nil }
        return TransmitTimeout(seconds: TimeInterval(value))
    }
}
