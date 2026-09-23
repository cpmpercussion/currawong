// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The session pane's link control: hang up, cancel a connect, or connect to
/// the selected channel. A pure value so its wording and state are testable.
///
/// On the session pane as well as the form so an operator can hang up without
/// navigating. It dials the *selected* channel — the one the status panel above
/// names — and says "Reconnect" only when that is where the last call went.
struct SessionLinkControl: Equatable {
    let title: String
    let systemImage: String

    /// False only while a disconnect is already under way.
    let isEnabled: Bool

    /// Red, for every state that ends a link, including cancelling a connect.
    let isDestructive: Bool

    /// Filled, for the action that starts a call.
    let isProminent: Bool

    /// - Parameters:
    ///   - connection: the session's connection status.
    ///   - destinationName: the selected channel's display name.
    ///   - isReturningToLastConnected: whether the last call this run went to
    ///     that channel; decides only the wording.
    /// - Returns: `nil` when disconnected with no channel selected.
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
            // `disconnect()` accepts `.connecting`; this is the only control
            // that offers it, since the form's button is inert while busy.
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
