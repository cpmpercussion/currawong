// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The pane that is about *the radio right now*: what the link is doing, what
/// stopped the last transmission, and the button that keys the transmitter.
///
/// ## Why these five things and nothing else
///
/// Everything here is either a safety message or the PTT button, and the two
/// belong together because of what SF-3 and PT-1 need from the layout: the
/// operator must be able to see that they are keyed, see why they stopped being
/// keyed, and reach the control that stops it — without navigating. The connect
/// form, the keypad and the station browser are all things you do *between*
/// transmissions, so they live in other panes; this one is the one you look at
/// while talking.
///
/// ## What is deliberately not here
///
/// No `.onDisappear { session.viewDisappeared() }`. That handler is the app's
/// "the operator has left" release path and ``RootView`` is its only owner. If
/// a pane carried it too, switching tabs would unkey the radio through the same
/// code path as closing the app, and the session would have no way to tell an
/// operator who navigated from an operator who left.
///
/// ``PushToTalkButton`` does carry its own `onDisappear`, which is a different
/// and correct thing: it releases the key when the *button* goes away, because
/// its gesture goes away with it. See the note in ``RootView`` about what that
/// means for the tab layout.
struct SessionPane: View {
    @ObservedObject var session: RadioSession
    @ObservedObject var accessory: BLEPTTController
    @ObservedObject var remoteCommand: RemoteCommandPTTController

    /// Whether to draw the app's name above the status.
    ///
    /// True in the tab layout, where there is no window title and no navigation
    /// bar to say what this app is; false in the split layout, where the window
    /// title already does and the vertical space is worth more spent on keeping
    /// the PTT button above the fold.
    let showsHeader: Bool

    /// Opens the accessory screen. Passed in rather than presented from here,
    /// because in the split layout the accessories are a pane rather than a
    /// sheet and this view should not have to know which.
    let openAccessories: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader { header }

            if let notice = session.safetyNotice {
                SafetyBanner(notice: notice) { session.dismissSafetyNotice() }
            }

            if let warning = session.mediaWarning {
                MediaWarningLabel(text: warning)
            }

            StatusPanel(session: session)

            LevelMetersView(session: session)

            PushToTalkButton(
                isEnabled: session.connection.isConnected,
                isTransmitting: session.isTransmitting,
                isKeyDown: session.isKeyDown,
                onPress: { session.beginTransmit() },
                onRelease: { session.endTransmit(reason: $0) })
                // The button is a `GeometryReader` and so takes whatever it is
                // given. Capped, because in the split layout this pane shares a
                // fixed column with the panes below it and an uncapped button
                // would push them off the bottom.
                .frame(maxHeight: 240)

            AccessoryStatusRow(
                accessory: accessory,
                remoteCommand: remoteCommand,
                action: openAccessories)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// **BLE-3's indicator**, and the way in to the accessory screen.
///
/// The link state is on the row rather than only on the screen that configures
/// it, because the question "is my PTT fob still connected?" is asked from the
/// screen the operator is looking at while transmitting, not from the settings
/// screen.
struct AccessoryStatusRow: View {
    @ObservedObject var accessory: BLEPTTController
    @ObservedObject var remoteCommand: RemoteCommandPTTController
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(colour)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PTT accessories")
                        .font(.subheadline.weight(.medium))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        if accessory.isAccessoryKeyed { return "dot.radiowaves.left.and.right" }
        switch accessory.linkState {
        case .connected: return "dot.circle"
        case .noAccessory: return remoteCommand.isEnabled ? "headphones" : "dot.circle"
        case .scanning, .connecting, .reconnecting: return "antenna.radiowaves.left.and.right"
        case .unavailable, .failed: return "exclamationmark.triangle"
        }
    }

    private var colour: Color {
        switch accessory.linkState {
        case .connected: return .green
        case .reconnecting, .scanning, .connecting: return .orange
        case .failed, .unavailable: return .orange
        case .noAccessory: return remoteCommand.isEnabled ? .green : .secondary
        }
    }

    /// One line covering both inputs, because "no accessory" and "no accessory
    /// but the headset button is armed" are different situations and the
    /// difference is whether a button in the operator's pocket can key a
    /// transmitter.
    private var summary: String {
        switch (accessory.linkState, remoteCommand.isEnabled) {
        case (.noAccessory, false):
            return "None set up"
        case (.noAccessory, true):
            return PTTSource.remoteCommand.label
        case (let state, false):
            return state.label
        case (let state, true):
            return "\(state.label) · \(PTTSource.remoteCommand.label)"
        }
    }
}
