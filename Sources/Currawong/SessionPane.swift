// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The radio right now: the status panel, the reason the last transmission
/// stopped, and the PTT button — what SF-3 and PT-1 need visible without
/// navigating.
///
/// The status panel is always shown, at the top. Meters and the PTT button
/// appear from ``RadioSession/ConnectionStatus/connecting`` onwards, not from
/// `.connected`, so one connect changes the layout once (APP-18).
///
/// No `.onDisappear { session.viewDisappeared() }` here: ``RootView`` is that
/// release path's only owner, and a pane carrying it would unkey on every tab
/// switch. ``PushToTalkButton``'s own `onDisappear` is different and correct.
struct SessionPane: View {
    @ObservedObject var session: RadioSession
    @ObservedObject var accessory: BLEPTTController
    @ObservedObject var remoteCommand: RemoteCommandPTTController

    /// Whether to draw the app's name above the status: true in the tab layout,
    /// which has no window title.
    let showsHeader: Bool

    /// Hangs up, cancels a connect, or reconnects, as ``SessionLinkControl``
    /// says. Passed in because connecting may need a proxy sourced first, and
    /// ``RootView`` owns that sequence.
    let linkAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader { header }

            if let notice = session.safetyNotice {
                SafetyBanner(notice: notice) { session.dismissSafetyNotice() }
            }

            if let warning = session.mediaWarning {
                MediaWarningLabel(text: warning)
            }

            StatusPanel(session: session, accessory: accessoryIndicator)

            // A link that drops while keyed removes the PTT button under a held
            // finger, and its `onDisappear` release is then the only thing that
            // unkeys: the gesture goes with it. `SessionPaneStateTests` covers it.
            if showsTransmitControls {
                LevelMetersView(session: session)

                PushToTalkButton(
                    isEnabled: session.connection.isConnected,
                    isTransmitting: session.isTransmitting,
                    isKeyDown: session.isKeyDown,
                    onPress: { session.beginTransmit() },
                    onRelease: { session.endTransmit(reason: $0) })
                    // A `GeometryReader` takes all it is given; capped so it
                    // cannot push the split layout's lower pane off-screen.
                    .frame(maxHeight: 240)
            }

            // Last in the pane in every state, so the control that ends a call
            // does not move.
            if let control = SessionLinkControl(
                connection: session.connection,
                destinationName: session.settings.displayName,
                isReturningToLastConnected: session.lastConnectedChannel?.id == session.settings.id)
            {
                SessionLinkButton(control: control, action: linkAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: showsTransmitControls)
    }

    /// Whether the transmit controls are on screen; ``SessionPaneLayout`` makes
    /// the decision so ``RootView`` shares it.
    private var showsTransmitControls: Bool {
        SessionPaneLayout(connection: session.connection).showsTransmitControls
    }

    private var accessoryIndicator: AccessoryIndicator {
        AccessoryIndicator(
            linkState: accessory.linkState,
            isAccessoryConfigured: accessory.mapping != nil,
            isAccessoryKeyed: accessory.isAccessoryKeyed,
            isRemoteCommandEnabled: remoteCommand.isEnabled,
            isButtonVerified: accessory.isButtonVerified)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Currawong")
                .font(.largeTitle.weight(.semibold))
            Text("AllStarLink, M17 and EchoLink for Apple platforms")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The link control under the PTT button: Disconnect, Cancel, or Reconnect.
/// Plainer than ``PushToTalkButton`` so it does not compete with it for the
/// glance SF-3 wants spent on the transmit state.
struct SessionLinkButton: View {
    let control: SessionLinkControl
    let action: () -> Void

    var body: some View {
        // Prominent only for the affirmative action. A branch rather than a
        // conditional modifier: the two `buttonStyle`s are different types.
        Group {
            if control.isProminent {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .tint(control.isDestructive ? .red : .accentColor)
        .disabled(!control.isEnabled)
        .accessibilityLabel(control.title)
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: control.systemImage)
                Text(control.title)
                    // Truncate a long channel name rather than reflow the pane.
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
        }
    }
}
