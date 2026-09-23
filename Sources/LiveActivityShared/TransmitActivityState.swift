// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **SF-4.** What the lock screen is told about the transmitter.
///
/// Shared by the app and the widget extension, and made of strings and dates so
/// the widget only draws: every judgement about wording is made in the app,
/// where it can be tested. No ActivityKit import, so it compiles on macOS.
struct TransmitActivityState: Codable, Hashable, Sendable {

    /// **The one field that must never lie.** True only while the operator's
    /// voice is actually going on air — so false during a route-change
    /// recovery's gap. A safety display that claims TX over a shut microphone
    /// teaches the operator not to trust it.
    var isOnAir: Bool

    /// The large line. Short enough for the Dynamic Island's compact form.
    var headline: String

    /// Whether letting go will unkey (PT-4), or what the app is waiting for;
    /// the same sentence as the on-screen banner.
    var detail: String

    /// When the current *hold* began, not the current key-down, so a
    /// route-change resume does not restart the elapsed timer.
    var holdBegan: Date

    /// When the SF-1 watchdog will unkey this key-down; `nil` when nothing is
    /// on air. A separate clock from ``holdBegan``: each resume restarts it.
    var watchdogDeadline: Date?
}
