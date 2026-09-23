// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One public EchoLink proxy, in the app's own vocabulary; the library's
/// `EchoLinkPublicProxy` stays in `CompositionRoot`.
struct ProxyCandidate: Equatable, Sendable, Identifiable {
    /// The proxy's advertised name. Display only.
    var name: String

    var host: String
    var port: UInt16

    /// How far away the directory said it is, when it said.
    var distanceKilometres: Double?

    /// The measured round trip, which is why it was chosen.
    var latencyMilliseconds: Int?

    var id: String { "\(host):\(port)" }

    /// This candidate as a route, with the public proxy password.
    var route: EchoLinkProxyRoute {
        EchoLinkProxyRoute(
            host: host, port: port, password: EchoLinkProxySettings.publicPassword,
            isPrivate: false)
    }

    /// "Sydney · 465 km · 38 ms", skipping whatever the listing did not give.
    var summary: String {
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        if let distance = distanceKilometres {
            parts.append("\(Int(distance.rounded())) km")
        }
        if let latency = latencyMilliseconds {
            parts.append("\(latency) ms")
        }
        return parts.joined(separator: " · ")
    }
}

/// Picks a public proxy on the operator's behalf. A protocol so tests need not
/// probe real machines; the real one is `EchoLinkPublicProxyFinder`.
protocol ProxyFinder: Sendable {
    /// Fetches the public proxy list, probes the nearest few, and returns the
    /// quickest that answered.
    ///
    /// - Parameter onProgress: the running count of proxies probed. Called
    ///   from an arbitrary task.
    func fastestProxy(onProgress: @escaping @Sendable (Int) -> Void) async throws -> ProxyCandidate
}

/// Why no proxy was found. Usually contention rather than a fault — a public
/// proxy carries one client at a time — so the wording says to try again.
enum ProxyFinderError: Error, Equatable, CustomStringConvertible {
    /// Nothing in the list was public and ready.
    case noneAvailable

    /// Candidates were probed and none answered.
    case noneAnswered(probed: Int)

    /// The list itself could not be fetched or made sense of.
    case listUnavailable(detail: String)

    var description: String {
        switch self {
        case .noneAvailable:
            return """
                No public proxy is listed as free. They carry one user at a time and are \
                heavily contended — try again in a moment.
                """
        case .noneAnswered(let probed):
            return """
                Tried \(probed) \(probed == 1 ? "proxy" : "proxies") and none answered. A proxy \
                is listed as ready until somebody takes it, so this is usually contention \
                rather than a fault — try again.
                """
        case .listUnavailable(let detail):
            return "Could not fetch the public proxy list: \(detail)"
        }
    }
}

/// Which proxy an EchoLink session goes through, and the search that finds one
/// (a list fetch, then TCP probes of several machines: a second or two).
///
/// The only place a proxy comes from (APP-13): connecting and reading the
/// directory both call ``route(privateProxy:privatePassword:)``.
@MainActor
final class ProxyPicker: ObservableObject {
    @Published private(set) var isSearching = false

    /// How many proxies have been probed, shown so a search visibly progresses.
    @Published private(set) var probedCount = 0

    /// The public proxy this sitting is using: a lease, not a setting. Shared
    /// by a directory read and the connect after it, and dropped by
    /// ``releaseLease()`` at teardown.
    @Published private(set) var lease: ProxyCandidate?

    /// Why the last search found nothing, in words the operator can act on.
    @Published private(set) var failure: String?

    private let finder: ProxyFinder
    private var searchTask: Task<ProxyCandidate?, Never>?

    /// Bumped by every search, so a superseded one can tell that it is.
    private var generation = 0

    init(finder: ProxyFinder) {
        self.finder = finder
    }

    /// Drops the ``lease`` and probes for another, fire-and-forget: the
    /// "find another proxy" button.
    func findAnother() {
        lease = nil
        beginSearch()
    }

    /// The same search, awaited. Both paths go through ``beginSearch()``, so
    /// there is only ever one search.
    ///
    /// - Returns: the proxy, or nil if none was found, the search failed, or it
    ///   was superseded. On failure ``failure`` says why; show that.
    @discardableResult
    func findProxy() async -> ProxyCandidate? {
        await beginSearch().value
    }

    /// The search itself, and the one place that touches the picker's state.
    ///
    /// Everything up to `searchTask = task` is synchronous, so a second press
    /// cannot start a second search. The lease is set inside the task, so it
    /// is on screen by the time the spinner comes down.
    @discardableResult
    private func beginSearch() -> Task<ProxyCandidate?, Never> {
        // Cancelled *and* waited for, below: an overlapping probe could make the
        // new search's winner look busy — because of our own app.
        let superseded = searchTask
        superseded?.cancel()

        isSearching = true
        failure = nil
        probedCount = 0
        generation += 1
        let generation = generation

        let task = Task { @MainActor [weak self] in
            guard let self else { return ProxyCandidate?.none }
            defer { if self.generation == generation { self.isSearching = false } }

            // Short: the probe closes its transport even when cancelled.
            _ = await superseded?.value

            do {
                let candidate = try await self.finder.fastestProxy { probed in
                    // Called from an arbitrary task.
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.probedCount = probed
                    }
                }
                guard !Task.isCancelled, self.generation == generation else { return nil }
                self.lease = candidate
                return candidate
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return nil }
                self.failure = "\(error)"
                return nil
            }
        }

        searchTask = task
        return task
    }

    /// The proxy this sitting's EchoLink traffic goes through (FR-3.3), resolved
    /// when needed: the operator's own proxy (never overridden here), else the
    /// ``lease``, else a fresh probe.
    ///
    /// - Returns: the proxy, or `nil` when the probe found nothing; then
    ///   ``failure`` says why and the caller should stop. Callers check
    ///   `RadioMode.usesProxy` first.
    func route(
        privateProxy: EchoLinkProxySettings, privatePassword: String
    ) async -> EchoLinkProxyRoute? {
        if let own = privateProxy.route(password: privatePassword) { return own }
        if let lease { return lease.route }
        return await findProxy()?.route
    }

    /// Gives up the public proxy at teardown: somebody else may take it before
    /// the next session.
    func releaseLease() {
        lease = nil
        failure = nil
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
