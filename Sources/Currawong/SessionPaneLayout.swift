// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **APP-18.** Which controls the session screen has, given what the link is
/// doing.
///
/// A pure value like ``SessionLinkControl`` and ``AccessoryIndicator``, shared
/// because the decision has two halves in *different files* — ``SessionPane``
/// owns the meters and the PTT button, ``RootView`` owns the connect form and
/// the pane picker — and they must not drift into showing both or neither.
///
/// ## Why `.connecting` counts as a link
///
/// The switch is on "not disconnected" rather than "connected", so a press of
/// Connect changes the layout once, at the moment the operator acts, rather
/// than twice — once when the form goes away, once when the meters arrive.
/// `.disconnecting` keeps the transmit controls for the same reason from the
/// other side: taking them away a beat early makes hanging up look like a
/// fault.
struct SessionPaneLayout: Equatable {
    /// The level meters and the PTT button. Before there is a link they are a
    /// meter reading nothing and a large slab that advertises itself and then
    /// refuses.
    let showsTransmitControls: Bool

    /// The connect form — the whole pane while disconnected, and gone once there
    /// is a link, where it is `isEditable: false` and so a read-only wall of
    /// fields whose one useful line (where the radio is pointed) is on the
    /// status panel instead (APP-16).
    let showsConnectForm: Bool

    init(connection: RadioSession.ConnectionStatus) {
        showsConnectForm = connection == .disconnected
        showsTransmitControls = !showsConnectForm
    }
}
