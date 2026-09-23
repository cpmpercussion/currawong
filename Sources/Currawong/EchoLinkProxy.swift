// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **APP-13.** The operator's own EchoLink proxy, if they run one.
///
/// **App-wide, not per channel.** A proxy is the operator's station
/// infrastructure — the machine their traffic leaves through, the same one for
/// every node they call, set up once. `isSamePlace(as:)` already ignores the
/// host in EchoLink and `secretAccount(for:)` has no host in it, so
/// ``NodeSettings`` was never really treating a proxy as channel state; see
/// ``ProxyPicker/lease`` for how a probed public proxy is kept from being
/// reused forever instead.
///
/// **The password is not in here.** It goes in the Keychain, under
/// ``passwordAccount``, so an operator running a private proxy is not storing
/// its password in `UserDefaults`, less carefully than their account password.
/// A *public* proxy's password is the protocol literal ``publicPassword`` and
/// is not stored at all.
struct EchoLinkProxySettings: Equatable, Codable, Sendable {
    /// The proxy's host name or address. Empty means "no private proxy" — find
    /// a public one instead.
    var host: String

    /// The proxy's TCP port. 8100 everywhere observed.
    var port: UInt16

    /// Nothing configured, which is the state every operator starts in and most
    /// stay in.
    static let none = EchoLinkProxySettings()

    /// The proxy port. Duplicated from `RadioMode.echoLink.defaultPort` rather
    /// than read from it, because this type is about the proxy and not about a
    /// mode — but they are the same number and must stay so.
    static let defaultPort: UInt16 = 8100

    /// The literal every public proxy expects, and the only proxy password ever
    /// seen on the wire. Not a secret, which is why it is a constant here rather
    /// than something the operator is asked for.
    static let publicPassword = "PUBLIC"

    /// The Keychain account the private proxy's password is filed under.
    ///
    /// **Not per callsign**, unlike the EchoLink account and the Web Transceiver
    /// token. Those are credentials issued *to an operator*; this is the
    /// password of a machine, and it does not change when the callsign it is
    /// used from does. One string, no interpolation, so it cannot drift.
    static let passwordAccount = "echolink-proxy"

    init(host: String = "", port: UInt16 = EchoLinkProxySettings.defaultPort) {
        self.host = host
        self.port = port
    }

    /// Whether a private proxy is set. `false` is the ordinary case and means
    /// "probe for a public one".
    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What is wrong with what the operator typed.
    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidHost

        var description: String {
            switch self {
            case .invalidHost:
                return """
                    A proxy address is a host name or an IP address, with no spaces and no \
                    http:// in front of it.
                    """
            }
        }
    }

    /// Trimmed settings, or an error naming what is wrong.
    ///
    /// **Deliberately more permissive than ``NodeSettings/isPlausibleHostName``**,
    /// which insists on a dot — right for a directory server's handful of
    /// published names, wrong here: a private proxy is often a single-label
    /// machine name like `pi` or `shackpi`. What is caught is what is actually
    /// a mistake: a URL pasted in whole, or a name with a space in it.
    ///
    /// A colon is refused too, which rules out a bare IPv6 literal — a
    /// deliberate trade, since the port has its own field and `shackpi:8100` is
    /// far likelier to be typed here.
    func validated() throws -> EchoLinkProxySettings {
        var trimmed = EchoLinkProxySettings(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)

        if trimmed.isConfigured {
            guard
                !trimmed.host.contains(where: \.isWhitespace),
                !trimmed.host.contains("/"),
                !trimmed.host.contains(":")
            else { throw ValidationError.invalidHost }
        }

        if trimmed.port == 0 { trimmed.port = Self.defaultPort }
        return trimmed
    }

    /// This proxy as something a session can tunnel through. `nil` when no
    /// private proxy is configured, which is the caller's signal to find a
    /// public one.
    func route(password: String) -> EchoLinkProxyRoute? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return EchoLinkProxyRoute(
            host: trimmed, port: port == 0 ? Self.defaultPort : port, password: password,
            isPrivate: true)
    }
}

/// The proxy one EchoLink session actually goes through.
///
/// Resolved at the moment of use — connecting, or reading the directory — from
/// the private proxy if there is one and from a probe if there is not, and
/// **never stored in a channel**. It exists so the thing a session tunnels
/// through is a value passed to the code that needs it rather than three fields
/// on a saved destination that outlive the session.
///
/// The app's own vocabulary: `EchoLinkProxyPassword` and the library's
/// `.proxy(host:port:password:)` route belong to `CompositionRoot`.
struct EchoLinkProxyRoute: Equatable, Sendable {
    var host: String
    var port: UInt16

    /// ``EchoLinkProxySettings/publicPassword`` on a public proxy; whatever the
    /// operator stored on their own.
    var password: String

    /// Whether this is the operator's own proxy rather than a stranger's.
    ///
    /// Display only, and it earns its place: "your proxy" and "somebody else's
    /// machine, briefly" are different obligations, and the operator should be
    /// able to see which one is carrying their traffic.
    var isPrivate: Bool
}
