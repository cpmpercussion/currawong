// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The session pane's one link control: hang up, cancel a connect in progress,
/// or go back to where you just were.
///
/// A pure value like ``TransmitStatusPresentation``, and for the same reason —
/// what the button says, whether it is armed, and whether it is the destructive
/// one are decisions worth testing without a view.
///
/// ## Why there is a second one of these at all
///
/// The connect form already has a Connect/Disconnect button. This is not a
/// duplicate of it but the same argument ``SessionPane`` is built on: the
/// session pane is the screen an operator looks at *while talking*, and hanging
/// up is something they may want to do in a hurry. Making them navigate to the
/// form to end a link is the same mistake as putting the PTT button there.
///
/// ## Why this dials the *selected* channel
///
/// It used to offer only "Reconnect", to the last channel a call was placed to
/// this run, and it restored that channel before dialling. The reasoning was
/// that a plain Connect here would be a second entry point to a form's worth of
/// fields the operator could not see from this pane, so the button should never
/// start a call to somewhere they had not looked at.
///
/// **APP-16 removed that premise.** The status panel immediately above this
/// button now names the destination, its address and its mode, so the operator
/// can see exactly where a call would go without leaving the pane.
///
/// What the old behaviour cost, meanwhile, was worse than what it bought:
/// selecting a channel in the list moved the panel and left the button naming
/// the previous one, so the pane showed `M17-432 H` above a button reading
/// `Reconnect to M17-CBR A` — and pressing it dialled the second. A control that
/// keys a transmitter must not disagree with the thing above it about where.
///
/// So the button follows the selection. The word still distinguishes the two
/// cases, because returning to where you just were is worth knowing: **the same
/// channel says "Reconnect", a different one says "Connect"**, and both dial
/// what the panel is showing.
///
struct SessionLinkControl: Equatable {
    let title: String
    let systemImage: String

    /// Whether the button does anything. False only while a disconnect is
    /// already under way — the one state with nothing left to ask for.
    let isEnabled: Bool

    /// Whether this is the destructive presentation (red, prominent). True for
    /// every state that ends a link, including the cancel of a connect in
    /// progress: ending a call is the action an operator should be able to find
    /// without reading.
    let isDestructive: Bool

    /// Whether this is the affirmative action — the one that starts a call, and
    /// the one an operator should be able to find at a glance after choosing a
    /// channel. Drives the prominent (filled) presentation.
    let isProminent: Bool

    /// - Parameters:
    ///   - connection: the session's connection status.
    ///   - destinationName: the display name of the channel currently selected —
    ///     the one the status panel is showing, and the one this button dials.
    ///   - isReturningToLastConnected: whether that channel is the one a call
    ///     was last placed to this run, which decides only the wording.
    /// - Returns: `nil` when there is nothing to show — disconnected with no
    ///   channel selected, where there is nowhere for the button to go.
    init?(
        connection: RadioSession.ConnectionStatus,
        destinationName: String?,
        isReturningToLastConnected: Bool = false
    ) {
        switch connection {
        case .connected:
            title = "Disconnect"
            systemImage = "phone.down.fill"
            isEnabled = true
            isDestructive = true
            isProminent = false
        case .connecting:
            // Not "Disconnect": there is no link yet to drop. `disconnect()`
            // accepts `.connecting` precisely so a connect that is going nowhere
            // can be abandoned, and this is the only control that offers it —
            // the form's button is inert while busy.
            title = "Cancel"
            systemImage = "xmark.circle.fill"
            isEnabled = true
            isDestructive = true
            isProminent = false
        case .disconnecting:
            title = "Disconnecting…"
            systemImage = "phone.down.fill"
            isEnabled = false
            isDestructive = true
            isProminent = false
        case .disconnected:
            guard let name = destinationName, !name.isEmpty else { return nil }
            title = isReturningToLastConnected ? "Reconnect to \(name)" : "Connect to \(name)"
            systemImage = "phone.arrow.up.right.fill"
            isEnabled = true
            isDestructive = false
            isProminent = true
        }
    }
}
