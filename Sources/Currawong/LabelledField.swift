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
            content
        }
    }
}
