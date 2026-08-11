// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Everything the app needs to reach a node, **except the secret**.
///
/// The split is deliberate and load-bearing: this value is `Codable` and is
/// written to `UserDefaults`, and the secret is not part of it, so there is no
/// way to accidentally persist a password by persisting the settings. The
/// secret lives in the Keychain and is keyed by ``secretAccount``.
///
/// Names no library type. It carries a ``RadioMode`` and the *union* of both
/// modes' fields, and the composition root turns one of these plus a secret
/// into a concrete destination — the mode is the app's own vocabulary, not
/// `IAX2Client` or `M17ReflectorClient` leaking upwards.
///
/// The union is a deliberate trade-off rather than an accident of growth. Two
/// settings types would each be honest about their own fields, but would double
/// the store, the form and the validation for the sake of one field that
/// differs (``node`` versus ``module``). One type plus a mode keeps that cost
/// at a single `if` in ``validated()`` and a single form; the price is that a
/// value always has one field that means nothing, and only the mode says which.
///
/// Full settings CRUD (multiple stored nodes, editing, deleting) is APP-4; this
/// is the single node a first connection needs.
struct NodeSettings: Equatable, Codable, Sendable {
    /// Which network this node is reached over, and therefore which of the
    /// fields below are live.
    var mode: RadioMode

    /// Hostname or literal address of the node.
    var host: String

    /// UDP port. 4569 is the registered IAX2 port and the default everywhere.
    var port: UInt16

    /// The number being called — an AllStar node number such as `"55553"`.
    /// Empty and unused in M17, which links a ``module`` instead.
    var node: String

    /// The M17 reflector module to link: a single letter A–Z. Empty and unused
    /// in AllStarLink.
    var module: String

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
        mode: RadioMode = .allStarLink,
        host: String = "",
        port: UInt16 = NodeSettings.defaultPort,
        node: String = "",
        module: String = "",
        username: String = "",
        callsign: String = "",
        transmitTimeout: TimeInterval = NodeSettings.defaultTransmitTimeout
    ) {
        self.mode = mode
        self.host = host
        self.port = port
        self.node = node
        self.module = module
        self.username = username
        self.callsign = callsign
        self.transmitTimeout = transmitTimeout
    }

    /// Decodes settings, **including settings written before this type had a
    /// watchdog timeout, a mode, or a module.**
    ///
    /// Hand-written for exactly one reason: the synthesised initialiser treats
    /// a missing key as a failure, so adding a non-optional field would make
    /// every stored settings blob undecodable, `SettingsStore.load()` would
    /// return `nil`, and the operator would find their node details wiped by an
    /// app update. A missing timeout is not corruption, it is an older file.
    ///
    /// The same holds for the mode: a blob written before modes existed was
    /// written when AllStarLink was the only thing this app could do, so it *is*
    /// an AllStarLink node rather than a corrupt one, and a missing module is
    /// simply a field that mode never asks for.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decodeIfPresent(RadioMode.self, forKey: .mode) ?? .allStarLink
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(UInt16.self, forKey: .port)
        self.node = try container.decode(String.self, forKey: .node)
        self.module = try container.decodeIfPresent(String.self, forKey: .module) ?? ""
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
    ///
    /// **The AllStarLink form is frozen.** Every secret an operator has already
    /// stored is filed under `username@host:port/node`; changing that string by
    /// so much as a separator orphans all of them, and the operator would be
    /// asked for a password they thought they had saved. M17 needs its own form
    /// anyway — it is unauthenticated, so it has no secret to file, but the
    /// account still has to identify the entry uniquely, and an M17 link to a
    /// host must not be mistaken for an authenticated AllStarLink connection to
    /// the same host. Its dialled target is a module letter rather than a node
    /// number, and the prefix makes the two unmistakable.
    var secretAccount: String {
        switch mode {
        case .allStarLink:
            return "\(username)@\(host):\(port)/\(node)"
        case .m17:
            return "m17:\(callsign)@\(host):\(port)/\(module)"
        }
    }

    /// What is wrong with a set of settings the operator has typed.
    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case missingHost
        case missingNode
        case missingCallsign
        case missingModule
        case invalidModule

        var description: String {
            switch self {
            case .missingHost:
                return "Enter the node's host name or address."
            case .missingNode:
                return "Enter the node number to call."
            case .missingCallsign:
                return "Enter your callsign. Transmitting without identifying is not legal anywhere."
            case .missingModule:
                return "Enter the reflector module to link, a single letter A-Z."
            case .invalidModule:
                return "A reflector module is one letter, A-Z — not a word or a number."
            }
        }
    }

    /// Trimmed, normalised settings, or an error naming the empty field.
    ///
    /// `username` and the secret are *not* required: a node with no account
    /// configured expects neither, and the library omits empty fields rather
    /// than sending blank ones. `callsign` is required in both modes, because
    /// unidentified transmission is not a thing this app is going to make easy.
    ///
    /// Which of ``node`` and ``module`` is insisted on is the mode's business,
    /// per `RadioMode.usesNodeNumber` and `RadioMode.usesModule` — demanding
    /// both would make one of them a field the operator has to fill in for no
    /// effect on the wire.
    func validated() throws -> NodeSettings {
        var trimmed = NodeSettings(
            mode: mode,
            host: host.trimmed,
            port: port,
            node: node.trimmed,
            module: module.trimmed.uppercased(),
            username: username.trimmed,
            callsign: callsign.trimmed.uppercased(),
            transmitTimeout: transmitTimeout)

        guard !trimmed.host.isEmpty else { throw ValidationError.missingHost }
        guard !trimmed.callsign.isEmpty else { throw ValidationError.missingCallsign }

        if mode.usesNodeNumber {
            guard !trimmed.node.isEmpty else { throw ValidationError.missingNode }
        }

        if mode.usesModule {
            guard !trimmed.module.isEmpty else { throw ValidationError.missingModule }
            // Already uppercased above, so ASCII plus letter is exactly A–Z.
            guard trimmed.module.count == 1, let letter = trimmed.module.first,
                letter.isASCII, letter.isLetter
            else { throw ValidationError.invalidModule }
        }

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
