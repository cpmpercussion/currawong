// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **SF-4.** What the lock screen is told about the transmitter, as a plain
/// value.
///
/// Compiled into both the app and the widget extension, and deliberately made
/// of strings and dates rather than of the app's own types: the widget draws
/// this and decides nothing. Every judgement about wording — which input is
/// holding the key, whether letting go will unkey, whether the radio is on air
/// at all — is made in the app, next to ``TransmitStatusPresentation``, where it
/// can be unit-tested without a widget, a device or a lock screen.
///
/// It is `Codable` because `ActivityKit` archives it across the process
/// boundary, and `Hashable` because `ActivityAttributes.ContentState` requires
/// it. Nothing here imports `ActivityKit`, so it compiles on macOS, where there
/// are no Live Activities at all.
struct TransmitActivityState: Codable, Hashable, Sendable {

    /// **The one field that must never lie.** True only while the operator's
    /// voice is actually going on air.
    ///
    /// A Live Activity still claiming TX after transmission stopped is worse
    /// than no Live Activity: it is a safety display that lies, and an operator
    /// who learns not to trust it has lost the thing SF-4 was for. So this is
    /// false during the gap in the middle of a route-change recovery, and the
    /// activity says so, rather than holding the red banner up over a
    /// microphone that is shut.
    var isOnAir: Bool

    /// The large line. Short enough for the Dynamic Island's compact form.
    var headline: String

    /// Whether letting go will unkey (PT-4), or what the app is waiting for.
    /// The same sentence the on-screen banner shows, so the two cannot disagree.
    var detail: String

    /// When the current *hold* began — not the current key-down. A route-change
    /// recovery keys down again under the same hold, and an elapsed timer that
    /// restarted at that moment would tell the operator their over is younger
    /// than it is.
    var holdBegan: Date

    /// When the library's watchdog (SF-1) will unkey this key-down, if it is
    /// keyed. `nil` when nothing is on air.
    ///
    /// Distinct from ``holdBegan`` on purpose: they are two different clocks,
    /// and after a route-change resume the watchdog's is the younger of them.
    var watchdogDeadline: Date?
}
