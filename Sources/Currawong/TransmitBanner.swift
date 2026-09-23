// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **SF-4.** The "you are on air" strip, full bleed — red while transmitting,
/// muted otherwise.
///
/// In its own file because of where it has to sit: above the pane container in
/// ``RootView``, outside the `TabView` and the `NavigationSplitView`, so no tab
/// switch, column collapse or scroll can take it off screen. A copy inside a
/// pane would be a copy some other pane lacks, and the one thing SF-4 exists to
/// prevent is the strip being absent while transmitting.
///
/// (The lock-screen half of SF-4 is the Live Activity, APP-3 — see
/// ``TransmitActivityController``. This is the half that matters while the app
/// is on screen, and the whole of SF-4 on macOS or with Live Activities off.)
///
/// **Always present; only colour and wording change (APP-23).** Inserting and
/// removing the strip at key-down/key-up would move every control below it,
/// including the PTT button under the operator's finger — a button that slides
/// out from under a held finger is a drag-off release
/// (``TransmitStopReason/draggedOffButton``). Keeping the strip permanent keeps
/// the PTT button still while held.
///
/// One line in both states: a subtitle restating the word beside it teaches the
/// eye to skip the strip.
///
/// **`source` exists for PT-4.** A latched transmission is the one case where
/// letting go does not stop the radio, and an operator who believes a latched
/// key is momentary is how this app leaves a microphone open. The latched case
/// says so in the space "ON AIR" already occupies; momentary sources say
/// nothing extra, because TRANSMITTING is the whole truth for them.
///
/// The height is identical in every state — the tests pin it, and the layout
/// depends on it.
struct TransmitBanner: View {
    /// Whether the radio is on air. The strip is drawn either way.
    let isTransmitting: Bool

    /// The input holding the key, when one is known. Read only to answer PT-4's
    /// question — whether letting go stops it — so an unknown source is treated
    /// as momentary, which is the presentation that claims least.
    let source: PTTSource?

    /// **`BU-15`, DEBUG only.** How many times the radio was keyed during the
    /// current or most recent hold — see ``RadioSession/keyDownsInCurrentHold``.
    ///
    /// Reaches the screen as this element's accessibility *value*, leaving the
    /// label VoiceOver reads (which SF-4's tests pin) untouched. This is the
    /// only way an XCUITest can count key-downs inside a hold, since the test
    /// cannot look at the app mid-gesture and the count must be readable after
    /// release.
    ///
    /// Defaulted: every caller but ``RootView`` is a preview or a layout test.
    var keyDownsInHold: Int = 0

    /// The rest of `BU-15`'s trace, DEBUG only: where the route changes landed
    /// and how long the wait took. See
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
        // The colour change is worth animating — it is the state change itself,
        // and it moves nothing. The strip's frame is identical in both states.
        .animation(.easeInOut(duration: 0.15), value: isTransmitting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        // Named so a UI test can address *this* element. The PTT button reports
        // the same fact in its own accessibility value, so a query written
        // against the words alone can land on either.
        .accessibilityIdentifier("session.transmitStrip")
        // Not in a shipping build: it is an instrument, not an interface.
        #if DEBUG
            .accessibilityValue("keyDowns=\(keyDownsInHold) \(routeTrace)")
        #endif
    }

    /// **PT-4.** Whether the key is held by something that will not release it
    /// when the operator lets go. An unknown source is not treated as latched:
    /// only ``PTTSource/remoteCommand`` actually latches.
    private var isLatched: Bool {
        isTransmitting && source?.isMomentary == false
    }

    /// The right-hand word. "LATCHED" replaces "ON AIR" rather than joining it:
    /// it is the more urgent of the two, and the colour has already said the
    /// radio is on air.
    ///
    /// Not private, so PT-4's one drawn fact can be tested as a value rather
    /// than read out of a rendered view.
    var trailingWord: String {
        guard isTransmitting else { return "STANDBY" }
        return isLatched ? "LATCHED" : "ON AIR"
    }

    /// What VoiceOver reads, and what the tests assert on. Not private: for an
    /// operator using VoiceOver, this string *is* SF-4, so it gets a test of
    /// its own rather than being inspected through a rendered view.
    ///
    /// Longer than the strip, deliberately: a screen reader has no colour, so
    /// these words carry what the eye gets from red — including PT-4's full
    /// sentence, worth the extra second spoken though it was clutter drawn.
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
