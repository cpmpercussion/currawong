// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **SF-1, SF-2, SF-3.** The notice that says something stopped the operator
/// transmitting, and why.
///
/// It is dismissible and it does not time out. Every notice this shows is the
/// record of a transmission that ended without the operator ending it — the
/// watchdog, an audio interruption, a route change, an accessory that went away
/// mid-press — and an operator who was looking at the radio rather than the
/// screen has to be able to find out what happened after the fact. A banner
/// that faded on its own would be a banner that is reliably gone by the time
/// anybody looks.
///
/// The pane split moved this out of ``RootView`` unchanged: it renders a notice
/// and reports a dismissal, and the session remains the only thing that decides
/// when there is one.
struct SafetyBanner: View {
    let notice: RadioSession.SafetyNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(notice.message)
                    .font(.footnote)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.15)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch notice.kind {
        case .transmitWatchdog: return "Transmit watchdog stopped you"
        case .audioInterruption: return "Audio interrupted"
        case .routeChange: return "Audio route changed"
        case .accessoryLinkLost: return "Accessory disconnected"
        }
    }
}

/// Inbound media the client is discarding — a codec nobody negotiated, video,
/// anything the app cannot play.
///
/// Quieter than ``SafetyBanner`` on purpose: nothing is wrong with the radio,
/// but "the link is up and I hear nothing" has a cause, and this is it.
struct MediaWarningLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "waveform.badge.exclamationmark")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
