// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How an AllStarLink node is reached: with credentials of our own, or as a
/// guest presenting a portal token.
///
/// Not a fourth ``RadioMode``: Web Transceiver is the same protocol to the same
/// nodes, differing only in which credentials the call carries.
///
/// The raw values are persisted. `.nodeSecret`'s is not `"nodeSecret"` because
/// a test asserts a channel's encoding never contains the word "secret".
enum AllStarLinkAccess: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A username and secret the node's owner configured for us.
    case nodeSecret = "nodeLogin"

    /// A token from an allstarlink.org portal account (IAX-12, IAX-13). Reaches
    /// any node whose owner has enabled WT, with no per-node arrangement.
    case webTransceiver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nodeSecret: return "Node secret"
        case .webTransceiver: return "Web Transceiver"
        }
    }
}

/// A channel (APP-4): everything the app needs to reach one destination,
/// except the secret.
///
/// Written to `UserDefaults`; the secret is deliberately not part of it, so
/// persisting settings can never persist a password. The secret lives in the
/// Keychain under ``secretAccount(for:)``.
///
/// Names no library type. It carries a ``RadioMode`` and the union of all three
/// modes' fields, so some field always means nothing for the current mode; the
/// composition root turns it into a concrete destination. Held in a list by
/// ``ChannelSet``.
struct NodeSettings: Equatable, Codable, Sendable, Identifiable {
    /// Stable identity, so a channel survives being renamed or re-pointed. Not
    /// what the Keychain secret is filed under; see ``secretAccount(for:)``.
    var id: UUID

    /// What the operator calls this channel. May be empty, in which case the UI
    /// falls back to ``displayName``.
    var name: String

    /// Which network, and therefore which of the fields below are live.
    var mode: RadioMode

    /// Hostname or literal address of the node. Empty in EchoLink, where the
    /// proxy is app-wide (``EchoLinkProxySettings``, APP-13) and the node is
    /// named by ``peer`` and ``node``.
    var host: String

    /// UDP port. Unused in EchoLink, with ``host``.
    var port: UInt16

    /// The number being called — an AllStar node number such as `"55553"`.
    /// Empty and unused in M17, which links a ``module`` instead.
    var node: String

    /// The M17 reflector module to link: a single letter A–Z. Empty and unused
    /// in AllStarLink.
    var module: String

    /// **EchoLink.** The far node's IPv4 address, as a dotted quad. The
    /// library takes four literal octets and resolves nothing, so a name will
    /// not do; the station browser fills it in.
    var peer: String

    /// **EchoLink.** The directory server's IPv4 address, or a host name the
    /// app resolves first (``HostResolver``). Empty skips the directory login,
    /// after which every step still reports success but no node ever answers.
    var directoryServer: String

    /// The account the node authenticates us as. May be empty. Unused for Web
    /// Transceiver, which uses a guest account named in `CompositionRoot`.
    var username: String

    /// **AllStarLink.** Node secret or Web Transceiver guest. Per channel,
    /// because it is a fact about the node. Ignored in the other modes.
    var allStarAccess: AllStarLinkAccess

    /// The registered IAX2 port, duplicated so this type need not import
    /// `IAX2Kit`.
    static let defaultPort: UInt16 = 4569

    /// The directory server a new EchoLink channel starts with: the pool's
    /// round-robin name, since the addresses behind it are not stable.
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

    /// Whether this channel is a Web Transceiver guest call. Checks the mode
    /// too, so a stale `.webTransceiver` on a non-AllStar channel means nothing.
    var usesWebTransceiver: Bool {
        mode == .allStarLink && allStarAccess == .webTransceiver
    }

    /// The Keychain account the Web Transceiver token is filed under: per
    /// callsign, since one portal token serves every WT channel, and separate
    /// from ``secretAccount(for:)`` because a token is not a node secret.
    func webTransceiverAccount(for identity: OperatorIdentity) -> String {
        NodeSettings.webTransceiverAccount(for: identity)
    }

    /// The same slot, for the settings screen, which has no channel in hand.
    static func webTransceiverAccount(for identity: OperatorIdentity) -> String {
        "wt-token:\(identity.normalisedCallsign)"
    }

    /// The Keychain account an EchoLink account password is filed under: one
    /// per callsign, shared by every EchoLink channel.
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

    /// What the channel list calls this channel: ``displayName``, or "New
    /// channel" for a blank one, matching the connect form's placeholder.
    var listDisplayName: String {
        let name = displayName
        return name.isEmpty ? "New channel" : name
    }

    /// Where this channel points, in the mode's terms. Shown alongside
    /// ``displayName``, which prefers the operator's own name and so says
    /// nothing about the destination.
    var addressDescription: String {
        switch mode {
        case .allStarLink:
            let target = host.isEmpty ? "no host" : host
            return node.isEmpty ? target : "node \(node) at \(target)"
        case .m17:
            let target = host.isEmpty ? "no reflector" : host
            return module.isEmpty ? target : "\(target) · module \(module)"
        case .echoLink:
            let target = peer.isEmpty ? "no address" : peer
            return node.isEmpty ? target : "\(node) · \(target)"
        }
    }

    /// Decodes settings, including older blobs missing later fields.
    ///
    /// Hand-written because the synthesised decoder fails on a missing key,
    /// which would wipe the operator's channels on an app update. A missing
    /// mode is `.allStarLink`, the only mode older blobs can have meant.
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
        // Absent in blobs older than Web Transceiver.
        self.allStarAccess =
            try container.decodeIfPresent(AllStarLinkAccess.self, forKey: .allStarAccess)
            ?? .nodeSecret
        // A channel never names a proxy (APP-13), so an old EchoLink `host` is
        // dropped, as in ``validated()``. `loadEchoLinkProxy()` rescues it.
        if self.mode.usesProxy {
            self.host = ""
            self.port = self.mode.defaultPort
        }

        // Older blobs may carry identity and timeout fields; `SettingsStore`
        // harvests those separately.
    }

    /// The Keychain account the secret for this node is filed under. Derived,
    /// so it cannot drift from the settings, and not secret itself.
    ///
    /// **These strings are frozen:** changing one by so much as a separator
    /// orphans every secret stored under it. The callsign is the normalised
    /// form, because secrets are filed under the validated callsign.
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

    /// Whose secret a channel connects with, if anyone's (APP-14).
    ///
    /// Writing through the wrong slot would misfile a secret, or delete the
    /// EchoLink password by writing an empty field over it (``SecretStore``
    /// treats empty as a removal).
    enum SecretOwnership: Equatable {
        /// An AllStarLink node secret, filed per destination.
        case channel(account: String)
        /// One app-wide password, which **only the settings screen writes**.
        case appWide(account: String)
        /// Nothing to store: M17, or a Web Transceiver token (its own slot).
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

    /// Whether two channels point at the same place on the same network,
    /// ignoring identity and name.
    func isSamePlace(as other: NodeSettings) -> Bool {
        guard mode == other.mode else { return false }

        let sameEndpoint =
            host.caseInsensitiveCompare(other.host) == .orderedSame && port == other.port

        switch mode {
        case .allStarLink:
            // Access counts: collapsing it would let a directory browse
            // re-point a node-secret channel at the guest account.
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

    /// Trimmed, normalised settings, or an error naming the bad field. Only the
    /// mode's own fields are required; the callsign is checked separately by
    /// ``OperatorIdentity/validated()``.
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

        // Cleared, not just unchecked, so a stale proxy in `host` cannot
        // survive the next save.
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
            // Empty means no directory login (the form warns). Otherwise it
            // must be an address or a plausible host name, so a typo is caught
            // here rather than at resolution.
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

    /// The length of every Web Transceiver token seen so far.
    static let webTransceiverTokenLength = 12

    /// Whether a token looks like the portal's: 12 lowercase hex characters.
    ///
    /// Advisory, never a gate, as in the library: only the node decides, and
    /// the format may change (OQ-10). Case matters, to catch autocapitalisation.
    static func isPlausibleWebTransceiverToken(_ text: String) -> Bool {
        let trimmed = text.trimmed
        return trimmed.count == webTransceiverTokenLength
            && trimmed.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Whether a string is four decimal octets separated by dots: the shape
    /// the library's `EchoLinkPeerAddress` accepts, checked here to catch a
    /// typo at the field.
    static func isDottedQuad(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && UInt8(part) != nil
        }
    }

    /// Whether a string could be a host name worth resolving. Permissive: it
    /// catches typos like `129.213.119` or `naeast..echolink.org`, and requires
    /// a dot, since a single label is more likely a half-typed address.
    static func isPlausibleHostName(_ text: String) -> Bool {
        guard text.count <= 253, text.contains(".") else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }

        // All-numeric labels are an address with an octet missing, not a name.
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return false }

        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                && label.first != "-" && label.last != "-"
        }
    }

    /// Parses a port the operator typed. Empty means the mode's own default
    /// port, which differs per mode, not zero.
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
