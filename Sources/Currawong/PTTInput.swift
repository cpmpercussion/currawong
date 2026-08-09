// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What keyed the radio.
///
/// Tracked because the three inputs do not behave the same way, and PT-4 makes
/// that the operator's problem unless the UI says so: the on-screen button and
/// a Bluetooth accessory are **momentary** — transmission lasts exactly as long
/// as the button is held — while a remote-command button is a **toggle**, and
/// an operator who does not know which one keyed them does not know whether
/// letting go will unkey them.
enum PTTSource: String, Sendable, Equatable, CaseIterable {
    /// PT-1. The on-screen button.
    case onScreen

    /// PT-2/PT-3. A learned Bluetooth LE accessory.
    case accessory

    /// PT-4. `MPRemoteCommandCenter` — a headset button or HID key.
    case remoteCommand

    /// Whether transmission ends when the button is let go. False for PT-4,
    /// which has no release edge to end on.
    var isMomentary: Bool { self != .remoteCommand }

    var label: String {
        switch self {
        case .onScreen: return "On-screen button"
        case .accessory: return "Bluetooth accessory"
        case .remoteCommand: return "Headset or remote button"
        }
    }

    /// Shown while transmitting, so "am I still keyed if I let go?" is never a
    /// question the operator has to answer from memory.
    var holdDescription: String {
        isMomentary
            ? "Transmitting while held. Let go to stop."
            : "Latched. Press the button again to stop transmitting."
    }
}

/// What a PTT input source talks to.
///
/// ``RadioSession`` is the only production conformer. The protocol exists so
/// the Bluetooth and remote-command controllers can be tested against a
/// recording double without a network client, and — more importantly — so
/// there is exactly one vocabulary for "a button was pressed", and every input
/// funnels into ``RadioSession/endTransmit(reason:)`` through it rather than
/// growing its own path to the microphone.
@MainActor
protocol PTTSink: AnyObject {
    func pttPressed(from source: PTTSource)
    func pttReleased(from source: PTTSource, reason: TransmitStopReason)

    /// PT-4. Toggle, because a remote command has no release edge.
    func pttToggled(from source: PTTSource)

    /// **SF-2.** The Bluetooth accessory link went away. Called unconditionally
    /// on link loss, whether or not the accessory was the thing that keyed:
    /// this is the "the accessory fell off the desk and the radio stayed keyed"
    /// case, and guessing about it is not worth the risk.
    func accessoryLinkLost()
}
