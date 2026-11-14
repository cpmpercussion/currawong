// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **SF-4.** The "you are on air" strip, full bleed — red while transmitting,
/// muted otherwise. The on-screen half of SF-4; the lock-screen half is
/// ``TransmitActivityController``.
///
/// Sits above the pane container in ``RootView``, outside every tab, column
/// and scroll view, so nothing can take it off screen.
///
/// Always present, at the same height in every state (the tests pin it): if it
/// appeared at key-down it would move the PTT button under a held finger, which
/// is a drag-off release (``TransmitStopReason/draggedOffButton``).
struct TransmitBanner: View {
    /// Whether the radio is on air. The strip is drawn either way.
    let isTransmitting: Bool

    /// DEBUG only (BU-15): key-downs in the current or last hold, see
    /// ``RadioSession/keyDownsInCurrentHold``. Exposed as the accessibility
    /// *value*, leaving the SF-4 label untouched, so a UI test can read it after
    /// release.
    var keyDownsInHold: Int = 0

    /// DEBUG only (BU-15): the route-change trace, see
    /// ``RadioSession/routeSignalsDuringPreparation``.
    var routeTrace: String = ""


    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isTransmitting
                ? "dot.radiowaves.left.and.right"
                : "antenna.radiowaves.left.and.right")
            Text(isTransmitting ? "TRANSMITTING" : "RECEIVE")
                .font(.headline.weight(.black))
                .monospaced()
            Spacer()
            Text(trailingWord)
                .font(.headline.weight(.black))
        }
        .foregroundStyle(isTransmitting ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isTransmitting ? AnyShapeStyle(Color.red) : AnyShapeStyle(.quaternary))
        .animation(.easeInOut(duration: 0.15), value: isTransmitting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        // The PTT button reports the same words, so tests address this by id.
        .accessibilityIdentifier("session.transmitStrip")
        // Not in a shipping build: it is an instrument, not an interface.
        #if DEBUG
            .accessibilityValue("keyDowns=\(keyDownsInHold) \(routeTrace)")
        #endif
    }

    /// The right-hand word. Internal so it can be tested as a value.
    var trailingWord: String {
        isTransmitting ? "ON AIR" : "STANDBY"
    }

    /// What VoiceOver reads — for a VoiceOver user this string *is* SF-4, so it
    /// is internal and tested. Longer than the strip, since it replaces the red.
    var accessibilityDescription: String {
        guard isTransmitting else { return "Not transmitting. Standby." }
        return "Transmitting. On air. \(RadioSession.holdDescription)"
    }
}

#Preview {
    VStack(spacing: 0) {
        TransmitBanner(isTransmitting: true)
        TransmitBanner(isTransmitting: false)
        Spacer()
    }
}
