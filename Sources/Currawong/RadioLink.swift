// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

/// What the app needs to know about a connection, beyond `TransmitState`:
/// the vocabulary each client's own `events` are mapped into by the
/// `CompositionRoot` factories (which do not yet use `NetworkClient.radioEvents`).
enum RadioLinkEvent: Sendable, Equatable {
    /// The call is up. `codec` is the negotiated codec's display name, `nil`
    /// when the far end did not say; shown because an undecodable codec
    /// otherwise sounds exactly like a silent link.
    case connected(codec: String?)

    /// Transmission started.
    case transmitting

    /// Transmission stopped, for any reason.
    case receiving

    /// A DTMF digit arrived from the far end (FR-1.5) — how the operator sees
    /// that a node heard a command.
    case dtmfReceived(Character)

    /// **SF-1.** The transmit watchdog unkeyed on the operator's behalf. Must be
    /// shown: a PTT was held, or stuck, for the whole timeout.
    case transmitWatchdogExpired(Duration)

    /// Inbound media is being discarded, with a reason. Not fatal, but it tells
    /// "quiet" from "broken", which the operator cannot do by ear.
    case mediaRejected(String)

    /// Who is transmitting on a shared M17 reflector module; the event is
    /// never produced for a point-to-point call. A `nil` callsign is a legal
    /// base-40 address (reserved or extended range) that does not decode to text.
    case remoteStation(callsign: String?)

    /// The call ended, with the reason if there was one.
    case disconnected(reason: String?)
}

/// Why transmission stopped.
///
/// Every PTT release path names one, and the view model records it, so the
/// tests can prove each path really ends transmission.
enum TransmitStopReason: String, Sendable, Equatable, CaseIterable {
    /// Touch-up on the PTT button. The ordinary case.
    case released

    /// **PT-2.** The release edge from a learned Bluetooth accessory.
    case accessoryReleased

    /// **SF-2.** The accessory's link dropped while it was, or might have been,
    /// holding the key. It cannot report a release, so the only safe answer is
    /// to unkey.
    case accessoryLinkLost

    /// **PT-4.** A latched remote-command transmission was unlatched, by a
    /// second press or by switching the remote input off.
    case remoteCommandToggled

    /// The finger left the button while still down.
    case draggedOffButton

    /// The system cancelled the gesture.
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

    /// Keying up failed. Nothing went on air; a fresh press is needed.
    case transmitFailed

    /// Whether the operator is still holding the key after this stop.
    ///
    /// Only a route change: the operator did not let go, so ``RadioSession``
    /// keys back down. SF-3 still holds — transmission stops, and the resume is
    /// a fresh key-down with its own watchdog. Every other stop must end the
    /// hold; above all, resuming after the watchdog would defeat SF-1.
    var leavesTheHoldAlive: Bool {
        switch self {
        case .routeChanged:
            return true
        case .released, .accessoryReleased, .remoteCommandToggled,
            .draggedOffButton, .disconnecting, .gestureCancelled,
            .viewDisappeared, .appBackgrounded, .audioInterrupted,
            .watchdogExpired, .transmitFailed, .accessoryLinkLost:
            return false
        }
    }

    /// Whether this stop happened *to* the operator, and so is explained on
    /// screen: unexplained, they would simply key up again.
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
/// Closures rather than a generic client: `NetworkClient`'s `associatedtype
/// Destination` would force one mode to be chosen for the app's lifetime, and
/// closures let every mode produce this one type.
///
/// Single-use: a client's `disconnect()` is terminal, so ``RadioSession`` asks
/// the factory for a fresh link on every connect.
struct RadioLink {
    /// Which network this link speaks.
    let mode: RadioMode

    /// Connects to the destination this link was built for, which is captured
    /// rather than exposed because its type belongs to a protocol library.
    let connect: @Sendable () async throws -> Void

    /// Drops the connection and shuts the client down.
    let disconnect: @Sendable () async -> Void

    /// Keys up. Throws if the client is not connected.
    let startTransmit: @Sendable () async throws -> Void

    /// Unkeys. Idempotent, and safe when not connected — the SF-2 and SF-3
    /// paths call it without being able to know the current state.
    let stopTransmit: @Sendable () async -> Void

    /// The client's transmit state, read live: the watchdog (SF-1) can unkey
    /// between two reads.
    let transmitState: @Sendable () -> TransmitState

    /// Lifecycle, watchdog and media events, already translated.
    let events: AsyncStream<RadioLinkEvent>

    /// Decoded 8 kHz mono PCM from the far end, 160 samples per 20 ms.
    let receivedAudio: AsyncStream<[Int16]>

    /// Hands one captured 20 ms frame to the client. **Called from the audio
    /// thread**: must not block or `await` (see ``CapturedFrameRelay``).
    let sendCapturedFrame: @Sendable ([Int16]) -> Void

    /// Sends one DTMF digit (FR-1.5), which is not on `NetworkClient`. Signalling,
    /// not audio: it does not key the radio. Throws whatever the client throws.
    let sendDTMF: @Sendable (Character) async throws -> Void

    /// Releases the pumps this link owns. Idempotent; called on every
    /// teardown path, including a connect that failed.
    let close: @Sendable () -> Void
}
