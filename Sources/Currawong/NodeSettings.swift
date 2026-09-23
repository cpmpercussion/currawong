// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How an AllStarLink node is reached: with credentials of our own, or as a
/// guest presenting a portal token.
///
/// Not a fourth ``RadioMode``: Web Transceiver is the same protocol to the same
/// nodes over the same port, differing only in which credentials the call
/// carries. A fourth mode would duplicate the whole AllStarLink form and store
/// for one substitution, and would imply WT reaches somewhere else. The two are
/// not interchangeable from the operator's side, so it is a choice they make:
///
/// | | Node secret | Web Transceiver |
/// |---|---|---|
/// | You need | an entry in that node's `iax.conf` | an allstarlink.org portal account |
/// | Set up by | the node's owner, per node, for you | nobody — the owner enables WT once, for everyone |
/// | You supply | a username and a secret | a token, which stands for your callsign |
///
/// The raw values land in `UserDefaults`, and `.nodeSecret`'s is deliberately
/// not `"nodeSecret"`: a test asserts that a channel's persisted encoding
/// contains no occurrence of the word "secret", and a raw value carrying it
/// would need an exception in that check.
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

/// Everything the app needs to reach a node, except the secret.
///
/// The split is load-bearing: this value is `Codable` and written to
/// `UserDefaults`, and the secret is not part of it, so there is no way to
/// accidentally persist a password by persisting the settings — it lives in
/// the Keychain, keyed by ``secretAccount``.
///
/// Names no library type: it carries a ``RadioMode`` and the union of all
/// three modes' fields, and the composition root turns one of these plus a
/// secret into a concrete destination. One type plus a mode, rather than one
/// type per mode, keeps the cost of a differing field (``node`` versus
/// ``module``) to a single `if` in ``validated()`` and one form; the price is
/// that a value always has one field that means nothing for its mode.
///
/// **This is a channel** (APP-4): one saved place the operator can go back to,
/// held in a list by ``ChannelSet``, named by ``name`` and identified by
/// ``id``. It was a single node before APP-4, which is why the type is still
/// called `NodeSettings` and why ``init(from:)`` copes with a blob that has
/// neither of those two fields.
struct NodeSettings: Equatable, Codable, Sendable, Identifiable {
    /// Stable identity, so a channel survives being renamed or re-pointed.
    ///
    /// Generated when a channel is created, never derived from its contents. A
    /// blob with no id is given a fresh one at decode. Not what the Keychain
    /// secret is filed under; see ``secretAccount``.
    var id: UUID

    /// What the operator calls this channel. May be empty, in which case the UI
    /// falls back to ``displayName``.
    var name: String

    /// Which network this node is reached over, and therefore which of the
    /// fields below are live.
    var mode: RadioMode

    /// Hostname or literal address of the node.
    ///
    /// Empty and unused in EchoLink (APP-13): the proxy is the operator's
    /// station infrastructure, not a property of one destination, and lives in
    /// ``EchoLinkProxySettings`` instead. An EchoLink node is named by ``peer``
    /// and ``node`` alone.
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
    /// ``EchoLinkProxySettings``, not part of a channel. The library takes this
    /// as four literal octets and resolves nothing, so a name will not do; the
    /// station browser fills it in from the directory listing.
    var peer: String

    /// **EchoLink.** The directory server's IPv4 address, or a host name.
    ///
    /// The library takes only a dotted quad and resolves nothing, but the app
    /// resolves a name before handing it over (see ``HostResolver``) — typing an
    /// IP address from memory is not something to ask of somebody with a phone.
    ///
    /// The directory login registers the station as available; skip it and
    /// every step still reports success while no node ever answers, so this
    /// being empty matters more than an empty optional usually does.
    var directoryServer: String

    /// The account the node authenticates us as. May be empty.
    ///
    /// Unused when ``allStarAccess`` is `.webTransceiver`: a WT call
    /// authenticates as a shared guest account the app fills in, and this field
    /// is hidden in that case. See `CompositionRoot`, where the guest
    /// credentials are named.
    var username: String

    /// **AllStarLink.** Whether this channel is reached with a node secret or as
    /// a Web Transceiver guest. Ignored in the other two modes.
    ///
    /// Part of the channel, not an app-wide setting: it is a fact about the
    /// node, since one may give us an `iax.conf` entry while the next has only
    /// WT switched on.
    var allStarAccess: AllStarLinkAccess

    /// The registered IAX2 port. Duplicated rather than imported from
    /// `IAX2Kit`: this type does not know which protocol is underneath it, and
    /// `IAX2Destination`'s own default is the authority on the wire.
    static let defaultPort: UInt16 = 4569

    /// The directory server a new EchoLink channel starts with.
    ///
    /// `servers`, not a regional name, since it round-robins the whole pool and
    /// they all serve the same directory. A name, not an address: the addresses
    /// behind it are cloud-hosted with no promise of stability.
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
    /// Per callsign, not per channel: the portal issues the token to an
    /// operator, and it resolves to their callsign on any WT-enabled node, so
    /// one token serves every WT channel. Separate from ``secretAccount(for:)``
    /// because a token is not a node secret — sharing the slot would file a
    /// portal credential under a node's name.
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
    /// Per callsign: EchoLink issues one account password with the callsign, so
    /// every EchoLink channel for that callsign shares it. A `static` because
    /// APP-12's settings screen edits the account with no channel in hand.
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
    /// ``displayName`` is empty for a channel with no name, no host and no
    /// node — exactly what `Add channel` hands over — so this falls back to
    /// "New channel", the same wording the connect form's placeholder uses,
    /// rather than a name that reads as a fault.
    var listDisplayName: String {
        let name = displayName
        return name.isEmpty ? "New channel" : name
    }

    /// Where this channel actually points, in the terms the mode uses.
    ///
    /// The companion to ``displayName``, not a fallback for it: `displayName`
    /// prefers the operator's own name, so "Sunday net" says nothing about
    /// where it goes, the way a radio still shows the frequency it is tuned to
    /// whether or not the memory has a name. Also makes an unsaved edit
    /// visible — the name stays put while the address underneath it changes.
    var addressDescription: String {
        switch mode {
        case .allStarLink:
            let target = host.isEmpty ? "no host" : host
            return node.isEmpty ? target : "node \(node) at \(target)"
        case .m17:
            let target = host.isEmpty ? "no reflector" : host
            return module.isEmpty ? target : "\(target) · module \(module)"
        case .echoLink:
            // The proxy is not a channel field (APP-13); the peer address is
            // the whole of where this goes.
            let target = peer.isEmpty ? "no address" : peer
            return node.isEmpty ? target : "\(node) · \(target)"
        }
    }

    /// Decodes settings, including a blob written before this type had a mode
    /// or a module.
    ///
    /// Hand-written because the synthesised initialiser treats a missing key as
    /// a failure: a non-optional field would make an older stored blob
    /// undecodable, `SettingsStore.load()` would return `nil`, and the operator
    /// would find their node details wiped by an app update. A missing mode
    /// decodes as `.allStarLink` — the only mode that existed when it was
    /// written — and a missing module is simply a field that mode never asks
    /// for, not corruption.
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
        // Absent means a channel saved before Web Transceiver existed: a
        // node-secret channel, not a corrupt one.
        self.allStarAccess =
            try container.decodeIfPresent(AllStarLinkAccess.self, forKey: .allStarAccess)
            ?? .nodeSecret
        // APP-13: a channel must not name a proxy, so a `host` surviving from a
        // build that kept the proxy there is dropped on read, same as in
        // ``validated()``. `UserDefaultsSettingsStore.loadEchoLinkProxy()`
        // rescues a private proxy from these blobs separately, as raw JSON.
        if self.mode.usesProxy {
            self.host = ""
            self.port = self.mode.defaultPort
        }

        // `callsign`, `operatorName`, `location` and `transmitTimeout` may be
        // present in an older blob; not read here, since the type no longer has
        // those fields and an unknown key is ignored. `loadIdentity()` and
        // `loadTransmitTimeout()` in `UserDefaultsSettingsStore` harvest them
        // once instead.
    }

    /// The Keychain account the secret for this node is filed under.
    ///
    /// Derived rather than stored, so it cannot drift out of step with the
    /// settings, and contains no secret material — it is an identifier, visible
    /// in a Keychain attribute.
    ///
    /// **The AllStarLink form is frozen** at `username@host:port/node`: changing
    /// that string by so much as a separator orphans every secret already
    /// stored under it. M17's `m17:` prefix keeps an unauthenticated link to a
    /// host from being mistaken for an authenticated AllStarLink connection to
    /// the same host.
    ///
    /// Takes the identity rather than a stored callsign — the callsign is the
    /// operator's, not the channel's — but the account strings are unchanged,
    /// so secrets already in the Keychain are still found. Uses
    /// ``OperatorIdentity/normalisedCallsign``, not `callsign`: the identity is
    /// stored as typed and only uppercased at `connect()`, and the secret is
    /// filed under the validated form, so reading under the typed form would
    /// lose a lower-case callsign's password every relaunch.
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

    /// **APP-14.** Whose secret a channel connects with, if anyone's.
    ///
    /// A property of the mode, not a single "is this Web Transceiver?" check in
    /// `connect()`: M17 has no secret at all, and EchoLink's password is one
    /// app-wide value the settings screen owns (APP-12), not a per-channel one
    /// — writing either through the AllStarLink node-secret path would store a
    /// secret in the wrong slot, or delete the EchoLink password by writing an
    /// empty field over it (``SecretStore`` treats empty as a removal).
    enum SecretOwnership: Equatable {
        /// The channel's own, filed per destination: an AllStarLink node secret.
        case channel(account: String)
        /// One password for the whole app, which **only the settings screen
        /// writes**. Connecting reads it and must never write it.
        case appWide(account: String)
        /// Nothing to store. M17 does not authenticate, and a Web Transceiver
        /// channel's token is not a secret and has a slot of its own.
        case none
    }

    func secretOwnership(for identity: OperatorIdentity) -> SecretOwnership {
        switch mode {
        case .allStarLink:
            return usesWebTransceiver ? .none : .channel(account: secretAccount(for: identity))
        case .m17:
            return .none
        case .echoLink:
            return .appWide(account: Self.echoLinkAccount(for: identity))
        }
    }

    /// Whether two channels point at the same place on the same network.
    ///
    /// Identity, name and the operator's own preferences are excluded: a
    /// channel renamed "Sunday net" is still the same reflector module, and
    /// offering to save it again under a different name fills the list with
    /// entries an operator cannot tell apart. Compared per mode, since the
    /// fields that name a destination differ.
    func isSamePlace(as other: NodeSettings) -> Bool {
        guard mode == other.mode else { return false }

        let sameEndpoint =
            host.caseInsensitiveCompare(other.host) == .orderedSame && port == other.port

        switch mode {
        case .allStarLink:
            // The access route counts: the same node reached with a secret and
            // reached as a WT guest carry different credentials, so collapsing
            // them would let a directory browse silently re-point a working
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
    /// `username` and the secret are not required: a node with no account
    /// configured expects neither. The callsign is required but is no longer a
    /// field here — see ``OperatorIdentity/validated()``, called alongside this
    /// by `RadioSession.connect()`.
    ///
    /// Which of ``node`` and ``module`` is insisted on is the mode's business
    /// (`RadioMode.usesNodeNumber`, `usesModule`): demanding both would make one
    /// a field the operator fills in for no effect on the wire.
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
        // `peer`. Cleared rather than merely unchecked, so a stale proxy in
        // `host` cannot survive the next save.
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
            // Empty is allowed and means "do not log in to the directory" — the
            // form warns rather than refuses, since the library treats an
            // absent directory server and an absent account password as the
            // pair they are. A host name is allowed too; the app resolves it
            // before the library sees it (``HostResolver``). What is refused is
            // neither: a typo that would otherwise resolve to nothing, much
            // later and further from the field it was typed in.
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
    /// Advisory, never a gate, like the library's own check: only the node
    /// decides whether a token works, and the login endpoint is expected to
    /// change (OQ-10), so refusing an unfamiliar format would turn a widened one
    /// into an app that cannot connect. The form warns and lets the operator
    /// press Connect anyway.
    ///
    /// Case matters: the portal issues lowercase, and this catches a token
    /// upper-cased by a field with autocapitalisation on.
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
