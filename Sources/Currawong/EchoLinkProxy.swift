// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **APP-13.** The operator's own EchoLink proxy, if they run one.
///
/// App-wide, not per channel: a proxy is station infrastructure, the same for
/// every node called. The password is not in here — it is in the Keychain
/// under ``passwordAccount``; a public proxy's is the literal ``publicPassword``.
struct EchoLinkProxySettings: Equatable, Codable, Sendable {
    /// The proxy's host name or address. Empty means "no private proxy" — find
    /// a public one instead.
    var host: String

    /// The proxy's TCP port.
    var port: UInt16

    /// Nothing configured: find a public proxy.
    static let none = EchoLinkProxySettings()

    /// Must equal `RadioMode.echoLink.defaultPort`.
    static let defaultPort: UInt16 = 8100

    /// The literal every public proxy expects. Not a secret.
    static let publicPassword = "PUBLIC"

    /// The Keychain account for the private proxy's password. Not per callsign,
    /// unlike the operator's credentials: it is a machine's password.
    static let passwordAccount = "echolink-proxy"

    init(host: String = "", port: UInt16 = EchoLinkProxySettings.defaultPort) {
        self.host = host
        self.port = port
    }

    /// Whether a private proxy is set; `false` means probe for a public one.
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
    /// More permissive than ``NodeSettings/isPlausibleHostName``: a private
    /// proxy is often a single-label name like `shackpi`. It refuses spaces, a
    /// pasted URL, and a colon — the last rules out bare IPv6 in exchange for
    /// catching `shackpi:8100`.
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

    /// This proxy as a route, or `nil` when none is configured.
    func route(password: String) -> EchoLinkProxyRoute? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return EchoLinkProxyRoute(
            host: trimmed, port: port == 0 ? Self.defaultPort : port, password: password,
            isPrivate: true)
    }
}

/// The proxy one EchoLink session goes through: resolved when connecting or
/// reading the directory, from the private proxy or a probe, and never stored
/// in a channel.
struct EchoLinkProxyRoute: Equatable, Sendable {
    var host: String
    var port: UInt16

    /// ``EchoLinkProxySettings/publicPassword`` on a public proxy; whatever the
    /// operator stored on their own.
    var password: String

    /// Whether this is the operator's own proxy rather than a stranger's.
    /// Display only.
    var isPrivate: Bool
}
