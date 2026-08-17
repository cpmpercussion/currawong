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
/// ## Why "Reconnect" and not "Connect"
///
/// A plain Connect button here would be a second entry point to a form's worth
/// of fields the operator cannot see from this pane. Reconnect is narrower and
/// honest: it names the place it will call, and it appears only once there is
/// somewhere to go back to — so it can never be the button that starts a call to
/// somewhere the operator has not looked at.
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

    /// - Parameters:
    ///   - connection: the session's connection status.
    ///   - lastConnectedName: the display name of the last channel a call was
    ///     placed to this run, or `nil` if there has not been one.
    /// - Returns: `nil` when there is nothing to show — disconnected, with
    ///   nowhere to go back to. The connect form is where a first call starts,
    ///   and a dead button here would only invite pressing it.
    init?(connection: RadioSession.ConnectionStatus, lastConnectedName: String?) {
        switch connection {
        case .connected:
            title = "Disconnect"
            systemImage = "phone.down.fill"
            isEnabled = true
            isDestructive = true
        case .connecting:
            // Not "Disconnect": there is no link yet to drop. `disconnect()`
            // accepts `.connecting` precisely so a connect that is going nowhere
            // can be abandoned, and this is the only control that offers it —
            // the form's button is inert while busy.
            title = "Cancel"
            systemImage = "xmark.circle.fill"
            isEnabled = true
            isDestructive = true
        case .disconnecting:
            title = "Disconnecting…"
            systemImage = "phone.down.fill"
            isEnabled = false
            isDestructive = true
        case .disconnected:
            guard let name = lastConnectedName, !name.isEmpty else { return nil }
            title = "Reconnect to \(name)"
            systemImage = "phone.arrow.up.right.fill"
            isEnabled = true
            isDestructive = false
        }
    }
}
