// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What AllStarLink's directory knows about a node number.
///
/// The app's own vocabulary, and deliberately a fraction of what the API
/// returns — it also carries server affiliation, registration timestamps,
/// key-up statistics and a linked-node tree, none of which help an operator
/// decide whether to call.
struct NodeRegistration: Equatable, Sendable {
    /// The node number that was looked up.
    var node: String

    /// Where it registered from. This is the field the whole lookup exists to
    /// obtain.
    var host: String

    /// The port it registered on — 4569 almost always, and not worth assuming.
    var port: UInt16

    /// The callsign the node is licensed under.
    var callsign: String?

    /// The directory's free-text description: a frequency, a hub name, a town.
    var description: String?

    /// Whether the directory calls the node active.
    var isActive: Bool

    /// The node's page on AllStarLink's stats site, the counterpart to an M17
    /// reflector's dashboard.
    ///
    /// `https://stats.allstarlink.org/nodeinfo.cgi?node=<node>` — what is
    /// linked to when a node number is quoted on the air. It carries the things
    /// a lookup deliberately does not: what the node is currently connected to,
    /// who keyed it last and when, how long it has been up. The lookup answers
    /// "where do I dial", which is a different and smaller question; this is
    /// where an operator goes for the rest.
    ///
    /// Built from the node number rather than returned by the API, because the
    /// stats API has no field for it and the URL is a fixed shape. `nil` unless
    /// the number is digits — everything AllStarLink issues is, and refusing
    /// anything else means free text the operator typed can never be spliced
    /// into a URL.
    var dashboard: URL? {
        let trimmed = node.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber)
        else { return nil }
        return URL(string: "https://stats.allstarlink.org/nodeinfo.cgi?node=\(trimmed)")
    }

    /// "WB6NIL · ASL Public Hub · 18.224.69.177", skipping whatever is missing.
    ///
    /// One line rather than a row of fields: the operator is confirming that
    /// the number they typed is the node they meant, and the callsign and the
    /// description are what tell them.
    var summary: String {
        var parts: [String] = []
        if let callsign, !callsign.isEmpty { parts.append(callsign) }
        if let description, !description.isEmpty { parts.append(description) }
        parts.append(host)
        return parts.joined(separator: " · ")
    }
}

/// Turns an AllStarLink node number into an address.
///
/// **Why this is a lookup and not a browser.** EchoLink and M17 got panes
/// because their directories are lists worth reading: who is on, which
/// reflectors exist. AllStarLink's is neither — an operator already knows the
/// node number they want, because it is what gets quoted on the air, and what
/// they do not know is the address behind it. So this answers one question
/// about one node rather than offering the whole register to scroll.
///
/// A protocol so the button can be tested without the network.
protocol NodeLookup: Sendable {
    func registration(forNode node: String) async throws -> NodeRegistration
}

/// Why a node number did not turn into an address.
enum NodeLookupError: Error, Equatable, CustomStringConvertible {
    /// Nothing was typed.
    case missingNode

    /// The directory has no such node.
    case notListed(node: String)

    /// The node exists but has no address on file — private nodes and nodes
    /// that have never registered both look like this.
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

/// Looks a node up through AllStarLink's public stats API.
///
/// `https://stats.allstarlink.org/api/stats/<node>` — unauthenticated, one node
/// per request, and it answers `404` with an empty array for a number it does
/// not know.
///
/// **Registration data, not a live probe.** `ipaddr` is where the node last
/// registered from, which is what an IAX2 client needs to dial and is not a
/// promise that anybody is home. A stale answer produces a call that times out,
/// which is the same outcome as dialling a stale address by hand — no worse for
/// having been looked up.
struct AllStarLinkNodeLookup: NodeLookup {
    static let endpoint = URL(string: "https://stats.allstarlink.org/api/stats/")!

    /// The registered IAX2 port, if the directory does not say. Duplicated from
    /// `NodeSettings.defaultPort` rather than imported for the same reason that
    /// constant is duplicated from the library: this layer does not import
    /// `IAX2Kit`, and the destination's own default is the authority.
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

        // Percent-encoded rather than interpolated: the field is free text
        // until it is validated, and a stray slash or space would otherwise
        // build a URL pointing somewhere else entirely.
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
            // 404 with `[]` is how the directory says "no such node", which is
            // an ordinary answer rather than a fault.
            if http.statusCode == 404 { throw NodeLookupError.notListed(node: trimmed) }
            guard (200..<300).contains(http.statusCode) else {
                throw NodeLookupError.unreachable(detail: "the server answered \(http.statusCode)")
            }
        }

        return try Self.parse(data, node: trimmed)
    }

    /// Reads the `node` object out of a stats response.
    ///
    /// Separate from the fetch so every rule about the payload is testable
    /// against bytes, with no network in the test.
    static func parse(_ data: Data, node: String) throws -> NodeRegistration {
        // An empty array is the 404 body, and also what a 200 with no node
        // looks like if the API ever changes its mind about the status code.
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
            // Anything other than an explicit "Active" is treated as not
            // active, rather than guessing at a vocabulary we have only seen
            // one value of.
            isActive: entry.Status?.caseInsensitiveCompare("Active") == .orderedSame)
    }

    private struct StatsResponse: Decodable {
        var node: NodeEntry
    }

    /// Named as the API names them, including the capital `S` and the
    /// underscore, so the mapping between this and a response an operator might
    /// paste into a bug report is obvious.
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

/// The state behind the "look it up" button.
///
/// Kept out of the view for the reason ``ProxyPicker`` is: it is a network
/// round trip, it can fail in ways the operator needs told about, and a second
/// press while one is in flight must replace it rather than race it.
@MainActor
final class NodeLocator: ObservableObject {
    @Published private(set) var isSearching = false

    /// The last node found, which the form has already been filled in from.
    @Published private(set) var found: NodeRegistration?

    /// Why the last lookup found nothing, in words the operator can act on.
    @Published private(set) var failure: String?

    private let lookup: NodeLookup
    private var task: Task<Void, Never>?

    /// Bumped by every ``find(node:then:)``, so a superseded lookup can tell
    /// that it is one. Same guard as `ProxyPicker` and the two browsers.
    private var generation = 0

    init(lookup: NodeLookup) {
        self.lookup = lookup
    }

    /// Looks `node` up and hands the answer to `apply`.
    ///
    /// The result is passed out rather than written to settings here: this type
    /// does not own the connect form's fields, and reaching into them would be
    /// writing to a draft it cannot see the rest of.
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

    /// Forgets the last answer. Called when the node number changes, so a
    /// summary describing a node the operator has since typed over does not
    /// sit there looking authoritative.
    func clear() {
        cancel()
        found = nil
        failure = nil
    }
}
