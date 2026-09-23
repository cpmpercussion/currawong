// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which network a connection uses, in the app's own vocabulary; only
/// `CompositionRoot` turns one into a concrete client.
///
/// | | AllStarLink | M17 | EchoLink |
/// |---|---|---|---|
/// | Reached by | a node *number* | a reflector *module* | a node's *IPv4*, through the app-wide proxy |
/// | Identity | username + secret | callsign only | callsign + account password, at a directory server |
///
/// `NodeSettings` carries the union of their fields and this says which are
/// live. EchoLink has no host of its own: the library supports only the
/// proxied route, so `NodeSettings.host` and `.port` are unused and the proxy
/// comes from ``EchoLinkProxySettings`` (APP-13). Its node is named by a
/// display callsign and a literal IPv4 address, because nothing in the library
/// resolves one to the other — the directory does.
enum RadioMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// AllStarLink over IAX2 (RFC 5456).
    case allStarLink

    /// M17 over a reflector.
    case m17

    /// EchoLink through a proxy, GSM 06.10 audio.
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

    /// The port this mode uses when the operator has not said otherwise,
    /// duplicated because this layer does not import the libraries. EchoLink's
    /// 8100 is the proxy's TCP port, not the node's.
    var defaultPort: UInt16 {
        switch self {
        case .allStarLink: return 4569
        case .m17: return 17000
        case .echoLink: return 8100
        }
    }

    /// Whether this mode has a directory to browse. AllStarLink node numbers
    /// resolve through a lookup instead.
    var hasDirectory: Bool {
        switch self {
        case .echoLink, .m17: return true
        case .allStarLink: return false
        }
    }

    /// Whether this mode dials a node number and authenticates. Drives the
    /// connect form's fields and ``NodeSettings/validated()``.
    var usesNodeNumber: Bool { self == .allStarLink }

    /// Whether this mode links a reflector module.
    var usesModule: Bool { self == .m17 }

    /// Whether this mode reaches its node through an EchoLink proxy.
    var usesProxy: Bool { self == .echoLink }

    /// Whether the mode has a DTMF path. `M17Client` and `EchoLinkClient` have
    /// no `send(dtmf:)`, so the keypad is hidden for them.
    var sendsDTMF: Bool { self == .allStarLink }
}
