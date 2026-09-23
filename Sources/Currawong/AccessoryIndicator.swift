// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Whether something other than the on-screen button can key the radio, as a
/// glyph and a few words for the status panel (APP-18). A pure value, so the
/// choice is testable without a view.
///
/// Nothing configured is dim; configured and connected is solid; **configured
/// and lost is loud**, because SF-2 has already dropped transmit and the
/// operator needs to see why on the screen they are using. ``Emphasis/working``
/// is pairing or connecting, not a safety message.
struct AccessoryIndicator: Equatable {
    /// How loudly to draw it: a colour only; the words carry the meaning.
    enum Emphasis: Equatable {
        /// Nothing is configured.
        case dim
        /// Configured and usable, or keyed right now.
        case solid
        /// On the way to an accessory: pairing, or a first connect.
        case working
        /// **Configured and not usable.** SF-2.
        case loud
    }

    let systemImage: String

    /// Short enough for one line beside the connection state.
    let title: String

    /// The full story for VoiceOver, including the link state's reason.
    let accessibilityLabel: String

    let emphasis: Emphasis

    /// - Parameters:
    ///   - linkState: the BLE controller's link state.
    ///   - isAccessoryConfigured: whether a mapping has been learned — what
    ///     separates "nothing configured" from "lost".
    ///   - isAccessoryKeyed: whether the accessory is holding the key now.
    ///   - isRemoteCommandEnabled: PT-4; a headset button needs no link.
    ///   - isButtonVerified: see `BLEPTTController.isButtonVerified`. No
    ///     default, so a call site cannot forget it and show "Accessory ready"
    ///     over an unproven button.
    init(
        linkState: BLEPTTController.LinkState,
        isAccessoryConfigured: Bool,
        isAccessoryKeyed: Bool,
        isRemoteCommandEnabled: Bool,
        isButtonVerified: Bool
    ) {
        // Keyed outranks everything.
        if isAccessoryKeyed {
            systemImage = "dot.radiowaves.left.and.right"
            title = "Accessory keyed"
            accessibilityLabel = "PTT accessory keyed"
            emphasis = .solid
            return
        }

        guard isAccessoryConfigured else {
            // No accessory to lose, so Bluetooth being off is not news.
            systemImage = isRemoteCommandEnabled ? "headphones" : "dot.circle"
            title = isRemoteCommandEnabled ? "Headset PTT" : "No accessory"
            accessibilityLabel =
                isRemoteCommandEnabled
                ? "PTT: \(PTTSource.remoteCommand.label)"
                : "No PTT accessory set up"
            emphasis = isRemoteCommandEnabled ? .solid : .dim
            return
        }

        switch linkState {
        case .connected where !isButtonVerified:
            // A connection is not a working button (BU-14). Not a warning:
            // usually the first press proves it. Its own VoiceOver label, since
            // "connected" is the claim being avoided.
            systemImage = "dot.circle"
            title = "Accessory untested"
            emphasis = .working
            accessibilityLabel =
                "PTT accessory: connected, but nothing has arrived from it yet — "
                + "the button is untested"
            return
        case .connected:
            systemImage = "dot.circle.fill"
            title = "Accessory ready"
            emphasis = .solid
        case .scanning, .connecting:
            systemImage = "antenna.radiowaves.left.and.right"
            title = "Linking…"
            emphasis = .working
        case .reconnecting, .failed, .unavailable, .noAccessory:
            // All mean "configured, and cannot key the radio".
            systemImage = "exclamationmark.triangle.fill"
            title = "Accessory lost"
            emphasis = .loud
        }

        accessibilityLabel = "PTT accessory: \(linkState.label)"
    }
}

/// The indicator in the status panel. Deliberately not tappable: configuring
/// is on the settings screen.
struct AccessoryIndicatorView: View {
    let indicator: AccessoryIndicator

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: indicator.systemImage)
                .foregroundStyle(colour)
            Text(indicator.title)
                .font(.caption)
                .foregroundStyle(indicator.emphasis == .loud ? colour : .secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(indicator.accessibilityLabel)
        .accessibilityIdentifier("session.accessoryIndicator")
    }

    private var colour: Color {
        switch indicator.emphasis {
        case .dim: return .secondary
        case .solid: return .green
        case .working: return .orange
        case .loud: return .red
        }
    }
}
