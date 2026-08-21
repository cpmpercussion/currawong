// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **APP-18.** Whether something other than the on-screen button can key the
/// radio, as one glyph and three words, for the status panel.
///
/// A pure value like ``SessionLinkControl`` and ``TransmitStatusPresentation``,
/// and for the same reason: which of these an operator is looking at is a
/// decision worth testing without a view.
///
/// ## Why this replaced a row
///
/// It used to be ``AccessoryStatusRow`` at the bottom of the session pane — an
/// icon, two lines of text and a chevron into the accessory screen. The row's
/// own rationale was right and is kept here: *"is my PTT fob still connected?"*
/// is asked from the screen the operator is looking at **while transmitting**,
/// not from the screen that configures it. What did not belong on that screen
/// was the way *in* to the configuration, which APP-12 had already given to
/// Settings, and the vertical space — a full row for a thing that is a light on
/// a front panel.
///
/// ## Three states, not two
///
/// The state that matters is the third one. **Nothing configured** is dim and
/// says so. **Configured and connected** is solid, and is the ordinary case
/// nobody reads. **Configured and lost** is loud, because it is SF-2: BLE link
/// loss has already dropped transmit, and an operator whose fob just stopped
/// keying the radio needs to be told why by the screen they are already looking
/// at. A greyed-out icon cannot carry that, and carrying it is the whole reason
/// the indicator exists.
///
/// ``Emphasis/working`` is a fourth, and is not one of the three: it is the
/// pairing path — scanning and connecting *towards* an accessory — which is
/// neither lost nor ready and is not a safety message.
struct AccessoryIndicator: Equatable {
    /// How loudly to draw it. Maps to a colour in the view and to nothing else;
    /// the words carry the meaning for anyone who cannot see the colour.
    enum Emphasis: Equatable {
        /// Nothing is configured. There is no accessory to have lost.
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

    /// The whole story, including the reason the link state carries when it has
    /// one — the panel has room for three words, VoiceOver does not have that
    /// limit, and the operator asking this question is the one who needs the
    /// detail.
    let accessibilityLabel: String

    let emphasis: Emphasis

    /// - Parameters:
    ///   - linkState: the BLE controller's link state.
    ///   - isAccessoryConfigured: whether a mapping has been learned — i.e.
    ///     whether there is an accessory this app expects to be connected to.
    ///     Not the same as the link being up, and it is the difference between
    ///     "nothing configured" and "lost".
    ///   - isAccessoryKeyed: whether the accessory is holding the key now.
    ///   - isRemoteCommandEnabled: PT-4. A headset button is a configured input
    ///     too, and it needs no link, so it is the one thing that can make this
    ///     solid with no accessory at all.
    init(
        linkState: BLEPTTController.LinkState,
        isAccessoryConfigured: Bool,
        isAccessoryKeyed: Bool,
        isRemoteCommandEnabled: Bool
    ) {
        // Keyed first: while a button is held, what it is doing outranks how it
        // got connected.
        if isAccessoryKeyed {
            systemImage = "dot.radiowaves.left.and.right"
            title = "Accessory keyed"
            accessibilityLabel = "PTT accessory keyed"
            emphasis = .solid
            return
        }

        guard isAccessoryConfigured else {
            // No accessory to lose. `unavailable` is not shouted about here:
            // Bluetooth being off matters to an operator who has a fob, and to
            // nobody else.
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
        case .connected:
            systemImage = "dot.circle.fill"
            title = "Accessory ready"
            emphasis = .solid
        case .scanning, .connecting:
            systemImage = "antenna.radiowaves.left.and.right"
            title = "Linking…"
            emphasis = .working
        case .reconnecting, .failed, .unavailable, .noAccessory:
            // Every one of these is "configured, and cannot key the radio".
            // `noAccessory` reaches here only if the mapping outlived the
            // controller's own state, which is still that same fact.
            systemImage = "exclamationmark.triangle.fill"
            title = "Accessory lost"
            emphasis = .loud
        }

        accessibilityLabel = "PTT accessory: \(linkState.label)"
    }
}

/// The indicator itself: a glyph and its three words, in the status panel.
///
/// Non-interactive on purpose. Configuration is on the settings screen (APP-12),
/// and a tappable light on a front panel invites the operator to press the thing
/// that reports their PTT state while they are using it.
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
