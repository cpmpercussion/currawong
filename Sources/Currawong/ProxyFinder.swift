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
    private var searchTask: Task<ProxyCandidate?, Never>?

    /// Bumped by every search, however it was started, so a superseded one can
    /// tell that it is — the same hazard, and the same guard, as
    /// `StationBrowser`.
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
        beginSearch(apply: apply)
    }

    /// The same search, awaited.
    ///
    /// The button path above fires and forgets; ``sourceProxyIfNeeded`` has to
    /// *wait*, because the thing it is finding a proxy for cannot start until
    /// there is one. Both go through ``beginSearch(apply:)``, so a search
    /// started either way is the same single search — same spinner, same probe
    /// count, same cancellation — rather than a second one racing the first for
    /// the same strangers' machines.
    ///
    /// - Returns: the proxy, or nil if none was found, the search failed, or it
    ///   was superseded. In the failure case ``failure`` says why, which is
    ///   what the caller should be showing rather than a message of its own.
    @discardableResult
    func findProxy() async -> ProxyCandidate? {
        await beginSearch(apply: nil).value
    }

    /// The search itself, and the one place that touches the picker's state.
    ///
    /// **Everything up to `searchTask = task` happens synchronously**, before
    /// this returns: the spinner going up is the caller's own effect, not
    /// something that lands a hop later. ``find(then:)`` is called straight
    /// from a button, and a picker that had not yet started when the press
    /// returned would let a second press start a second search.
    ///
    /// `apply` runs *inside* the task, next to `chosen`, rather than being left
    /// to the awaiting caller — so by the time the spinner comes down, the
    /// proxy is already in the form.
    @discardableResult
    private func beginSearch(
        apply: (@MainActor (ProxyCandidate) -> Void)?
    ) -> Task<ProxyCandidate?, Never> {
        // Cancelled *and* waited for, below, before the new search opens
        // anything. Cancelling alone would leave the two overlapping for a
        // round trip, and a superseded search can be probing the very proxy the
        // new one is about to pick — which would present as the winner being
        // busy, from our own app rather than from a stranger. Probing is
        // touching other operators' equipment, so the overlap is worth removing
        // even though it is brief.
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

            // The cancelled search drops its sockets within a round trip — the
            // probe closes its transport even on the cancelled path — so this
            // is a short wait, and it is what keeps the two from probing at
            // once. `Never` as the failure type, so awaiting it cannot throw.
            _ = await superseded?.value

            do {
                let candidate = try await self.finder.fastestProxy { probed in
                    // Hops back to the main actor: the library calls this from
                    // whichever task ran the batch.
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.probedCount = probed
                    }
                }
                guard !Task.isCancelled, self.generation == generation else { return nil }
                self.chosen = candidate
                apply?(candidate)
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

    /// Makes sure `settings` names a proxy before an operation that needs one,
    /// finding a public one if it does not.
    ///
    /// A proxy is not a preference, it is plumbing: EchoLink cannot be reached
    /// from a phone without one, and there is nothing an operator knows that
    /// would let them fill the field in better than a probe can. So the two
    /// places that need a proxy — reading the directory, and placing a call —
    /// source one at the moment they need it rather than refusing and naming a
    /// field. That is only true of an *empty* field: a proxy the operator typed
    /// or the app already found is theirs, and repointing it silently under a
    /// channel they had set up would be the worse surprise. Use "Find a public
    /// proxy" in the connect form to replace one deliberately.
    ///
    /// - Parameter apply: writes the proxy into whatever holds the draft. As in
    ///   ``find(then:)``, this type does not reach into the form itself.
    /// - Returns: whether the caller may proceed — true when a proxy was
    ///   already there or one was found, false when one was needed and the
    ///   search came back empty. On false, ``failure`` says why.
    func sourceProxyIfNeeded(
        for settings: NodeSettings,
        apply: @MainActor (ProxyCandidate) -> Void
    ) async -> Bool {
        guard settings.mode.usesProxy,
            settings.host.trimmingCharacters(in: .whitespaces).isEmpty
        else { return true }

        guard let candidate = await findProxy() else { return false }
        apply(candidate)
        return true
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
