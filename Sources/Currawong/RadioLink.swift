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
    /// The call is up and media may flow. `codec` is the negotiated codec as a
    /// human-readable name, already rendered by the composition root — the app
    /// displays it and does not reason about it. It is `nil` when the far end
    /// did not say.
    ///
    /// Worth surfacing rather than swallowing: "connected but negotiated
    /// something we cannot decode" and "connected and silent" look identical
    /// from the operator's chair, and the first is a configuration problem at
    /// the node.
    case connected(codec: String?)

    /// Transmission started.
    case transmitting

    /// Transmission stopped, for any reason.
    case receiving

    /// A DTMF digit arrived from the far end (FR-1.5).
    ///
    /// Nodes echo digits back and announce their own, so this is how the
    /// operator can tell "the node heard my command" from "the node ignored
    /// it" — which, when commanding an AllStar node by DTMF, is the whole
    /// question.
    case dtmfReceived(Character)

    /// **SF-1.** The transmit watchdog reached its deadline and unkeyed on the
    /// operator's behalf. This must reach the operator's eyes: it means a PTT
    /// was held — or stuck — for the whole timeout.
    case transmitWatchdogExpired(Duration)

    /// Inbound media is being discarded, with a human-readable reason. Not
    /// fatal, but it is the difference between "the link is quiet" and "the
    /// link is broken", and the operator cannot tell those apart by ear.
    case mediaRejected(String)

    /// Who is transmitting on a shared channel, or `nil` when they stopped.
    ///
    /// **M17 only.** A reflector module is a shared channel — everyone linked
    /// to it hears everyone else — so the identity of the station currently
    /// transmitting is both available and worth showing. An AllStarLink call
    /// is point-to-point and produces this never.
    ///
    /// A `nil` callsign means a station whose base-40 address did not decode
    /// to text, which is legal and happens for the reserved and extended
    /// address ranges.
    case remoteStation(callsign: String?)

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

    /// **PT-2.** The release edge from a learned Bluetooth accessory. Distinct
    /// from ``released`` only so the tests can tell which input let go, which
    /// matters because the accessory is the one input whose release can also go
    /// missing — see ``accessoryLinkLost`` on `PTTSink`.
    case accessoryReleased

    /// **SF-2.** The Bluetooth accessory's link went away while it was, or
    /// might have been, holding the key.
    ///
    /// Distinct from ``accessoryReleased`` because nobody let go of anything.
    /// An accessory that has dropped off the link cannot report a release, so
    /// the app can no longer answer "is the button still held?" — and the only
    /// safe answer to a question like that is to unkey. This is the case
    /// SF-2 exists for: an accessory that goes out of range, runs out of
    /// battery or falls off the desk mid-sentence.
    case accessoryLinkLost

    /// **PT-4.** A latched remote-command transmission was unlatched — either
    /// by a second press, or by the operator switching the remote input off
    /// while it still held the key. Deliberate in both cases.
    case remoteCommandToggled

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
        case .released, .accessoryReleased, .remoteCommandToggled,
            .draggedOffButton, .disconnecting:
            return false
        case .gestureCancelled, .viewDisappeared, .appBackgrounded,
            .audioInterrupted, .routeChanged, .watchdogExpired, .transmitFailed,
            .accessoryLinkLost:
            return true
        }
    }
}

/// One connection's worth of plumbing, assembled by the composition root.
///
/// **Not generic, and deliberately no longer holding a client.** It used to be
/// `RadioLink<Client: NetworkClient>`, which worked while there was one mode
/// and stopped working the moment there were two: `NetworkClient` has an
/// `associatedtype Destination`, so `any NetworkClient` does not exist, and a
/// generic parameter has to be *chosen* somewhere. It was chosen in
/// `CompositionRoot`, which meant the app could hold an AllStarLink session or
/// an M17 session, but never one of either.
///
/// The way out is that ``RadioSession`` never needed the client — only five
/// operations on it. Each is a closure here, captured over whichever concrete
/// client and destination the composition root built. The generic parameter
/// disappears, both modes produce the same type, and the seam is otherwise
/// unchanged: this is still the only place the app's vocabulary meets the
/// library's.
///
/// A link is single-use. Both clients shut down for good on `disconnect()` —
/// the streams finish and a second connect throws — so reconnecting means a
/// new link, not a reset of this one. ``RadioSession`` asks the factory for a
/// fresh one on every connect.
struct RadioLink {
    /// Which network this link speaks. For display, and for the few decisions
    /// the app is allowed to make about modes; it names no library type.
    let mode: RadioMode

    /// Connects to the destination this link was built for.
    ///
    /// The destination is captured rather than exposed, because it is a
    /// protocol-specific type — an `IAX2Destination` or an `M17Destination` —
    /// and letting one out would put library vocabulary back into the app.
    let connect: @Sendable () async throws -> Void

    /// Drops the connection and shuts the client down.
    let disconnect: @Sendable () async -> Void

    /// Keys up. Throws if the client is not connected.
    let startTransmit: @Sendable () async throws -> Void

    /// Unkeys. Idempotent, and safe when not connected — the SF-2 and SF-3
    /// paths call it without being able to know the current state.
    let stopTransmit: @Sendable () async -> Void

    /// The client's transmit state, read live.
    ///
    /// A closure rather than a stored value because it has to be *current*:
    /// the watchdog (SF-1) can unkey between two reads, and a snapshot taken
    /// when the link was built would be a lie for the rest of the session.
    let transmitState: @Sendable () -> TransmitState

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

    /// Sends one DTMF digit (FR-1.5). Another hole in `NetworkClient` — the
    /// concrete clients have it, the protocol does not — closed the same way as
    /// the streams above.
    ///
    /// Signalling rather than audio: it does **not** require PTT, and the app
    /// deliberately does not key the radio around it. Throws whatever the
    /// client throws, including "not connected".
    let sendDTMF: @Sendable (Character) async throws -> Void

    /// Releases the pumps this link owns. Idempotent; called on every
    /// teardown path, including a connect that failed.
    let close: @Sendable () -> Void
}
