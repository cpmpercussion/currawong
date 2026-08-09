// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

/// What the app needs to know about a connection, beyond `TransmitState`.
///
/// `RadioCore.NetworkClient` gives the app `state`, `connect`, `disconnect`,
/// `startTransmit` and `stopTransmit` and nothing else — no event stream, no
/// received audio, no way to hand captured audio back. Every concrete client
/// has all three, but they are on the concrete type, so the app cannot reach
/// them generically. This enum is the app-side vocabulary the composition root
/// maps a concrete client's events into; see ``RadioLink`` for the rest of the
/// hole and the note in `CompositionRoot`.
enum RadioLinkEvent: Sendable, Equatable {
    /// The call is up and media may flow.
    case connected

    /// Transmission started.
    case transmitting

    /// Transmission stopped, for any reason.
    case receiving

    /// **SF-1.** The transmit watchdog reached its deadline and unkeyed on the
    /// operator's behalf. This must reach the operator's eyes: it means a PTT
    /// was held — or stuck — for the whole timeout.
    case transmitWatchdogExpired(Duration)

    /// Inbound media is being discarded, with a human-readable reason. Not
    /// fatal, but it is the difference between "the link is quiet" and "the
    /// link is broken", and the operator cannot tell those apart by ear.
    case mediaRejected(String)

    /// The call ended, with the reason if there was one.
    case disconnected(reason: String?)
}

/// Why transmission stopped.
///
/// Every PTT release path in the app names one of these, which is how the
/// tests can prove that each path really does end transmission: the reason is
/// recorded on the view model and asserted. A case here without a call site is
/// a path nobody wired up, and a call site without a case is a path nobody
/// thought about.
enum TransmitStopReason: String, Sendable, Equatable, CaseIterable {
    /// Touch-up on the PTT button. The ordinary case.
    case released

    /// The finger left the button's bounds while still down. A finger that has
    /// slid off the button is a finger that is no longer paying attention to
    /// it, and a PTT that keeps transmitting in that state is a PTT that can
    /// be forgotten about.
    case draggedOffButton

    /// The gesture was cancelled out from under us — a system gesture took
    /// over, a scroll won the recogniser race, the touch was invalidated.
    case gestureCancelled

    /// The view holding the button went away.
    case viewDisappeared

    /// The app left the foreground.
    case appBackgrounded

    /// **SF-3.** The audio session was interrupted.
    case audioInterrupted

    /// **SF-3.** The audio route changed.
    case routeChanged

    /// **SF-1.** The transmit watchdog fired.
    case watchdogExpired

    /// The operator disconnected, or the link dropped.
    case disconnecting

    /// Keying up failed. Nothing went on air; the button is released so the
    /// operator has to make a fresh, deliberate press.
    case transmitFailed

    /// Whether this stop happened *to* the operator rather than because of
    /// them. These are the ones worth explaining on screen — an operator who
    /// does not know why they were unkeyed will simply key up again.
    var isUnexpected: Bool {
        switch self {
        case .released, .draggedOffButton, .disconnecting:
            return false
        case .gestureCancelled, .viewDisappeared, .appBackgrounded,
            .audioInterrupted, .routeChanged, .watchdogExpired, .transmitFailed:
            return true
        }
    }
}

/// One connection's worth of plumbing, assembled by the composition root.
///
/// Generic over `Client: NetworkClient` rather than holding `any
/// NetworkClient`, because the protocol has an `associatedtype Destination`
/// and so has no existential form. The destination travels *with* the client
/// for the same reason: the view model cannot construct a `Client.Destination`
/// from `NodeSettings` without knowing what one is, so whoever knew how to
/// build the client builds it too.
///
/// A link is single-use. `IAX2Client.disconnect()` shuts its client down for
/// good — the streams finish and a second `connect(to:)` throws — so
/// reconnecting means a new link, not a reset of this one. ``RadioSession``
/// asks for a fresh one on every connect.
struct RadioLink<Client: NetworkClient> {
    /// The client, spoken to only through `NetworkClient`.
    let client: Client

    /// Where this link connects to.
    let destination: Client.Destination

    /// Lifecycle, watchdog and media events, already translated out of
    /// whatever protocol-specific enum they arrived in.
    let events: AsyncStream<RadioLinkEvent>

    /// Decoded 8 kHz mono PCM from the far end, 160 samples per 20 ms.
    let receivedAudio: AsyncStream<[Int16]>

    /// Hands one captured 20 ms frame to the client.
    ///
    /// **Called from the audio thread**, so it must not block, must not
    /// allocate unboundedly, and must not `await`. The composition root
    /// satisfies that with ``CapturedFrameRelay``.
    let sendCapturedFrame: @Sendable ([Int16]) -> Void

    /// Releases the pumps this link owns. Idempotent; called on every
    /// teardown path, including a connect that failed.
    let close: @Sendable () -> Void
}
