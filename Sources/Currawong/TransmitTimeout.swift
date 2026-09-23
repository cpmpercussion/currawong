// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **SF-1.** How long one transmission may last before the library's watchdog
/// unkeys.
///
/// **App-wide, not per channel.** The watchdog exists to stop a stuck
/// microphone, and a safety limit an operator has to check per channel is one
/// they cannot answer "what is mine set to?" about. One number, on the
/// settings screen, beside the other things that are the operator's rather
/// than the channel's.
///
/// Modelled on ``TransmitGain``: a struct rather than a bare `TimeInterval` so
/// the clamp lives in the initialiser and there is no way to hold an
/// out-of-range one. The library owns the enforcement; this is only the number
/// handed to it, and `CompositionRoot` is what hands it over.
struct TransmitTimeout: Equatable, Sendable {
    /// What the operator is allowed to ask for. Below the floor the watchdog
    /// fires inside a normal call-and-response and the app becomes unusable
    /// rather than safe; the ceiling is longer than any legitimate single
    /// transmission and well inside what a repeater's own timer will tolerate.
    static let range: ClosedRange<TimeInterval> = 5...600

    /// 180 s, matching `RadioCore.TransmitWatchdog.defaultTimeout`. Duplicated
    /// rather than imported because this layer does not import the library —
    /// the library's own default is the authority if they ever differ, and
    /// this is what is used when nothing has been stored.
    static let `default` = TransmitTimeout(seconds: 180)

    /// The timeout in seconds, always inside ``range``.
    let seconds: TimeInterval

    /// Clamped rather than rejected, and a non-finite value becomes the
    /// default: refusing to connect over an out-of-range timeout would be a
    /// safety feature that prevents transmitting altogether, the wrong shape
    /// of failure. A value that is not a number at all never gets this far;
    /// see ``parse(_:)``.
    init(seconds: TimeInterval) {
        guard seconds.isFinite else {
            self.seconds = 180
            return
        }
        self.seconds = min(max(seconds, Self.range.lowerBound), Self.range.upperBound)
    }

    /// Whole seconds, for a field and for a status line.
    var wholeSeconds: Int { Int(seconds.rounded()) }

    /// Parses a timeout the operator typed, in whole seconds.
    ///
    /// Empty means the default; anything unparseable is rejected so the field
    /// can refuse the keystroke rather than silently storing something else.
    /// Out-of-range values are not rejected here — they are clamped by the
    /// initialiser, so typing `9999` lands on ten minutes instead of leaving
    /// the field stuck.
    static func parse(_ text: String) -> TransmitTimeout? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .default }
        guard let value = Int(trimmed), value > 0 else { return nil }
        return TransmitTimeout(seconds: TimeInterval(value))
    }
}
