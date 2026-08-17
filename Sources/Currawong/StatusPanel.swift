// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// What the link is doing, in one box.
///
/// This is the pane split's answer to "where did the diagnostics go": every line
/// that used to sit loose in ``RootView``'s single column is here, and this box
/// is placed in the part of the session pane that is on screen without
/// scrolling. The panes moved; the state did not become optional.
///
/// The lines below the connection state are deliberately unglamorous. They are
/// the questions asked during a first contact with an unfamiliar node — what
/// codec did it agree to, how long will the watchdog let me talk, why did the
/// last transmission stop, why did the link go away — and every one of them is
/// obvious in a packet capture and invisible from the app otherwise.
struct StatusPanel: View {
    @ObservedObject var session: RadioSession

    private var status: TransmitStatusPresentation {
        TransmitStatusPresentation(state: session.transmitState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColour)
                    .frame(width: 10, height: 10)
                Text(session.connection.label)
                    .font(.headline)
                Spacer()
                receiveIndicator
            }

            Text(status.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let codec = session.negotiatedCodec {
                detailLine("Codec: \(codec)")
            }

            detailLine("Transmit watchdog: \(session.transmitTimeout.wholeSeconds) s")

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
