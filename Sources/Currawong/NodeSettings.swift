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
/// **This is a channel** (APP-4). One of these is one saved place the operator
/// can go back to, held in a list by ``ChannelSet``, named by ``name`` and
/// identified by ``id``. It was a single node before APP-4, which is why the
/// type is still called `NodeSettings` and why ``init(from:)`` has to cope with
/// a blob that has neither of those two fields.
struct NodeSettings: Equatable, Codable, Sendable, Identifiable {
    /// Stable identity, so a channel survives being renamed or re-pointed.
    ///
    /// Generated when a channel is created and never derived from its contents.
    /// A blob written before channels existed has no id and is given a fresh one
    /// at decode — it is one channel either way, and which UUID it gets does not
    /// matter as long as it keeps it afterwards.
    ///
    /// Note that this is deliberately **not** what the Keychain secret is filed
    /// under; see ``secretAccount``.
    var id: UUID

    /// What the operator calls this channel. May be empty, in which case the UI
    /// falls back to ``displayName``.
    var name: String

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

    /// **EchoLink.** The far node's IPv4 address, as a dotted quad.
    ///
    /// Separate from ``host`` because in EchoLink those are two different
    /// machines: `host` is the proxy the session is tunnelled through, and this
    /// is the node at the far end of the tunnel. The library takes it as four
    /// literal octets and resolves nothing, so a name will not do — the station
    /// browser exists to fill this in from the directory listing.
    var peer: String

    /// **EchoLink.** The proxy's password. `PUBLIC` on a public proxy, which is
    /// the only value ever observed on the wire and is not a secret.
    ///
    /// It lives here, in `UserDefaults`, rather than in the Keychain, and that
    /// is a judgement about `PUBLIC` rather than about passwords: the account
    /// password — the one that is genuinely secret — is in the Keychain, keyed
    /// by ``secretAccount``, and never in this type. An operator running a
    /// *private* proxy would be storing its password less carefully than their
    /// account password, which is worth knowing before doing it.
    var proxyPassword: String

    /// **EchoLink.** The directory server's IPv4 address, dotted quad.
    ///
    /// **A host name or a dotted quad.** The library takes only the quad — the
    /// proxy's `OPEN` carries four raw octets and it resolves nothing — but the
    /// app resolves a name before handing it over, because "know an IP address
    /// off the top of your head" is not a thing to ask of somebody holding a
    /// phone. See ``HostResolver``.
    ///
    /// The directory login is what *registers* the station as available. Skip it
    /// and every step still reports success while no node ever answers, so this
    /// being empty is a much bigger deal than an empty optional usually is.
    var directoryServer: String

    /// The account the node authenticates us as. May be empty.
    var username: String

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

    /// The literal string a public EchoLink proxy expects, and the only proxy
    /// password ever seen on the wire. Not a secret; see ``proxyPassword``.
    static let defaultProxyPassword = "PUBLIC"

    /// The directory server a new EchoLink channel starts with.
    ///
    /// `servers` rather than one of the regional names (`naeast`, `nasouth`,
    /// `europe`): it answers with the whole pool and round-robins the order, so
    /// it is the one choice that is not a guess about which region an operator
    /// is nearest — and they all serve the same directory anyway.
    ///
    /// A name and not an address on purpose. The addresses behind it are
    /// cloud-hosted and have no promise of stability, so an IP baked in here
    /// would be a defect with a delay on it.
    static let defaultDirectoryServer = "servers.echolink.org"

    init(
        id: UUID = UUID(),
        name: String = "",
        mode: RadioMode = .allStarLink,
        host: String = "",
        port: UInt16 = NodeSettings.defaultPort,
        node: String = "",
        module: String = "",
        peer: String = "",
        proxyPassword: String = NodeSettings.defaultProxyPassword,
        directoryServer: String = "",
        username: String = "",
        transmitTimeout: TimeInterval = NodeSettings.defaultTransmitTimeout
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.host = host
        self.port = port
        self.node = node
        self.module = module
        self.peer = peer
        self.proxyPassword = proxyPassword
        self.directoryServer = directoryServer
        self.username = username
        self.transmitTimeout = transmitTimeout
    }

    /// What the operator sees in the channel list: their own name for the
    /// channel, or the best description of it the fields allow.
    var displayName: String {
        let trimmedName = name.trimmed
        if !trimmedName.isEmpty { return trimmedName }

        switch mode {
        case .allStarLink:
            return node.isEmpty ? host : "\(node) at \(host)"
        case .m17:
            return module.isEmpty ? host : "\(host) module \(module)"
        case .echoLink:
            return node.isEmpty ? peer : node
        }
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
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.mode = try container.decodeIfPresent(RadioMode.self, forKey: .mode) ?? .allStarLink
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(UInt16.self, forKey: .port)
        self.node = try container.decode(String.self, forKey: .node)
        self.module = try container.decodeIfPresent(String.self, forKey: .module) ?? ""
        self.peer = try container.decodeIfPresent(String.self, forKey: .peer) ?? ""
        self.proxyPassword =
            try container.decodeIfPresent(String.self, forKey: .proxyPassword)
            ?? Self.defaultProxyPassword
        self.directoryServer =
            try container.decodeIfPresent(String.self, forKey: .directoryServer) ?? ""
        self.username = try container.decode(String.self, forKey: .username)
        // `callsign`, `operatorName` and `location` may be present in a blob
        // written before they became app-wide. They are deliberately not read
        // here: the type no longer has those fields, and an unknown key in a
        // keyed container is ignored. `UserDefaultsSettingsStore.loadIdentity()`
        // is what harvests them, once, so that an operator updating the app
        // does not have to retype them.
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
    /// Takes the identity rather than reading a stored callsign, since the
    /// callsign is the operator's and no longer the channel's — but the account
    /// *strings* are unchanged, so every secret already in the Keychain is still
    /// found under the same name.
    func secretAccount(for identity: OperatorIdentity) -> String {
        switch mode {
        case .allStarLink:
            return "\(username)@\(host):\(port)/\(node)"
        case .m17:
            return "m17:\(identity.callsign)@\(host):\(port)/\(module)"
        case .echoLink:
            return "echolink:\(identity.callsign)"
        }
    }

    /// Whether two channels point at the same place on the same network.
    ///
    /// Identity, name and the operator's own preferences are excluded: a
    /// channel renamed "Sunday net" is still the same reflector module, and
    /// offering to save it a second time under a different name is how a
    /// channel list fills up with entries an operator cannot tell apart.
    ///
    /// Compared per mode, because the fields that name a destination differ:
    /// AllStarLink dials a node number at a host, M17 links a module on a
    /// reflector, and EchoLink tunnels to a literal address — where the
    /// *address* decides who answers, so two entries with one callsign and
    /// different addresses are genuinely two places.
    func isSamePlace(as other: NodeSettings) -> Bool {
        guard mode == other.mode else { return false }

        let sameEndpoint =
            host.caseInsensitiveCompare(other.host) == .orderedSame && port == other.port

        switch mode {
        case .allStarLink:
            return sameEndpoint && node.trimmed == other.node.trimmed
        case .m17:
            return sameEndpoint
                && module.trimmed.uppercased() == other.module.trimmed.uppercased()
        case .echoLink:
            return peer.trimmed == other.peer.trimmed
                && node.trimmed.uppercased() == other.node.trimmed.uppercased()
        }
    }

    /// What is wrong with a set of settings the operator has typed.
    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case missingHost
        case missingNode
        case missingModule
        case invalidModule
        case missingPeerAddress
        case invalidPeerAddress
        case invalidDirectoryServer

        var description: String {
            switch self {
            case .missingPeerAddress:
                return """
                    Enter the node's IP address. Find it with the station browser \
                    rather than typing it — EchoLink node addresses change.
                    """
            case .invalidPeerAddress:
                return "A node address is four numbers separated by dots, such as 13.57.14.183."
            case .invalidDirectoryServer:
                return """
                    The directory server must be a host name such as servers.echolink.org, or an \
                    IP address as four numbers separated by dots.
                    """
            case .missingHost:
                return "Enter the node's host name or address."
            case .missingNode:
                return "Enter the node number to call."
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
    /// than sending blank ones. The callsign is required, but it is no longer
    /// here to check — see ``OperatorIdentity/validated()``, which
    /// `RadioSession.connect()` calls alongside this.
    ///
    /// Which of ``node`` and ``module`` is insisted on is the mode's business,
    /// per `RadioMode.usesNodeNumber` and `RadioMode.usesModule` — demanding
    /// both would make one of them a field the operator has to fill in for no
    /// effect on the wire.
    func validated() throws -> NodeSettings {
        var trimmed = NodeSettings(
            id: id,
            name: name.trimmed,
            mode: mode,
            host: host.trimmed,
            port: port,
            node: node.trimmed,
            module: module.trimmed.uppercased(),
            peer: peer.trimmed,
            proxyPassword: proxyPassword.trimmed.isEmpty
                ? Self.defaultProxyPassword : proxyPassword.trimmed,
            directoryServer: directoryServer.trimmed,
            username: username.trimmed,
            transmitTimeout: transmitTimeout)

        guard !trimmed.host.isEmpty else { throw ValidationError.missingHost }

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

        if mode.usesProxy {
            guard !trimmed.peer.isEmpty else { throw ValidationError.missingPeerAddress }
            guard Self.isDottedQuad(trimmed.peer) else {
                throw ValidationError.invalidPeerAddress
            }
            // Empty is allowed and means "do not log in to the directory", which
            // the form warns about rather than refuses: it is a legitimate
            // experiment, and the library treats an absent directory server and
            // an absent account password as the pair they are.
            //
            // A host name is allowed too, and is now the default — the app
            // resolves it before the library sees it (``HostResolver``). What is
            // still refused is something that is neither: an address with a
            // typo in it, which would otherwise resolve to nothing much later
            // and much further away from the field it was typed in.
            if !trimmed.directoryServer.isEmpty {
                guard Self.isDottedQuad(trimmed.directoryServer)
                    || Self.isPlausibleHostName(trimmed.directoryServer)
                else {
                    throw ValidationError.invalidDirectoryServer
                }
            }
        }

        if trimmed.port == 0 { trimmed.port = mode.defaultPort }

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

    /// Whether a string is four decimal octets separated by dots.
    ///
    /// The same shape `EchoLinkPeerAddress(_ dottedQuad:)` accepts, checked here
    /// so the operator hears about a typo while they are still looking at the
    /// field rather than as a failed connection later. Duplicating the rule is
    /// the price of this layer not importing the library; the rule itself is
    /// four small numbers and is not going to drift.
    static func isDottedQuad(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && UInt8(part) != nil
        }
    }

    /// Whether a string could be a host name worth trying to resolve.
    ///
    /// Deliberately permissive: this exists to catch `129.213.119` and
    /// `naeast.echolink` typed as `naeast..echolink.org`, not to police the DNS.
    /// Anything that gets past here and does not exist fails at resolution with
    /// a message that names it, which is a perfectly good place to find out.
    ///
    /// Requires a dot, because a single label is far more likely to be a
    /// half-typed address than a real host somebody meant.
    static func isPlausibleHostName(_ text: String) -> Bool {
        guard text.count <= 253, text.contains(".") else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }

        // All-numeric labels are an address being typed, not a name. `129.213.119`
        // is otherwise a perfectly well-formed host name as far as the rules
        // below are concerned, and treating it as one would send a dropped octet
        // off to the resolver instead of reporting it here.
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return false }

        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                && label.first != "-" && label.last != "-"
        }
    }

    /// Parses a port the operator typed. Empty means "the default", not zero —
    /// a cleared field should connect to the mode's own port, not fail.
    ///
    /// **The mode has to be passed in**, because "the default" is 4569, 17000 or
    /// 8100 depending on it. An earlier version took no mode and returned 4569
    /// for every one of them, so clearing the port field in EchoLink mode
    /// silently pointed the proxy connection at the IAX2 port.
    static func parsePort(_ text: String, for mode: RadioMode) -> UInt16? {
        let trimmed = text.trimmed
        if trimmed.isEmpty { return mode.defaultPort }
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
