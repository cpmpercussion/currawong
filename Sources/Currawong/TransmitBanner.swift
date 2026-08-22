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
/// **One line, in both states.** It carried a subtitle at first — "Transmitting
/// while held", "The transmitter is not keyed" — which the operator asked for
/// and then asked to have removed, rightly: both restate what the word beside
/// them already says, and a safety strip that spends half its height saying
/// nothing teaches the eye to skip it.
///
/// **The exception is PT-4, and it is why `source` is still here.** A *latched*
/// transmission is the one case where letting go does not stop the radio, and an
/// operator who believes a latched key is momentary is how this app would leave
/// a microphone open. So the latched case says so, in the space "ON AIR" already
/// occupies — the fact, not a sentence about the fact. Momentary sources say
/// nothing extra, because for them the word TRANSMITTING is the whole truth.
///
/// The height is the same in every state either way. That is what the tests
/// pin, and it is the property the layout depends on.
struct TransmitBanner: View {
    /// Whether the radio is on air. The strip is drawn either way.
    let isTransmitting: Bool

    /// The input holding the key, when one is known. Read only to answer PT-4's
    /// question — whether letting go stops it — so an unknown source is treated
    /// as momentary, which is the presentation that claims least.
    let source: PTTSource?

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
        // The colour change is worth animating — it is the state change itself,
        // and it moves nothing. The strip's frame is identical in both states.
        .animation(.easeInOut(duration: 0.15), value: isTransmitting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// **PT-4.** Whether the key is held by something that will not release it
    /// when the operator lets go. An unknown source is not treated as latched:
    /// only ``PTTSource/remoteCommand`` actually latches, and claiming it of an
    /// unknown input would make the word meaningless where it matters.
    private var isLatched: Bool {
        isTransmitting && source?.isMomentary == false
    }

    /// The right-hand word. "LATCHED" replaces "ON AIR" rather than joining it,
    /// because it is the more urgent of the two and the strip's colour has
    /// already said the radio is on air.
    ///
    /// Not private, so PT-4's one drawn fact can be tested as a value: reading
    /// it out of a rendered view would test SwiftUI rather than the rule.
    var trailingWord: String {
        guard isTransmitting else { return "STANDBY" }
        return isLatched ? "LATCHED" : "ON AIR"
    }

    /// What VoiceOver reads, and what the tests assert on. Not private: SF-4 is
    /// "the operator can tell whether they are on air", and for an operator
    /// using VoiceOver this string *is* the requirement, so it is worth a test
    /// of its own rather than being inspected through a rendered view.
    ///
    /// **Longer than the strip, deliberately.** A glance at red is instant and a
    /// screen reader has no colour, so what the eye gets from the background,
    /// VoiceOver gets from these words — including PT-4's full sentence, which
    /// is worth the extra second when spoken and was clutter when drawn.
    var accessibilityDescription: String {
        guard isTransmitting else { return "Not transmitting. Standby." }
        guard let source else { return "Transmitting. On air." }
        return "Transmitting. On air. \(source.holdDescription)"
    }
}

#Preview {
    VStack(spacing: 0) {
        TransmitBanner(isTransmitting: true, source: .onScreen)
        TransmitBanner(isTransmitting: false, source: nil)
        Spacer()
    }
}
