// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Turns a host name into an IPv4 address.
///
/// **Why the app does this and the library does not.** The EchoLink proxy's
/// `OPEN` frame carries four raw octets, so nothing below `EchoLinkDestination`
/// resolves a name — and `docs/CLI.md` is explicit that this is deliberate:
/// baking a third party's server into a protocol library "would be a guess
/// about infrastructure rather than about the protocol". That is the right call
/// for a library. It is the wrong one for a phone, where it becomes "know an IP
/// address off the top of your head", and the addresses behind
/// `servers.echolink.org` are cloud-hosted and do change.
///
/// So the app resolves, and hands the library the octets it asked for.
protocol HostResolver: Sendable {
    /// The IPv4 address for `host`.
    ///
    /// A host that is already dotted quad is returned unchanged, so callers can
    /// pass whatever the operator typed without inspecting it first.
    func ipv4Address(for host: String) async throws -> String
}

enum HostResolverError: Error, Equatable, CustomStringConvertible {
    /// The name resolved, but to nothing with an IPv4 address.
    case noIPv4Address(host: String)

    /// The lookup itself failed — no such name, or no DNS to ask.
    case lookupFailed(host: String, detail: String)

    var description: String {
        switch self {
        case .noIPv4Address(let host):
            return """
                \(host) does not resolve to an IPv4 address. EchoLink's proxy carries four raw \
                octets, so an IPv6-only name cannot be used.
                """
        case .lookupFailed(let host, let detail):
            return """
                Could not look up \(host): \(detail). Check the spelling and that this device has \
                a network connection.
                """
        }
    }
}

/// Resolves through the system resolver.
///
/// `getaddrinfo` rather than `Network.framework`: PD-1 governs how the app moves
/// *packets*, and this opens no connection — it is a name lookup, the system
/// resolver is the thing that does it, and `NWConnection` would mean standing up
/// a whole connection to a port nobody wants to talk to just to read the address
/// back out of it.
struct SystemHostResolver: HostResolver {
    init() {}

    func ipv4Address(for host: String) async throws -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)

        // Already an address. Cheap, and it means a channel saved before this
        // existed still works without a lookup.
        if NodeSettings.isDottedQuad(trimmed) { return trimmed }

        // Off the calling actor: `getaddrinfo` blocks, and the callers are the
        // main actor (connecting) and a directory fetch. A blocked main actor
        // during a DNS timeout is a frozen app.
        return try await Task.detached(priority: .userInitiated) {
            try SystemHostResolver.lookUp(trimmed)
        }.value
    }

    /// The blocking lookup. Returns the first IPv4 answer.
    ///
    /// First rather than a choice among them: `servers.echolink.org` answers
    /// with several addresses and round-robins the order, so taking the first is
    /// how the operator gets spread across the pool rather than everybody
    /// landing on whichever one sorted lowest.
    private static func lookUp(_ host: String) throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET  // IPv4 only: four octets is what the proxy takes.
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)

        guard status == 0, let first = result else {
            let detail = String(cString: gai_strerror(status))
            throw HostResolverError.lookupFailed(host: host, detail: detail)
        }
        defer { freeaddrinfo(result) }

        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if current.pointee.ai_family == AF_INET, let address = current.pointee.ai_addr {
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let converted = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    pointer -> String? in
                    var sinAddr = pointer.pointee.sin_addr
                    guard inet_ntop(AF_INET, &sinAddr, &text, socklen_t(INET_ADDRSTRLEN)) != nil
                    else { return nil }
                    return String(cString: text)
                }
                if let converted { return converted }
            }
            node = current.pointee.ai_next
        }

        throw HostResolverError.noIPv4Address(host: host)
    }
}
