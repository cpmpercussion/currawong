// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A label above its field. A `Form` would give this for free on iOS and
/// something quite different on macOS; laying it out by hand is the cheapest way
/// to have one screen rather than two.
///
/// It lived inside ``ConnectFormView`` as a private type until the settings
/// screen (APP-12) needed the same rows. Promoted rather than copied: two
/// spellings of one field layout is how two screens in one app come to look like
/// two apps — and unlike `paneColumn()` in `RootView`, which is deliberately
/// file-scoped because it is a layout decision about panes, this is a control.
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
            // nothing else, so VoiceOver announced "node.example.org, text
            // field" with no way to know it was the host. Found while writing
            // the on-air UI test (BU-8), which could not find a field called
            // "Host" either, for exactly the same reason: if a screen reader
            // cannot name the controls, nothing else can either.
            content
                .accessibilityLabel(label)
        }
    }
}
