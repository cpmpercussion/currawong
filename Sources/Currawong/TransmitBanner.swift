// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **SF-4.** The "you are on air" strip, full bleed — red while transmitting,
/// muted otherwise.
///
/// It lives in its own file because of *where* it has to be placed rather than
/// what it draws: it sits above the pane container in ``RootView``, outside the
/// `TabView` and outside the `NavigationSplitView`, so that no amount of tab
/// switching, column collapsing or scrolling can take it off the screen. A copy
/// inside a pane would be a copy that some other pane does not have, and the
/// operator would learn that the strip is sometimes absent while transmitting —
/// which is the one thing SF-4 exists to prevent.
///
/// (The lock-screen half of SF-4 is the Live Activity, APP-3 — see
/// ``TransmitActivityController``. This is still the half that matters when the
/// app *is* on screen, and it is the whole of SF-4 on macOS and for an operator
/// who has turned Live Activities off.)
///
/// ## APP-23: it is always here, and only its colour changes
///
/// It used to be inserted into the hierarchy at key-down and removed at key-up.
/// That made keying **move every control below it down the screen — including
/// the PTT button under the operator's finger**, which is the one control that
/// must not move while it is being held. A finger that lands on a button which
/// then slides out from under it is a finger that drags off, and dragging off is
/// a release (``TransmitStopReason/draggedOffButton``).
///
/// So the strip is permanent and the *state* is carried by colour and wording
/// alone. Nothing about SF-4 is weakened by this: what makes the strip
/// unhideable is its position as a sibling of the pane container, not its coming
/// and going. What is gained beyond the layout is that "am I on air?" is now
/// answered in the same place at all times, rather than by the presence or
/// absence of something the operator has to remember the meaning of.
///
/// **Both states are two lines**, deliberately. A subtitle that appeared only
/// while transmitting would change the strip's height and reintroduce exactly
/// the motion this is here to remove.
///
/// The transmitting subtitle is PT-4's requirement: it names the input that
/// keyed the radio and says whether letting go will stop it. A latched
/// transmission that the operator believes is momentary is the way this app
/// would leave a microphone open, so the answer is on screen rather than in the
/// manual.
struct TransmitBanner: View {
    /// Whether the radio is on air. The strip is drawn either way.
    let isTransmitting: Bool

    /// The input holding the key, when one is known. `nil` while transmitting
    /// renders the generic subtitle rather than guessing at a source.
    let source: PTTSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: isTransmitting
                    ? "dot.radiowaves.left.and.right"
                    : "antenna.radiowaves.left.and.right")
                Text(isTransmitting ? "TRANSMITTING" : "RECEIVE")
                    .font(.headline.weight(.black))
                    .monospaced()
                Spacer()
                Text(isTransmitting ? "ON AIR" : "STANDBY")
                    .font(.headline.weight(.black))
            }
            Text(subtitle)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(isTransmitting ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isTransmitting ? AnyShapeStyle(Color.red) : AnyShapeStyle(.quaternary))
        // The colour change is worth animating — it is the state change itself,
        // and it moves nothing. The strip's frame is identical in both states.
        .animation(.easeInOut(duration: 0.15), value: isTransmitting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Never empty, in either state: the second line is what keeps the two
    /// states the same height.
    private var subtitle: String {
        guard isTransmitting else { return "The transmitter is not keyed." }
        return source?.holdDescription ?? "The transmitter is keyed."
    }

    /// What VoiceOver reads, and what the tests assert on. Not private: SF-4 is
    /// "the operator can tell whether they are on air", and for an operator
    /// using VoiceOver this string *is* the requirement, so it is worth a test
    /// of its own rather than being inspected through a rendered view.
    var accessibilityDescription: String {
        guard isTransmitting else { return "Not transmitting. Standby." }
        return "Transmitting. On air. \(subtitle)"
    }
}

#Preview {
    VStack(spacing: 0) {
        TransmitBanner(isTransmitting: true, source: .onScreen)
        TransmitBanner(isTransmitting: false, source: nil)
        Spacer()
    }
}
