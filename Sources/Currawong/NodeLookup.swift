// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What AllStarLink's directory knows about a node number: the fraction of
/// the API's answer that helps an operator decide whether to call.
struct NodeRegistration: Equatable, Sendable {
    /// The node number that was looked up.
    var node: String

    /// Where it registered from: what the lookup is for.
    var host: String

    /// The port it registered on.
    var port: UInt16

    /// The callsign the node is licensed under.
    var callsign: String?

    /// The directory's free-text description: a frequency, a hub name, a town.
    var description: String?

    /// Whether the directory calls the node active.
    var isActive: Bool

    /// The node's page on AllStarLink's stats site, built from the node
    /// number. `nil` unless the number is digits, so typed text never reaches
    /// a URL.
    var dashboard: URL? {
        let trimmed = node.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber)
        else { return nil }
        return URL(string: "https://stats.allstarlink.org/nodeinfo.cgi?node=\(trimmed)")
    }

    /// `settings` with the answer filled in. Host and port always overwrite,
    /// so a lookup refreshes a moved node; the callsign fills the name only if
    /// the operator has not named the channel.
    func applied(to settings: NodeSettings) -> NodeSettings {
        var settings = settings
        settings.host = host
        settings.port = port

        if let callsign, !callsign.isEmpty,
            settings.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            settings.name = callsign
        }

        return settings
    }

    /// "WB6NIL · ASL Public Hub · 18.224.69.177", skipping whatever is missing.
    var summary: String {
        var parts: [String] = []
        if let callsign, !callsign.isEmpty { parts.append(callsign) }
        if let description, !description.isEmpty { parts.append(description) }
        parts.append(host)
        return parts.joined(separator: " · ")
    }
}

/// Turns an AllStarLink node number into an address. A lookup rather than a
/// browser, because operators already know the number. A protocol so tests
/// need no network.
protocol NodeLookup: Sendable {
    func registration(forNode node: String) async throws -> NodeRegistration
}

/// Why a node number did not turn into an address.
enum NodeLookupError: Error, Equatable, CustomStringConvertible {
    /// Nothing was typed.
    case missingNode

    /// The directory has no such node.
    case notListed(node: String)

    /// Listed, but with no address on file (private or never registered).
    case notRegistered(node: String)

    case unreachable(detail: String)
    case malformed(detail: String)

    var description: String {
        switch self {
        case .missingNode:
            return "Enter a node number first."
        case .notListed(let node):
            return """
                AllStarLink does not list node \(node). Check the number — or the node may be \
                private, in which case its owner has to give you the address.
                """
        case .notRegistered(let node):
            return """
                Node \(node) is listed but has not registered an address. It may be offline, or \
                private. Enter the address by hand if you have it.
                """
        case .unreachable(let detail):
            return """
                Could not reach the AllStarLink directory: \(detail). The lookup needs an \
                internet connection; the node itself does not.
                """
        case .malformed(let detail):
            return "The AllStarLink directory answered with something unexpected: \(detail)."
        }
    }
}

/// Looks a node up through AllStarLink's public stats API: unauthenticated,
/// one node per request, `404` with `[]` for an unknown number. The address is
/// where the node last registered, not proof it is up.
struct AllStarLinkNodeLookup: NodeLookup {
    static let endpoint = URL(string: "https://stats.allstarlink.org/api/stats/")!

    /// The registered IAX2 port, if the directory does not say.
    static let defaultPort: UInt16 = 4569

    private let endpoint: URL
    private let load: @Sendable (URL) async throws -> (Data, URLResponse)

    init(
        endpoint: URL = AllStarLinkNodeLookup.endpoint,
        load: @escaping @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.waitsForConnectivity = false
            return try await URLSession(configuration: configuration).data(from: url)
        }
    ) {
        self.endpoint = endpoint
        self.load = load
    }

    func registration(forNode node: String) async throws -> NodeRegistration {
        let trimmed = node.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NodeLookupError.missingNode }

        // Percent-encoded: a stray slash in free text would change the URL.
        guard
            let encoded = trimmed.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics),
            let url = URL(string: encoded, relativeTo: endpoint)
        else { throw NodeLookupError.notListed(node: trimmed) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await load(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NodeLookupError.unreachable(detail: error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            // 404 is an ordinary "no such node".
            if http.statusCode == 404 { throw NodeLookupError.notListed(node: trimmed) }
            guard (200..<300).contains(http.statusCode) else {
                throw NodeLookupError.unreachable(detail: "the server answered \(http.statusCode)")
            }
        }

        return try Self.parse(data, node: trimmed)
    }

    /// Reads the `node` object out of a stats response. Separate from the
    /// fetch so it is testable against bytes.
    static func parse(_ data: Data, node: String) throws -> NodeRegistration {
        // `[]` is the 404 body; handled here too in case a 200 ever carries it.
        if let empty = try? JSONDecoder().decode([String].self, from: data), empty.isEmpty {
            throw NodeLookupError.notListed(node: node)
        }

        let response: StatsResponse
        do {
            response = try JSONDecoder().decode(StatsResponse.self, from: data)
        } catch {
            throw NodeLookupError.malformed(detail: "\(error)")
        }

        let entry = response.node
        guard let address = entry.ipaddr?.trimmingCharacters(in: .whitespaces), !address.isEmpty
        else { throw NodeLookupError.notRegistered(node: node) }

        return NodeRegistration(
            node: node,
            host: address,
            port: entry.port ?? defaultPort,
            callsign: entry.callsign?.nonBlank,
            description: entry.node_frequency?.nonBlank,
            // Only an explicit "Active" counts.
            isActive: entry.Status?.caseInsensitiveCompare("Active") == .orderedSame)
    }

    private struct StatsResponse: Decodable {
        var node: NodeEntry
    }

    /// Named exactly as the API names them.
    private struct NodeEntry: Decodable {
        var Status: String?
        var ipaddr: String?
        var port: UInt16?
        var callsign: String?
        var node_frequency: String?
    }
}

extension String {
    fileprivate var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The state behind the "look it up" button. A second press replaces a
/// lookup in flight rather than racing it.
@MainActor
final class NodeLocator: ObservableObject {
    @Published private(set) var isSearching = false

    /// The last node found, which the form has already been filled in from.
    @Published private(set) var found: NodeRegistration?

    /// Why the last lookup found nothing, in words the operator can act on.
    @Published private(set) var failure: String?

    private let lookup: NodeLookup
    private var task: Task<Void, Never>?

    /// Bumped by every ``find(node:then:)``, so a superseded lookup can tell.
    private var generation = 0

    init(lookup: NodeLookup) {
        self.lookup = lookup
    }

    /// Looks `node` up and hands the answer to `apply`, which owns the form's
    /// fields.
    func find(node: String, then apply: @escaping @MainActor (NodeRegistration) -> Void) {
        task?.cancel()

        isSearching = true
        failure = nil
        found = nil
        generation += 1
        let generation = generation

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.isSearching = false } }

            do {
                let registration = try await self.lookup.registration(forNode: node)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.found = registration
                apply(registration)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.failure = "\(error)"
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }

    /// Forgets the last answer, when the node number changes.
    func clear() {
        cancel()
        found = nil
        failure = nil
    }
}
