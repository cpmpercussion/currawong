// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What keyed the radio. The on-screen button and a Bluetooth accessory are
/// momentary; a remote command is a toggle, so the UI must say which (PT-4).
enum PTTSource: String, Sendable, Equatable, CaseIterable {
    /// PT-1. The on-screen button.
    case onScreen

    /// PT-2/PT-3. A learned Bluetooth LE accessory.
    case accessory

    /// PT-4. `MPRemoteCommandCenter` — a headset button or HID key.
    case remoteCommand

    /// Whether letting go ends transmission. False for PT-4.
    var isMomentary: Bool { self != .remoteCommand }

    var label: String {
        switch self {
        case .onScreen: return "On-screen button"
        case .accessory: return "Bluetooth accessory"
        case .remoteCommand: return "Headset or remote button"
        }
    }

    /// Shown while transmitting, so the operator knows whether letting go
    /// unkeys.
    var holdDescription: String {
        isMomentary
            ? "Transmitting while held. Let go to stop."
            : "Latched. Press the button again to stop transmitting."
    }
}

/// What a PTT input talks to: ``RadioSession`` in production, a recording
/// double in tests. Every input's release funnels through it into
/// ``RadioSession/endTransmit(reason:)``, never a path of its own.
@MainActor
protocol PTTSink: AnyObject {
    func pttPressed(from source: PTTSource)
    func pttReleased(from source: PTTSource, reason: TransmitStopReason)

    /// PT-4. Toggle, because a remote command has no release edge.
    func pttToggled(from source: PTTSource)

    /// **SF-2.** The accessory link went away. Called on every link loss,
    /// whether or not the accessory keyed: guessing is not worth the risk.
    func accessoryLinkLost()
}
