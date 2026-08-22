// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The pane that is about *the radio right now*: what the link is doing, what
/// stopped the last transmission, and the button that keys the transmitter.
///
/// ## Why these things and nothing else
///
/// Everything here is either a safety message or the PTT button, and the two
/// belong together because of what SF-3 and PT-1 need from the layout: the
/// operator must be able to see that they are keyed, see why they stopped being
/// keyed, and reach the control that stops it — without navigating. The connect
/// form, the keypad and the station browser are all things you do *between*
/// transmissions, so they live in other panes; this one is the one you look at
/// while talking.
///
/// ## APP-18: the controls the state actually has
///
/// This pane used to show all of it in every state, which made it the *union*
/// of two radios rather than either one — and made the column rigid and tall
/// enough to overflow a short window, which is the root cause APP-15 worked
/// around by moving the pane picker to the toolbar.
///
/// It is now organised the way a rig is. **The status panel never hides**: one
/// region that is always there and always current, anchored at the top, so a
/// state change reads as the controls around the display changing rather than
/// as the whole thing jumping. Everything else earns its place:
///
/// * **Disconnected** — no level meters and no PTT button. A large slab reading
///   "Connect to a node first" is a control that advertises itself and then
///   refuses, and the space it took belongs to the connect form, which is the
///   only thing an operator can act on before a link exists.
/// * **Connecting or connected** — meters and PTT. The switch is on
///   ``RadioSession/ConnectionStatus/connecting``, not `.connected`: keyed off
///   the latter, the layout would change twice for one action, and the second
///   change would land while the operator was watching for the link to come up.
///
/// The accessory row went into the status panel as ``AccessoryIndicator``. Its
/// configuration was already on the settings screen (APP-12); what is left is a
/// light, which is what it always was.
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

    /// Hangs up, cancels a connect in progress, or reconnects to the last
    /// channel — whichever ``SessionLinkControl`` says the button means.
    ///
    /// Passed in rather than calling `session.disconnect()` here, because
    /// connecting is not only `connect()`: an EchoLink channel may need a proxy
    /// sourced first, and ``RootView`` is the one place that knows the whole
    /// sequence. Two call sites for one sequence is how the form and this button
    /// would come to disagree about it.
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

            // APP-18. Only once there is a link, or one on the way: before that
            // these are a meter reading nothing and a button that refuses.
            //
            // **A link that drops while the operator is keyed takes the PTT
            // button out of the hierarchy under a held finger.**
            // ``PushToTalkButton`` ends with
            // `.onDisappear { onRelease(.viewDisappeared) }`, which was written
            // as a backstop for the tab layout and is load-bearing here: it is
            // the only thing that unkeys in that case, because the gesture that
            // would have reported the release is torn down with the button.
            // `SessionPaneStateTests` drops the link while keyed and asserts
            // the release.
            if showsTransmitControls {
                LevelMetersView(session: session)

                PushToTalkButton(
                    isEnabled: session.connection.isConnected,
                    isTransmitting: session.isTransmitting,
                    isKeyDown: session.isKeyDown,
                    onPress: { session.beginTransmit() },
                    onRelease: { session.endTransmit(reason: $0) })
                    // The button is a `GeometryReader` and so takes whatever it
                    // is given. Capped, because in the split layout this pane
                    // shares a fixed column with the panes below it and an
                    // uncapped button would push them off the bottom.
                    .frame(maxHeight: 240)
            }

            // Directly under the PTT button, which is where the operator's hand
            // already is — and it is the last thing in the pane in every state,
            // so the control that ends a call does not move when the controls
            // above it come and go.
            if let control = SessionLinkControl(
                connection: session.connection,
                destinationName: session.settings.displayName,
                isReturningToLastConnected: session.lastConnectedChannel?.id == session.settings.id)
            {
                SessionLinkButton(control: control, action: linkAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Animated, so the region below the status panel is seen to change
        // rather than to have been replaced. The panel itself does not move:
        // this pane is top-aligned by its container.
        .animation(.default, value: showsTransmitControls)
    }

    /// Whether the transmit controls are on screen. The other half of the same
    /// decision — whether the connect form is — is ``RootView``'s, which is why
    /// the decision itself is ``SessionPaneLayout`` rather than a comparison
    /// written out in each place.
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
///
/// Deliberately much plainer than ``PushToTalkButton``. That button is the one
/// the operator must be able to hit without looking, and a second full-width
/// coloured slab under it would compete with it for exactly the glance SF-3
/// wants spent on the transmit state. This is a normal button that says what it
/// does.
struct SessionLinkButton: View {
    let control: SessionLinkControl
    let action: () -> Void

    var body: some View {
        // Prominent for the affirmative action only. Choosing a channel and then
        // hunting for the way to call it was the complaint this answers — a
        // bordered button under a large PTT slab did not read as the next step.
        // Disconnect stays bordered: it is findable because it is red and in a
        // fixed place, and a second filled slab under the PTT would compete with
        // it for the glance SF-3 wants spent on the transmit state.
        //
        // Written as a branch over the whole button rather than a conditional
        // modifier, because `buttonStyle` takes different concrete types and
        // there is no eraser for them.
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
                    // A channel name can be long, and truncating the label is
                    // better than a button that reflows the pane around it.
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
        }
    }
}
