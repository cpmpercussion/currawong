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

    /// This candidate as something a session can tunnel through.
    ///
    /// Every public proxy takes the same password, which is a protocol literal
    /// rather than a secret, so nothing is asked of the operator here.
    var route: EchoLinkProxyRoute {
        EchoLinkProxyRoute(
            host: host, port: port, password: EchoLinkProxySettings.publicPassword,
            isPrivate: false)
    }

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

/// Which proxy an EchoLink session goes through, and the search that finds one.
///
/// Kept out of the view because finding a proxy is not instant: it fetches a
/// list over HTTPS and then opens real TCP connections to several strangers'
/// machines, which takes a second or two. That is long enough that the operator
/// needs to see it happening, and long enough that they may want to stop.
///
/// **This is where a proxy comes from, and the only place** (APP-13). Nothing
/// stores one in a channel; ``route(privateProxy:privatePassword:)`` is what
/// connecting and reading the directory both call.
@MainActor
final class ProxyPicker: ObservableObject {
    @Published private(set) var isSearching = false

    /// How many proxies have been probed so far. Shown rather than a bare
    /// spinner: the count moving is the difference between "working" and
    /// "hung", and this is the part that takes the time.
    @Published private(set) var probedCount = 0

    /// The public proxy this sitting is using, if one has been found.
    ///
    /// **A lease, not a setting** (APP-13). It is held here, in memory, for as
    /// long as the operator is doing one thing — a directory refresh and the
    /// connect that follows it are one sitting and should go through one proxy,
    /// because probing again would take a second stranger's machine to do one
    /// operator's work — and it is dropped by ``releaseLease()`` when the link is
    /// torn down, so the next session probes afresh.
    ///
    /// It used to be written into the channel's `host` instead, and that was the
    /// fault APP-13 exists to fix: the first EchoLink connect burned whichever
    /// machine answered quickest into the channel permanently, and no later
    /// connect ever probed again.
    @Published private(set) var lease: ProxyCandidate?

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

    /// Probes for a public proxy and takes it as the sitting's ``lease``.
    ///
    /// Fire-and-forget, for the "find another proxy" button: the operator has
    /// looked at the proxy the app picked and wants a different one — usually
    /// because it has gone away mid-sitting. The result lands in ``lease``, which
    /// is what the next connect or directory read will use; nothing is written
    /// into a form, because there is no longer a form field to write into.
    func findAnother() {
        lease = nil
        beginSearch()
    }

    /// The same search, awaited.
    ///
    /// The button path above fires and forgets; ``route(privateProxy:privatePassword:)``
    /// has to *wait*, because the thing it is finding a proxy for cannot start
    /// until there is one. Both go through ``beginSearch()``, so a search started
    /// either way is the same single search — same spinner, same probe count,
    /// same cancellation — rather than a second one racing the first for the same
    /// strangers' machines.
    ///
    /// - Returns: the proxy, or nil if none was found, the search failed, or it
    ///   was superseded. In the failure case ``failure`` says why, which is
    ///   what the caller should be showing rather than a message of its own.
    @discardableResult
    func findProxy() async -> ProxyCandidate? {
        await beginSearch().value
    }

    /// The search itself, and the one place that touches the picker's state.
    ///
    /// **Everything up to `searchTask = task` happens synchronously**, before
    /// this returns: the spinner going up is the caller's own effect, not
    /// something that lands a hop later. ``findAnother()`` is called straight
    /// from a button, and a picker that had not yet started when the press
    /// returned would let a second press start a second search.
    ///
    /// The lease is set *inside* the task, so by the time the spinner comes down
    /// the proxy the next operation will use is already the one on screen.
    @discardableResult
    private func beginSearch() -> Task<ProxyCandidate?, Never> {
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

    /// The proxy this sitting's EchoLink traffic goes through, finding a public
    /// one if there is nothing else to use.
    ///
    /// **A proxy is not a preference, it is plumbing** (FR-3.3): EchoLink cannot
    /// be reached from a phone without one, and there is nothing an operator
    /// knows that would let them fill a field in better than a probe can. So the
    /// two places that need a proxy — reading the directory, and placing a call —
    /// resolve one at the moment they need it, and "connect to a proxy" is not a
    /// step anybody performs.
    ///
    /// The order is the whole of the policy:
    ///
    /// 1. **The operator's own proxy**, if they have configured one. Theirs beats
    ///    a stranger's every time, and nothing here ever overrides or re-points
    ///    it — that setting is changed in Settings and nowhere else.
    /// 2. **The ``lease``**, if this sitting already holds one. Same proxy for
    ///    the directory read and the call that follows it.
    /// 3. **A fresh probe**, and that is where the second or two goes.
    ///
    /// - Returns: the proxy, or `nil` when a public one was needed and the probe
    ///   found nothing — in which case ``failure`` says why, and the caller
    ///   should stop rather than substitute a message of its own. Callers check
    ///   `RadioMode.usesProxy` before asking; this does not, because a proxy for
    ///   a mode that does not use one is not a question with an answer.
    func route(
        privateProxy: EchoLinkProxySettings, privatePassword: String
    ) async -> EchoLinkProxyRoute? {
        if let own = privateProxy.route(password: privatePassword) { return own }
        if let lease { return lease.route }
        return await findProxy()?.route
    }

    /// Gives up the public proxy this sitting was using.
    ///
    /// Called when the link is torn down. A public proxy carries one client at a
    /// time, so holding the name of one past the session that used it is how an
    /// operator ends up reconnecting to a machine that somebody else has since
    /// taken — the fault this replaced, in miniature. The private proxy is
    /// untouched: it is a setting, not a lease.
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
