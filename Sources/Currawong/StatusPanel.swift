// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// What the link is doing, in one box — laid out like a radio's front panel.
///
/// **The destination is the headline**, the way a VFO frequency is the biggest
/// thing on a rig and the mode is a small box beside it. That was not true of
/// the first version: it led with the *connection state*, so the panel said
/// "Connected" in bold without ever saying connected to what, while the answer
/// sat in the channel list beside it — and in the compact layout the channel
/// list is a different tab, so the answer was nowhere.
///
/// ## What is not here any more
///
/// This box used to be the pane split's answer to "where did the diagnostics
/// go", and carried every loose line from the old single column. Two of them
/// have since stopped earning the space:
///
/// * **The transmit watchdog** is a *setting*, not a state — APP-12 moved it to
///   the settings screen, and echoing it here only restated a number that
///   cannot change while it is being read. The form of SF-1 that would help an
///   operator is the live one, seconds remaining before it unkeys, and that
///   belongs on the transmit banner where it is only shown while it is
///   counting. ``ActivityKitPresenter`` already computes that deadline for the
///   Live Activity; the banner does not show it yet.
/// * **The codec** is worth knowing exactly once, on first contact with an
///   unfamiliar node, and is stale the moment the link drops. So it rides on
///   the address line while connected instead of holding a line of its own.
///
/// What stayed are the two *events* — why the last transmission stopped, why
/// the link went away. Those are transient, they answer a question the operator
/// is actually asking at the moment they appear, and neither is visible from
/// anywhere else in the app.
struct StatusPanel: View {
    @ObservedObject var session: RadioSession

    /// **APP-18.** The PTT accessory light, or `nil` where there is no room for
    /// one — the settings screen shows this panel with its own accessory section
    /// a scroll below it.
    ///
    /// Passed as a value rather than observed here, because the two controllers
    /// it is computed from are already observed by ``SessionPane``: a second
    /// observer of the same objects buys nothing and makes this panel need to
    /// know about Bluetooth.
    let accessory: AccessoryIndicator?

    private var status: TransmitStatusPresentation {
        TransmitStatusPresentation(state: session.transmitState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(destinationName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                modeBadge

                Spacer(minLength: 8)

                receiveIndicator
            }

            Text(addressLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // The link state and what can key it, on one line: the two things
            // that decide whether pressing a button will put the operator on
            // air, side by side and never more than a glance apart.
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionColour)
                        .frame(width: 8, height: 8)
                    Text(session.connection.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                if let accessory {
                    Spacer(minLength: 8)
                    AccessoryIndicatorView(indicator: accessory)
                }
            }

            if status.detail != session.connection.label {
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let reason = session.lastStopReason, reason.isUnexpected, session.safetyNotice == nil {
                detailLine("Last transmission ended: \(reason.rawValue).")
            }

            // Why the *link* went away, as opposed to why a transmission did.
            // Only interesting once it has: while a call is up, the previous
            // call's ending is noise.
            if let reason = session.lastDisconnectReason, !session.connection.isConnected {
                detailLine("Last disconnect: \(reason)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12)))
    }

    /// The channel the app would dial, named the way the operator named it.
    ///
    /// Taken from the working copy rather than the connected link, so an edit in
    /// progress is reflected here — this says where the PTT button would go,
    /// which is the question a front panel answers.
    private var destinationName: String {
        let name = session.settings.displayName
        return name.isEmpty ? "No channel" : name
    }

    /// The address under the name, plus the codec while there is a live one to
    /// report. See the note on the type for why the codec lives here.
    private var addressLine: String {
        let address = session.settings.addressDescription
        guard session.connection.isConnected, let codec = session.negotiatedCodec else {
            return address
        }
        return "\(address) · \(codec)"
    }

    /// The mode, boxed, in the place a rig puts FM / SSB / DMR. Same capsule as
    /// the channel list row, so a channel reads the same in both places.
    private var modeBadge: some View {
        Text(session.settings.mode.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.gray.opacity(0.2)))
            .accessibilityLabel("Mode: \(session.settings.mode.displayName)")
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Received-audio activity. Driven by a `TimelineView` rather than a timer
    /// so the view model stays free of clocks: it answers "is audio arriving
    /// as of *this* instant", and the timeline supplies instants.
    ///
    /// On a shared channel the session also knows *who* — `receivingFrom` is M17
    /// only, and `nil` everywhere else, so the callsign appears when there is one
    /// and the indicator says no more than it knows.
    private var receiveIndicator: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let active = session.isReceivingAudio(asOf: context.date)
            HStack(spacing: 6) {
                Image(systemName: active ? "waveform" : "waveform.slash")
                    .foregroundStyle(active ? Color.green : Color.secondary)
                Text(indicatorText(active: active))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(active: active))
        }
    }

    private func indicatorText(active: Bool) -> String {
        if let station = session.receivingFrom { return station }
        return active ? "Audio in" : "Quiet"
    }

    private func accessibilityText(active: Bool) -> String {
        if let station = session.receivingFrom { return "Receiving from \(station)" }
        return active ? "Receiving audio" : "No audio arriving"
    }

    private var connectionColour: Color {
        switch session.connection {
        case .disconnected: return .secondary
        case .connecting, .disconnecting: return .orange
        case .connected: return .green
        }
    }
}
