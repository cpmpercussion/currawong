// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **APP-26.** The acknowledgements, on the settings screen.
///
/// ## Why it is here and not behind a link
///
/// LGPL-2.1 §6 asks for a *prominent* notice that the library is used and is
/// covered by that licence. A URL in a README is not a notice given to the
/// person running the application, and this app has no other screen an operator
/// opens in order to read about the app. So it is the last section of Settings —
/// findable, and shipped inside the binary that carries the obligation.
///
/// ## Why the notices are collapsed
///
/// Four licence notices unrolled would push the sections above them — the
/// watchdog among them — off the top of a screen that exists to configure a
/// transmitter. Each entry states the thing §6 requires in the row itself (what
/// it is, whose it is, which licence, how it is linked); the disclosure holds
/// the notice text. Nothing that must be *displayed* is hidden behind a tap: the
/// licence name and the fact of its use are always visible.
struct AboutPane: View {
    /// Expanded by default for the one entry with an obligation attached, so
    /// the LGPL notice is on screen without being asked for.
    @State private var expanded: Set<String> = ["Codec2"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Currawong \(Acknowledgements.appVersion)")
                .font(.headline)

            Text(
                "A client for amateur radio VoIP networks. Currawong is open source under the "
                + "Apache License 2.0.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link("Source code", destination: URL(string: Acknowledgements.apache2SourceURL)!)
                .font(.caption)

            Divider()
                .padding(.vertical, 2)

            Text("Open source licences")
                .font(.subheadline.weight(.semibold))

            ForEach(Acknowledgements.components) { component in
                entry(component)
            }

            // Said once, about the set, because it is a statement about how the
            // app is assembled rather than about any one component.
            Text(Acknowledgements.relinkingNotice)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func entry(_ component: Acknowledgement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if expanded.contains(component.id) {
                    expanded.remove(component.id)
                } else {
                    expanded.insert(component.id)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(
                        systemName: expanded.contains(component.id)
                            ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(component.name) \(component.version)")
                            .font(.callout.weight(.medium))
                        Text("\(component.licence) · \(component.linkage.description)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The row is a disclosure control, and on macOS a plain-styled
            // Button in a VStack is not announced as one otherwise.
            .accessibilityIdentifier("about.\(component.id)")
            .accessibilityHint("Shows the licence notice")

            if expanded.contains(component.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(component.copyright)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(component.notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let url = URL(string: component.sourceURL) {
                        Link(component.sourceURL, destination: url)
                            .font(.caption2)
                    }
                }
                .padding(.leading, 18)
                .padding(.bottom, 4)
            }
        }
    }
}
