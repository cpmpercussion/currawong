// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Everything the app needs to reach a node, **except the secret**.
///
/// The split is deliberate and load-bearing: this value is `Codable` and is
/// written to `UserDefaults`, and the secret is not part of it, so there is no
/// way to accidentally persist a password by persisting the settings. The
/// secret lives in the Keychain and is keyed by ``secretAccount``.
///
/// Protocol-agnostic on purpose. Nothing here mentions IAX2 — the composition
/// root turns one of these plus a secret into a concrete destination. Full
/// settings CRUD (multiple stored nodes, editing, deleting) is APP-4; this is
/// the single node a first connection needs.
struct NodeSettings: Equatable, Codable, Sendable {
    /// Hostname or literal address of the node.
    var host: String

    /// UDP port. 4569 is the registered IAX2 port and the default everywhere.
    var port: UInt16

    /// The number being called — an AllStar node number such as `"55553"`.
    var node: String

    /// The account the node authenticates us as. May be empty.
    var username: String

    /// The operator's callsign, sent as the calling name.
    var callsign: String

    /// The registered IAX2 port. Duplicated rather than imported from
    /// `IAX2Kit`, because this type is not allowed to know which protocol is
    /// underneath it; the composition root is what reconciles the two, and
    /// `IAX2Destination`'s own default is the authority on the wire.
    static let defaultPort: UInt16 = 4569

    init(
        host: String = "",
        port: UInt16 = NodeSettings.defaultPort,
        node: String = "",
        username: String = "",
        callsign: String = ""
    ) {
        self.host = host
        self.port = port
        self.node = node
        self.username = username
        self.callsign = callsign
    }

    /// The Keychain account the secret for this node is filed under.
    ///
    /// Derived rather than stored so it cannot drift out of step with the
    /// settings, and deliberately contains no secret material — it is an
    /// identifier, and it ends up in a Keychain attribute where it is visible.
    var secretAccount: String {
        "\(username)@\(host):\(port)/\(node)"
    }

    /// What is wrong with a set of settings the operator has typed.
    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case missingHost
        case missingNode
        case missingCallsign

        var description: String {
            switch self {
            case .missingHost:
                return "Enter the node's host name or address."
            case .missingNode:
                return "Enter the node number to call."
            case .missingCallsign:
                return "Enter your callsign. Transmitting without identifying is not legal anywhere."
            }
        }
    }

    /// Trimmed, normalised settings, or an error naming the empty field.
    ///
    /// `username` and the secret are *not* required: a node with no account
    /// configured expects neither, and the library omits empty fields rather
    /// than sending blank ones. `callsign` is required, because unidentified
    /// transmission is not a thing this app is going to make easy.
    func validated() throws -> NodeSettings {
        var trimmed = NodeSettings(
            host: host.trimmed,
            port: port,
            node: node.trimmed,
            username: username.trimmed,
            callsign: callsign.trimmed.uppercased())

        guard !trimmed.host.isEmpty else { throw ValidationError.missingHost }
        guard !trimmed.node.isEmpty else { throw ValidationError.missingNode }
        guard !trimmed.callsign.isEmpty else { throw ValidationError.missingCallsign }

        if trimmed.port == 0 { trimmed.port = NodeSettings.defaultPort }
        return trimmed
    }

    /// Parses a port the operator typed. Empty means "the default", not zero —
    /// a cleared field should connect to 4569, not fail.
    static func parsePort(_ text: String) -> UInt16? {
        let trimmed = text.trimmed
        if trimmed.isEmpty { return defaultPort }
        guard let value = UInt16(trimmed), value > 0 else { return nil }
        return value
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
