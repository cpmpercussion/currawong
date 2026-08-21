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
/// How an AllStarLink node is reached: with credentials of our own, or as a
/// guest presenting a portal token.
///
/// **Not a fourth ``RadioMode``.** Web Transceiver is the same protocol to the
/// same nodes over the same port; what differs is which credentials the call
/// carries. A fourth mode would have duplicated the whole AllStarLink third of
/// the form and the store to express one substitution, and would have implied to
/// an operator that WT reaches somewhere else.
///
/// The two are not interchangeable from the operator's side, which is why this
/// is a choice they make rather than something the app infers:
///
/// | | Node secret | Web Transceiver |
/// |---|---|---|
/// | You need | an entry in that node's `iax.conf` | an allstarlink.org portal account |
/// | Set up by | the node's owner, per node, for you | nobody — the owner enables WT once, for everyone |
/// | You supply | a username and a secret | a token, which stands for your callsign |
/// The raw values are what land in `UserDefaults`, and `.nodeSecret`'s is
/// deliberately **not** `"nodeSecret"`: one of this app's cheapest safety nets is
/// a test asserting that the persisted encoding of a channel contains no
/// occurrence of the word "secret" anywhere in it, and a raw value carrying it
/// would have to weaken that check into something with an exception in it.
enum AllStarLinkAccess: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A username and secret the node's owner configured for us. The route the
    /// app has always taken.
    case nodeSecret = "nodeLogin"

    /// A Web Transceiver token from an allstarlink.org portal account (IAX-12,
    /// IAX-13). Reaches any node whose owner has enabled WT, with no per-node
    /// arrangement at all.
    case webTransceiver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nodeSecret: return "Node secret"
        case .webTransceiver: return "Web Transceiver"
        }
    }
}

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
    ///
    /// **Empty and unused in EchoLink** (APP-13). It held the proxy there, which
    /// was the wrong owner: a proxy is the operator's station infrastructure, not
    /// a property of one destination, and persisting it here meant a public proxy
    /// found by probing was written into a channel and reused for ever. It now
    /// lives in ``EchoLinkProxySettings``, and an EchoLink node is named by
    /// ``peer`` and ``node`` alone — which ``isSamePlace(as:)`` had already
    /// assumed.
    var host: String

    /// UDP port. 4569 is the registered IAX2 port and the default everywhere.
    /// Unused in EchoLink, with ``host``.
    var port: UInt16

    /// The number being called — an AllStar node number such as `"55553"`.
    /// Empty and unused in M17, which links a ``module`` instead.
    var node: String

    /// The M17 reflector module to link: a single letter A–Z. Empty and unused
    /// in AllStarLink.
    var module: String

    /// **EchoLink.** The far node's IPv4 address, as a dotted quad.
    ///
    /// The node at the far end of the proxy tunnel — the proxy itself is
    /// ``EchoLinkProxySettings`` and is not part of a channel at all. The library
    /// takes this as four literal octets and resolves nothing, so a name will not
    /// do; the station browser exists to fill it in from the directory listing.
    var peer: String

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
    ///
    /// **Unused when ``allStarAccess`` is `.webTransceiver`**: a WT call
    /// authenticates as a shared guest account, which the app fills in rather
    /// than asking for, and this field is hidden in that case. See
    /// `CompositionRoot`, which is where the guest credentials are named.
    var username: String

    /// **AllStarLink.** Whether this channel is reached with a node secret or as
    /// a Web Transceiver guest. Ignored in the other two modes.
    ///
    /// Part of the channel rather than an app-wide setting, because it is a fact
    /// about the node: one may have given us an `iax.conf` entry and the next
    /// may only have WT switched on.
    var allStarAccess: AllStarLinkAccess

    /// The registered IAX2 port. Duplicated rather than imported from
    /// `IAX2Kit`, because this type is not allowed to know which protocol is
    /// underneath it; the composition root is what reconciles the two, and
    /// `IAX2Destination`'s own default is the authority on the wire.
    static let defaultPort: UInt16 = 4569

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
        directoryServer: String = "",
        username: String = "",
        allStarAccess: AllStarLinkAccess = .nodeSecret
    ) {
        self.allStarAccess = allStarAccess
        self.id = id
        self.name = name
        self.mode = mode
        self.host = host
        self.port = port
        self.node = node
        self.module = module
        self.peer = peer
        self.directoryServer = directoryServer
        self.username = username
    }

    /// Whether this channel is a Web Transceiver guest call.
    ///
    /// The mode is checked as well as the access, so the field cannot mean
    /// anything in a mode that has no such route: an M17 channel carrying a
    /// stale `.webTransceiver` from having once been an AllStar one is still
    /// just an M17 channel.
    var usesWebTransceiver: Bool {
        mode == .allStarLink && allStarAccess == .webTransceiver
    }

    /// The Keychain account the Web Transceiver token is filed under.
    ///
    /// **Per callsign, not per channel**, and that is the whole point: the token
    /// is issued by the portal to an operator and resolves to their callsign on
    /// any WT-enabled node, so one token serves every WT channel. It is a
    /// separate slot from ``secretAccount(for:)`` because a token is not a node
    /// secret — writing it there would overwrite the secret of any channel that
    /// happened to share the account string, and would file a portal credential
    /// under a node's name.
    ///
    /// Filled in by APP-12's portal login; typed or pasted until then.
    func webTransceiverAccount(for identity: OperatorIdentity) -> String {
        NodeSettings.webTransceiverAccount(for: identity)
    }

    /// The same slot, reachable without a channel: APP-12's settings screen
    /// stores a token before any channel has been chosen to use it on.
    static func webTransceiverAccount(for identity: OperatorIdentity) -> String {
        "wt-token:\(identity.normalisedCallsign)"
    }

    /// The Keychain account an EchoLink account password is filed under.
    ///
    /// Per callsign, and always has been: EchoLink issues one account password
    /// with the callsign, so every EchoLink channel for that callsign shares it.
    /// A `static` because APP-12's settings screen edits the account with no
    /// channel in hand — and two spellings of one Keychain key is how a stored
    /// password becomes unreadable.
    static func echoLinkAccount(for identity: OperatorIdentity) -> String {
        "echolink:\(identity.normalisedCallsign)"
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

    /// **APP-22.** What the channel list calls this channel, including before it
    /// has anything in it.
    ///
    /// ``displayName`` is empty for a channel with no name, no host and no node —
    /// which is exactly what `Add channel` hands over — and the list used to fall
    /// back to "Unnamed channel" for it. That was the right words for a *stored*
    /// row nobody could explain, and the wrong ones for a row the operator has
    /// just this moment created: it reads as a fault rather than as an
    /// invitation. The connect form's own placeholder already says "New channel";
    /// this is the same wording, in the list.
    var listDisplayName: String {
        let name = displayName
        return name.isEmpty ? "New channel" : name
    }

    /// Where this channel actually points, in the terms the mode uses.
    ///
    /// The companion to ``displayName``, and deliberately *not* a fallback for
    /// it: `displayName` prefers the operator's own name, so a channel called
    /// "Sunday net" says nothing about where it goes. A radio shows the
    /// frequency it is tuned to whether or not the memory has a name, and this
    /// is that line. It also makes an unsaved edit visible — the name stays put
    /// while the address underneath it changes.
    var addressDescription: String {
        switch mode {
        case .allStarLink:
            let target = host.isEmpty ? "no host" : host
            return node.isEmpty ? target : "node \(node) at \(target)"
        case .m17:
            let target = host.isEmpty ? "no reflector" : host
            return module.isEmpty ? target : "\(target) · module \(module)"
        case .echoLink:
            // The proxy is not a channel field (APP-13), so the peer address is
            // the whole of where this goes.
            let target = peer.isEmpty ? "no address" : peer
            return node.isEmpty ? target : "\(node) · \(target)"
        }
    }

    /// Decodes settings, **including settings written before this type had a
    /// mode or a module.**
    ///
    /// Hand-written for exactly one reason: the synthesised initialiser treats
    /// a missing key as a failure, so adding a non-optional field would make
    /// every stored settings blob undecodable, `SettingsStore.load()` would
    /// return `nil`, and the operator would find their node details wiped by an
    /// app update. A missing module is not corruption, it is an older file.
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
        self.directoryServer =
            try container.decodeIfPresent(String.self, forKey: .directoryServer) ?? ""
        self.username = try container.decode(String.self, forKey: .username)
        // Absent means a channel saved before Web Transceiver existed, which is
        // a node-secret channel rather than a corrupt one — the same reasoning
        // as the missing `mode` above.
        self.allStarAccess =
            try container.decodeIfPresent(AllStarLinkAccess.self, forKey: .allStarAccess)
            ?? .nodeSecret
        // **APP-13.** A channel written by a build that kept the proxy in `host`
        // still has one in the blob, and the whole point of hoisting it is that a
        // channel must not name a proxy. Dropped here as well as in
        // ``validated()`` so it is gone the moment the channel is read, whatever
        // path saves it next. The migration that *rescues* a private proxy from
        // these blobs reads them as raw JSON — see
        // `UserDefaultsSettingsStore.loadEchoLinkProxy()` — so it is unaffected by
        // this, and it runs on the same launch.
        if self.mode.usesProxy {
            self.host = ""
            self.port = self.mode.defaultPort
        }

        // `callsign`, `operatorName`, `location` and `transmitTimeout` may all be
        // present in a blob written before they became app-wide. They are
        // deliberately not read here: the type no longer has those fields, and an
        // unknown key in a keyed container is ignored.
        // `UserDefaultsSettingsStore.loadIdentity()` and
        // `loadTransmitTimeout()` are what harvest them, once, so that an
        // operator updating the app does not have to set them again.
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
    ///
    /// **``OperatorIdentity/normalisedCallsign``, not `callsign`.** The identity
    /// is stored as typed and only uppercased at `connect()`, so the two paths
    /// disagreed: the secret was *written* under the validated `VK1XYZ` and, on
    /// the next launch, *read* back under whatever had been typed. A callsign
    /// entered in lower case therefore lost its password every relaunch — the
    /// field came up empty, which reads as the app having forgotten it.
    /// Normalising here fixes the read without moving anything: what is already
    /// in the Keychain was written in this form.
    func secretAccount(for identity: OperatorIdentity) -> String {
        switch mode {
        case .allStarLink:
            return "\(username)@\(host):\(port)/\(node)"
        case .m17:
            return "m17:\(identity.normalisedCallsign)@\(host):\(port)/\(module)"
        case .echoLink:
            return Self.echoLinkAccount(for: identity)
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
            // The access route counts. The same node reached with a secret and
            // reached as a WT guest is one place on the air but two channels
            // here: they carry different credentials, and collapsing them would
            // mean a directory or a browse quietly re-pointing a working
            // node-secret channel at the guest account.
            return sameEndpoint && node.trimmed == other.node.trimmed
                && allStarAccess == other.allStarAccess
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
            directoryServer: directoryServer.trimmed,
            username: username.trimmed,
            allStarAccess: allStarAccess)

        // EchoLink names no host: the proxy is app-wide (APP-13) and the node is
        // `peer`. Cleared rather than merely unchecked, so a channel written by a
        // build that did hold a proxy here cannot carry it forward the next time
        // the draft is saved — which is the whole of how the old fault persisted.
        if mode.usesProxy {
            trimmed.host = ""
            trimmed.port = mode.defaultPort
        } else {
            guard !trimmed.host.isEmpty else { throw ValidationError.missingHost }
        }

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

        return trimmed
    }

    /// The length of every Web Transceiver token observed so far: 12 lowercase
    /// hexadecimal characters.
    static let webTransceiverTokenLength = 12

    /// Whether a token looks like the ones the portal has issued.
    ///
    /// **Advisory, never a gate.** The library takes the same position and for
    /// the same reason: only the node decides whether a token works, and the
    /// login endpoint is expected to be replaced (OQ-10), so refusing an
    /// unfamiliar-looking token would turn a widened format into an app that
    /// cannot connect. The form says "that does not look like a token" and lets
    /// the operator press Connect anyway.
    ///
    /// Case matters: the portal issues lowercase, and an upper-cased token is the
    /// mistake this catches — a token typed in a field with autocapitalisation on
    /// is not the token.
    static func isPlausibleWebTransceiverToken(_ text: String) -> Bool {
        let trimmed = text.trimmed
        return trimmed.count == webTransceiverTokenLength
            && trimmed.allSatisfy { $0.isHexDigit && !$0.isUppercase }
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
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
