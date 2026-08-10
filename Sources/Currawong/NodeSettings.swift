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

    /// **SF-1.** How long one transmission may last before the library's
    /// watchdog unkeys, in seconds.
    ///
    /// Per node rather than per app, because the right answer depends on what
    /// is on the other end: a parrot or echo-test extension wants a short leash
    /// while you are proving the path works, and a repeater wants something
    /// near its own timeout. The library owns the enforcement; this is only the
    /// number handed to it, and the composition root is what hands it over.
    var transmitTimeout: TimeInterval

    /// The registered IAX2 port. Duplicated rather than imported from
    /// `IAX2Kit`, because this type is not allowed to know which protocol is
    /// underneath it; the composition root is what reconciles the two, and
    /// `IAX2Destination`'s own default is the authority on the wire.
    static let defaultPort: UInt16 = 4569

    /// 180 s, matching `RadioCore.TransmitWatchdog.defaultTimeout`. Duplicated
    /// for the same reason ``defaultPort`` is: this type does not import the
    /// library. The library's own default is the authority if they ever differ,
    /// and it is the value used when nothing has been stored.
    static let defaultTransmitTimeout: TimeInterval = 180

    /// What the operator is allowed to ask for.
    ///
    /// The floor is not arbitrary: below a few seconds the watchdog fires
    /// inside a normal call-and-response and the app becomes unusable rather
    /// than safe. The ceiling is ten minutes, which is longer than any
    /// legitimate single transmission and well inside what a repeater's own
    /// timer will tolerate.
    static let transmitTimeoutRange: ClosedRange<TimeInterval> = 5...600

    init(
        host: String = "",
        port: UInt16 = NodeSettings.defaultPort,
        node: String = "",
        username: String = "",
        callsign: String = "",
        transmitTimeout: TimeInterval = NodeSettings.defaultTransmitTimeout
    ) {
        self.host = host
        self.port = port
        self.node = node
        self.username = username
        self.callsign = callsign
        self.transmitTimeout = transmitTimeout
    }

    /// Decodes settings, **including settings written before this type had a
    /// watchdog timeout.**
    ///
    /// Hand-written for exactly one reason: the synthesised initialiser treats
    /// a missing key as a failure, so adding a non-optional field would make
    /// every stored settings blob undecodable, `SettingsStore.load()` would
    /// return `nil`, and the operator would find their node details wiped by an
    /// app update. A missing timeout is not corruption, it is an older file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(UInt16.self, forKey: .port)
        self.node = try container.decode(String.self, forKey: .node)
        self.username = try container.decode(String.self, forKey: .username)
        self.callsign = try container.decode(String.self, forKey: .callsign)
        self.transmitTimeout =
            try container.decodeIfPresent(TimeInterval.self, forKey: .transmitTimeout)
            ?? Self.defaultTransmitTimeout
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
            callsign: callsign.trimmed.uppercased(),
            transmitTimeout: transmitTimeout)

        guard !trimmed.host.isEmpty else { throw ValidationError.missingHost }
        guard !trimmed.node.isEmpty else { throw ValidationError.missingNode }
        guard !trimmed.callsign.isEmpty else { throw ValidationError.missingCallsign }

        if trimmed.port == 0 { trimmed.port = NodeSettings.defaultPort }

        // Clamped rather than rejected. An out-of-range timeout is not a typo
        // the operator needs to be stopped over — and refusing to connect over
        // it would be a safety feature that prevents transmitting altogether,
        // which is the wrong shape of failure. A value that is not a number at
        // all never gets this far; see ``parseTransmitTimeout(_:)``.
        if !trimmed.transmitTimeout.isFinite {
            trimmed.transmitTimeout = Self.defaultTransmitTimeout
        }
        trimmed.transmitTimeout = min(
            max(trimmed.transmitTimeout, Self.transmitTimeoutRange.lowerBound),
            Self.transmitTimeoutRange.upperBound)

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

    /// Parses a watchdog timeout in whole seconds. Empty means the default, as
    /// with the port; anything unparseable is rejected so the field can refuse
    /// the keystroke rather than silently storing something else.
    static func parseTransmitTimeout(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmed
        if trimmed.isEmpty { return defaultTransmitTimeout }
        guard let value = Int(trimmed), value > 0 else { return nil }
        return TimeInterval(value)
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
