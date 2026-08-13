// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One public EchoLink proxy, in the app's own vocabulary.
///
/// `EchoLinkPublicProxy` is a library type and only `CompositionRoot` may see
/// it — the same rule that keeps `EchoLinkStation` out of the browser. What a
/// view needs from a proxy is a host, a port, and enough to say why *this* one
/// was picked; the library's version also carries a version string, an operator
/// comment and a status word that the app has no use for.
struct ProxyCandidate: Equatable, Sendable, Identifiable {
    /// The proxy's advertised name. Display only — the connection uses
    /// ``host``.
    var name: String

    var host: String
    var port: UInt16

    /// How far away the directory said it is, when it said.
    var distanceKilometres: Double?

    /// The measured round trip to it. This is the reason it was chosen over the
    /// others, so it is worth showing.
    var latencyMilliseconds: Int?

    var id: String { "\(host):\(port)" }

    /// "Sydney · 465 km · 38 ms", skipping whatever the listing did not give.
    ///
    /// A single line rather than a row of labelled fields: the operator is
    /// deciding whether to accept a machine the app picked for them, and the
    /// three facts that bear on that are who it is, how far, and how quick.
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

/// Picks a public proxy on the operator's behalf.
///
/// A protocol so the picker can be tested without touching echolink.org or
/// probing strangers' machines. The real one is
/// `CompositionRoot.EchoLinkPublicProxyFinder`.
protocol ProxyFinder: Sendable {
    /// Fetches the public proxy list, probes the nearest few, and returns the
    /// quickest that answered.
    ///
    /// - Parameter onProgress: the running count of proxies probed, so the UI
    ///   can say what it is doing during the second or two this takes. Called
    ///   from an arbitrary task.
    func fastestProxy(onProgress: @escaping @Sendable (Int) -> Void) async throws -> ProxyCandidate
}

/// Why no proxy was found.
///
/// Both cases are ordinary outcomes rather than faults — public proxies carry
/// one client at a time and are heavily contended, so "they were all busy" is
/// a normal Tuesday and the right response is to try again, not to report a
/// defect. The wording says so, and ``ProxyPicker`` offers a retry for both.
enum ProxyFinderError: Error, Equatable, CustomStringConvertible {
    /// Nothing in the list was public and ready.
    case noneAvailable

    /// Candidates were probed and none answered — listed as ready, but already
    /// taken by the time we knocked.
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

/// The state behind the "find me a proxy" button.
///
/// Kept out of the view because finding a proxy is not instant: it fetches a
/// list over HTTPS and then opens real TCP connections to several strangers'
/// machines, which takes a second or two. That is long enough that the operator
/// needs to see it happening, and long enough that they may want to stop.
@MainActor
final class ProxyPicker: ObservableObject {
    @Published private(set) var isSearching = false

    /// How many proxies have been probed so far. Shown rather than a bare
    /// spinner: the count moving is the difference between "working" and
    /// "hung", and this is the part that takes the time.
    @Published private(set) var probedCount = 0

    /// The last proxy found, which the form has already been filled in from.
    @Published private(set) var chosen: ProxyCandidate?

    /// Why the last search found nothing, in words the operator can act on.
    @Published private(set) var failure: String?

    private let finder: ProxyFinder
    private var searchTask: Task<Void, Never>?

    /// Bumped by every ``find(then:)`` so a superseded search can tell that it
    /// is one — the same hazard, and the same guard, as `StationBrowser`.
    private var generation = 0

    init(finder: ProxyFinder) {
        self.finder = finder
    }

    /// Finds the quickest free proxy and hands it to `apply`.
    ///
    /// The result is passed out rather than written to settings here: this type
    /// does not own the connect form's fields, and a picker that reached into
    /// them would be writing to a draft it cannot see the rest of.
    func find(then apply: @escaping @MainActor (ProxyCandidate) -> Void) {
        searchTask?.cancel()

        isSearching = true
        failure = nil
        probedCount = 0
        generation += 1
        let generation = generation

        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.isSearching = false } }

            do {
                let candidate = try await self.finder.fastestProxy { probed in
                    // Hops back to the main actor: the library calls this from
                    // whichever task ran the batch.
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.probedCount = probed
                    }
                }
                guard !Task.isCancelled, self.generation == generation else { return }
                self.chosen = candidate
                apply(candidate)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.failure = "\(error)"
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
