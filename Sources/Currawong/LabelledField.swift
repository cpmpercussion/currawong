// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A label above its field. A `Form` would give this for free on iOS and
/// something quite different on macOS; laying it out by hand is the cheapest way
/// to have one screen rather than two.
///
/// Shared with the settings screen (APP-12) rather than kept private to
/// ``ConnectFormView``: two spellings of one field layout is how two screens in
/// one app come to look like two apps.
struct LabelledField<Content: View>: View {
    let label: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                // Decorative once the field below carries the same name:
                // without this VoiceOver reads the label, then the field, and
                // says the word twice.
                .accessibilityHidden(true)

            // A `Label` above a `TextField` is a visual association and not an
            // accessible one — SwiftUI gives the field its *placeholder* and
            // nothing else, so without this VoiceOver announces "node.example.org,
            // text field" with no way to know it is the host (BU-8). If a screen
            // reader cannot name the controls, a UI test looking for a field by
            // name cannot either.
            content
                .accessibilityLabel(label)
        }
    }
}
