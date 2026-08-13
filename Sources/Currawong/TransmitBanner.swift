// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **SF-4.** The "you are on air" banner, full bleed and red.
///
/// It lives in its own file because of *where* it has to be placed rather than
/// what it draws: it sits above the pane container in ``RootView``, outside the
/// `TabView` and outside the `NavigationSplitView`, so that no amount of tab
/// switching, column collapsing or scrolling can take it off the screen. A copy
/// inside a pane would be a copy that some other pane does not have, and the
/// operator would learn that the banner is sometimes absent while transmitting —
/// which is the one thing SF-4 exists to prevent.
///
/// (The lock-screen half of SF-4 is APP-3's Live Activity.)
///
/// The second line is PT-4's requirement: it names the input that keyed the
/// radio and says whether letting go will stop it. A latched transmission that
/// the operator believes is momentary is the way this app would leave a
/// microphone open, so the answer is on screen rather than in the manual.
struct TransmitBanner: View {
    /// The input holding the key, when one is known. `nil` renders the banner
    /// without its explanatory line rather than guessing at a source.
    let source: PTTSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("TRANSMITTING")
                    .font(.headline.weight(.black))
                    .monospaced()
                Spacer()
                Text("ON AIR")
                    .font(.headline.weight(.black))
            }
            if let source {
                Text(source.holdDescription)
                    .font(.caption.weight(.medium))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            source.map { "Transmitting. On air. \($0.holdDescription)" }
                ?? "Transmitting. On air.")
    }
}

#Preview {
    VStack(spacing: 0) {
        TransmitBanner(source: .onScreen)
        Spacer()
    }
}
