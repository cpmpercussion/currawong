// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// What the link is doing, in one box laid out like a radio's front panel: the
/// destination as the headline, the mode boxed beside it, the address (plus
/// the codec while connected), the link state, and why the last transmission
/// or link ended.
///
/// The SF-1 timeout is a setting and is shown on the settings screen, not here.
struct StatusPanel: View {
    @ObservedObject var session: RadioSession

    /// The PTT accessory light, or `nil` where the screen has its own accessory
    /// section. A value, so this panel need not observe the Bluetooth
    /// controllers ``SessionPane`` already observes.
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

            // The link state and what can key it, side by side.
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

            // Why the last link ended; hidden while a call is up.
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

    /// The channel the app would dial. From the working copy, so an edit in
    /// progress shows here.
    private var destinationName: String {
        let name = session.settings.displayName
        return name.isEmpty ? "No channel" : name
    }

    /// The address, plus the codec while connected.
    private var addressLine: String {
        let address = session.settings.addressDescription
        guard session.connection.isConnected, let codec = session.negotiatedCodec else {
            return address
        }
        return "\(address) · \(codec)"
    }

    /// The mode, in the same capsule as the channel list row.
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

    /// Received-audio activity, and the sender's callsign when known (M17
    /// only). A `TimelineView` supplies the instants, so the view model needs
    /// no clock.
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
