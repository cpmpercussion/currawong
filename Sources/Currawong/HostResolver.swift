// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Turns a host name into an IPv4 address. The app resolves because the
/// EchoLink library takes raw octets and deliberately resolves nothing.
protocol HostResolver: Sendable {
    /// The IPv4 address for `host`; a dotted quad is returned unchanged.
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

/// Resolves with `getaddrinfo`. PD-1 governs moving packets, and this opens no
/// connection.
struct SystemHostResolver: HostResolver {
    init() {}

    func ipv4Address(for host: String) async throws -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)

        // Already an address: no lookup.
        if NodeSettings.isDottedQuad(trimmed) { return trimmed }

        // Off the calling actor: `getaddrinfo` blocks, and a DNS timeout on
        // the main actor freezes the app.
        return try await Task.detached(priority: .userInitiated) {
            try SystemHostResolver.lookUp(trimmed)
        }.value
    }

    /// The blocking lookup. Returns the first IPv4 answer, which keeps
    /// round-robin DNS spreading operators across a pool.
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
