// SPDX-License-Identifier: Apache-2.0

#if os(iOS)

import ActivityKit
import Foundation

/// **SF-4.** The ActivityKit declaration for the transmit Live Activity.
///
/// `iOS` only, and guarded with `#if os(iOS)` rather than
/// `#if canImport(ActivityKit)`: macOS has no Live Activities, the macOS build
/// and its tests are part of APP-3's definition of done, and "does this SDK
/// happen to vend the module?" is a different question from "does this platform
/// have the feature?".
///
/// The attributes are the part that cannot change for the life of an activity,
/// so only the connection's identity lives here; everything that moves is in
/// ``TransmitActivityState``. A channel change therefore ends one activity and
/// starts another, which is the honest thing — it is a different radio.
struct TransmitActivityAttributes: ActivityAttributes {
    typealias ContentState = TransmitActivityState

    /// The channel's display name, as the channel list shows it.
    var channel: String

    /// The mode's display name — "AllStarLink", "M17", "EchoLink". Named
    /// nominatively only, per OQ-1b.
    var mode: String
}

#endif
