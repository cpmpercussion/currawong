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
/// | Reached by | a node *number*, dialled | a reflector *module*, linked | a node's *IPv4*, through a proxy |
/// | Identity | username + secret | callsign only, unauthenticated | callsign + account password, at a directory server |
/// | Default port | 4569 | 17000 | 8100 — the **proxy's** TCP port |
///
/// `NodeSettings` therefore carries the union and this enum says which third is
/// live. The alternative — three settings types — would triple the store, the
/// form and the validation for the sake of the fields that differ.
///
/// ## EchoLink is the odd one out, and it is worth saying why once
///
/// Its `host` and `port` are **the proxy's**, not the node's. The library speaks
/// only the proxied route — `EchoLinkDestination.Route.direct` is declared and
/// throws, because no capture of a direct session exists — so every session is
/// tunnelled, and the proxy is the only host the app ever resolves.
///
/// The node itself is named twice: a display callsign such as `*ECHOTEST*`, and
/// a literal IPv4 address, because **nothing in the library resolves a callsign
/// to an address**. Turning one into the other is what the directory listing is
/// for, and so what the station browser is for. Typing an address by hand still
/// works; it is just not how anyone would want to find a node.
enum RadioMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// AllStarLink over IAX2 (RFC 5456). The validated path.
    case allStarLink

    /// M17 over a reflector. Believed working, never confirmed on air — see
    /// ``isValidatedOnAir``.
    case m17

    /// EchoLink through a proxy, GSM 06.10 audio. Validated on air by the
    /// library's CLI harness (Milestone M3, 2026-08-13) but never yet from this
    /// app — see ``unvalidatedWarning``.
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

    /// Whether this mode's stack has ever carried a real conversation.
    ///
    /// **This is not decoration.** AllStarLink has carried a two-way
    /// conversation through this stack, and so has EchoLink — through the
    /// library's CLI rather than through this app, but the protocol code is the
    /// same code. M17 has never been transmitted to a reflector by anyone, and
    /// its decoded audio has never been listened to. An operator picking M17 is
    /// the first person to try it, and the UI says so rather than presenting
    /// three equal choices.
    var isValidatedOnAir: Bool {
        switch self {
        case .allStarLink, .echoLink: return true
        case .m17: return false
        }
    }

    /// Shown beside the picker when there is something the operator should know
    /// before trusting the mode.
    ///
    /// Two different kinds of caveat, deliberately not flattened into one: M17
    /// has never worked anywhere, and EchoLink has worked but not from here.
    /// Telling an operator "unproven" about a mode that carried a QSO yesterday
    /// would train them to ignore the warning that matters.
    var unvalidatedWarning: String? {
        switch self {
        case .allStarLink:
            return nil
        case .m17:
            return """
                M17 has never been transmitted to a real reflector. It may not work \
                at all, and if it does, nobody has yet heard how it sounds.
                """
        case .echoLink:
            return """
                EchoLink has carried a live QSO through the command-line harness, \
                but never yet from this app.
                """
        }
    }

    /// Whether this mode dials a node number and authenticates.
    ///
    /// Drives which fields the connect form shows, and which of them
    /// ``NodeSettings/validated()`` insists on.
    var usesNodeNumber: Bool { self == .allStarLink }

    /// Whether this mode links a reflector module.
    var usesModule: Bool { self == .m17 }

    /// Whether this mode reaches its node through an EchoLink proxy, and so
    /// needs a proxy password, a node address and a directory server rather
    /// than a node number.
    var usesProxy: Bool { self == .echoLink }

    /// Whether the mode has a DTMF path at all.
    ///
    /// AllStarLink is the only one: commanding a node is what DTMF is *for*
    /// there. `M17Client` and `EchoLinkClient` have no `send(dtmf:)`, so the
    /// keypad is hidden rather than shown and made to fail.
    var sendsDTMF: Bool { self == .allStarLink }
}
