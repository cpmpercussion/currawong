// SPDX-License-Identifier: Apache-2.0

import RadioCore
import SwiftUI

/// The whole app, for now: connection state, the connect form, and the
/// on-screen momentary PTT (PT-1).
///
/// Generic over the client for the same reason ``RadioSession`` is — the view
/// model's type parameter has to go somewhere, and it is not going to be
/// `IAX2Client` anywhere outside the composition root.
///
/// This view owns three of the release paths (SF-3 and PT-1's "must not get
/// stuck"), and they are all here rather than scattered:
///
/// * **`scenePhase` leaving `.active`** — backgrounded, or merely covered by
///   the control centre. Both unkey.
/// * **`onDisappear`** — this view leaving the hierarchy.
/// * **the PTT button's own gesture** — touch-up, drag-off and cancellation,
///   handled in ``PushToTalkButton``.
///
/// The other two — audio interruption/route change and the SF-1 watchdog —
/// live in the view model, because they arrive from streams rather than from
/// SwiftUI.
struct RootView<Client: NetworkClient>: View {
    @ObservedObject var session: RadioSession<Client>

    @Environment(\.scenePhase) private var scenePhase

    private var status: TransmitStatusPresentation {
        TransmitStatusPresentation(state: session.transmitState)
    }

    var body: some View {
        VStack(spacing: 0) {
            if status.isTransmitting {
                transmitBanner
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let notice = session.safetyNotice {
                        safetyBanner(notice)
                    }
                    if let warning = session.mediaWarning {
                        warningLine(warning)
                    }
                    statusPanel

                    PushToTalkButton(
                        isEnabled: session.connection.isConnected,
                        isTransmitting: session.isTransmitting,
                        isKeyDown: session.isKeyDown,
                        onPress: { session.beginTransmit() },
                        onRelease: { session.endTransmit(reason: $0) })

                    Divider()

                    ConnectFormView(
                        settings: $session.settings,
                        secret: $session.secret,
                        isEditable: session.connection == .disconnected,
                        connectTitle: connectTitle,
                        isBusy: session.connection.isBusy,
                        connectAction: { Task { await session.toggleConnection() } })
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .task { session.start() }
        .onChange(of: scenePhase) { phase in
            session.setForeground(phase == .active)
        }
        .onDisappear { session.viewDisappeared() }
        .alert(
            session.alert?.title ?? "",
            isPresented: Binding(
                get: { session.alert != nil },
                set: { if !$0 { session.dismissAlert() } }),
            presenting: session.alert
        ) { _ in
            Button("OK", role: .cancel) { session.dismissAlert() }
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: - Pieces

    private var connectTitle: String {
        switch session.connection {
        case .disconnected: return "Connect"
        case .connecting: return "Connecting…"
        case .connected: return "Disconnect"
        case .disconnecting: return "Disconnecting…"
        }
    }

    /// SF-4's near relative: the operator must not be able to miss this. Full
    /// bleed, red, at the top of the window, above everything that scrolls.
    /// (The lock-screen half of SF-4 is APP-3's Live Activity.)
    private var transmitBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("TRANSMITTING")
                .font(.headline.weight(.black))
                .monospaced()
            Spacer()
            Text("ON AIR")
                .font(.headline.weight(.black))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.red)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transmitting. On air.")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Currawong")
                .font(.largeTitle.weight(.semibold))
            Text("AllStarLink and M17 for Apple platforms")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func safetyBanner(_ notice: RadioSession<Client>.SafetyNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(noticeTitle(notice.kind))
                    .font(.subheadline.weight(.bold))
                Text(notice.message)
                    .font(.footnote)
            }
            Spacer(minLength: 0)
            Button {
                session.dismissSafetyNotice()
            } label: {
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

    private func noticeTitle(_ kind: RadioSession<Client>.SafetyNotice.Kind) -> String {
        switch kind {
        case .transmitWatchdog: return "Transmit watchdog stopped you"
        case .audioInterruption: return "Audio interrupted"
        case .routeChange: return "Audio route changed"
        }
    }

    private func warningLine(_ text: String) -> some View {
        Label(text, systemImage: "waveform.badge.exclamationmark")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var statusPanel: some View {
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

            if let reason = session.lastStopReason, reason.isUnexpected, session.safetyNotice == nil {
                Text("Last transmission ended: \(reason.rawValue).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12)))
    }

    /// Received-audio activity. Driven by a `TimelineView` rather than a timer
    /// so the view model stays free of clocks: it answers "is audio arriving
    /// as of *this* instant", and the timeline supplies instants.
    private var receiveIndicator: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let active = session.isReceivingAudio(asOf: context.date)
            HStack(spacing: 6) {
                Image(systemName: active ? "waveform" : "waveform.slash")
                    .foregroundStyle(active ? Color.green : Color.secondary)
                Text(active ? "Audio in" : "Quiet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(active ? "Receiving audio" : "No audio arriving")
        }
    }

    private var connectionColour: Color {
        switch session.connection {
        case .disconnected: return .secondary
        case .connecting, .disconnecting: return .orange
        case .connected: return .green
        }
    }
}

#Preview {
    RootView(session: CompositionRoot().session)
}
