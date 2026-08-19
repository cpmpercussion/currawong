// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which network a connection uses.
///
/// The app's own vocabulary, not the library's: nothing here names `IAX2Client`,
/// `M17Client` or `EchoLinkClient`, and only `CompositionRoot` turns one of
/// these into a concrete client. Views and view models choose a mode and display
/// its name, and that is the whole of their protocol knowledge.
///
/// ## Why the three modes need different fields
///
/// They ask the operator for genuinely different things, and pretending
/// otherwise would mean a form with fields that quietly do nothing:
///
/// | | AllStarLink | M17 | EchoLink |
/// |---|---|---|---|
/// | Reached by | a node *number*, dialled | a reflector *module*, linked | a node's *IPv4*, through the app-wide proxy |
/// | Identity | username + secret | callsign only, unauthenticated | callsign + account password, at a directory server |
/// | Default port | 4569 | 17000 | 8100 — the **proxy's**, and not a channel's |
///
/// `NodeSettings` therefore carries the union and this enum says which third is
/// live. The alternative — three settings types — would triple the store, the
/// form and the validation for the sake of the fields that differ.
///
/// ## EchoLink is the odd one out, and it is worth saying why once
///
/// It names **no host of its own** (APP-13). The library speaks only the proxied
/// route — `EchoLinkDestination.Route.direct` is declared and throws, because no
/// capture of a direct session exists — so every session is tunnelled, and the
/// only host the app resolves for it is the *proxy*, which is app-wide station
/// infrastructure rather than part of a destination. See
/// ``EchoLinkProxySettings``. `NodeSettings.host` and `.port` are therefore dead
/// in this mode, the way `node` is dead in M17.
///
/// The node itself is named twice: a display callsign such as `*ECHOTEST*`, and
/// a literal IPv4 address, because **nothing in the library resolves a callsign
/// to an address**. Turning one into the other is what the directory listing is
/// for, and so what the station browser is for. Typing an address by hand still
/// works; it is just not how anyone would want to find a node.
enum RadioMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// AllStarLink over IAX2 (RFC 5456). The validated path.
    case allStarLink

    /// M17 over a reflector. Confirmed heard on air both ways as of
    /// 2026-08-17 — see ``isValidatedOnAir``.
    case m17

    /// EchoLink through a proxy, GSM 06.10 audio. Validated on air.
    case echoLink

    var id: String { rawValue }

    /// What the operator sees.
    var displayName: String {
        switch self {
        case .allStarLink: return "AllStarLink"
        case .m17: return "M17"
        case .echoLink: return "EchoLink"
        }
    }

    /// The port this mode uses when the operator has not said otherwise.
    ///
    /// Duplicated from the libraries rather than imported, for the same reason
    /// `NodeSettings.defaultPort` is: this layer does not import them. The
    /// destinations' own defaults are the authority on the wire.
    ///
    /// EchoLink's 8100 is the **proxy's** TCP port and not the node's — the node
    /// is reached only through the tunnel, so its own UDP ports never appear in
    /// this app at all.
    var defaultPort: UInt16 {
        switch self {
        case .allStarLink: return 4569
        case .m17: return 17000
        case .echoLink: return 8100
        }
    }

    // On-air validation status used to live here, as `isValidatedOnAir` and an
    // `unvalidatedWarning` shown beside the picker. Both are gone as of
    // 2026-08-16, and not because the modes became equal.
    //
    // M17 receive was proven that evening — a net on M17-434, intelligible for
    // its length, callsigns displayed — and EchoLink ran from this app the same
    // day. M17 *transmit* was the one direction left: on 2026-08-17, sent from
    // this app to M17-434 module B and heard readable at the far end via
    // Mseven, an independent M17 client — one reflector, one receiving
    // implementation, one operator at both ends, but no longer unconfirmed. A
    // per-mode caution cannot say that without saying more than it means, and a
    // warning on a mode whose receive and transmit paths the operator can hear
    // working is a warning they learn to dismiss.
    //
    // It also had exactly one reader, who knows the state of the project better
    // than any label could put it. Development status belongs in the plan and
    // the README; the interface should say things an operator can act on.
    // Restore something here if this app ever has users who are not its author.

    /// Whether this mode has somewhere to browse for a destination.
    ///
    /// EchoLink has the directory listing, which is the only way to turn a
    /// callsign into an address. M17 has the published reflector list, which is
    /// a convenience rather than a necessity. AllStarLink has neither yet — its
    /// node numbers resolve through a lookup rather than a list, which is a
    /// different shape of thing and does not want a pane.
    var hasDirectory: Bool {
        switch self {
        case .echoLink, .m17: return true
        case .allStarLink: return false
        }
    }

    /// Whether this mode dials a node number and authenticates.
    ///
    /// Drives which fields the connect form shows, and which of them
    /// ``NodeSettings/validated()`` insists on.
    var usesNodeNumber: Bool { self == .allStarLink }

    /// Whether this mode links a reflector module.
    var usesModule: Bool { self == .m17 }

    /// Whether this mode reaches its node through an EchoLink proxy, and so needs
    /// a node address and a directory server rather than a node number — and
    /// takes its proxy from ``EchoLinkProxySettings`` rather than from a channel.
    var usesProxy: Bool { self == .echoLink }

    /// Whether the mode has a DTMF path at all.
    ///
    /// AllStarLink is the only one: commanding a node is what DTMF is *for*
    /// there. `M17Client` and `EchoLinkClient` have no `send(dtmf:)`, so the
    /// keypad is hidden rather than shown and made to fail.
    var sendsDTMF: Bool { self == .allStarLink }
}
