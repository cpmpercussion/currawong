// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import Currawong

/// A ``ProxyFinder`` that probes nothing.
///
/// The real one fetches echolink.org's list and opens TCP connections to
/// several strangers' machines. This one answers from a stored value, which is
/// what lets the picker's states — searching, progress, failing, superseded —
/// be tested without touching anybody else's proxy.
///
/// Modelled on ``FakeStationDirectory``, including the polling hold: a finder
/// that parks on a continuation would hang the suite the moment a test
/// cancelled it.
final class FakeProxyFinder: ProxyFinder, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCandidate: ProxyCandidate
    private var storedError: Error?
    private var storedCallCount = 0
    private var storedHoldUntilReleased = false
    private var storedReleased = false
    private var storedIgnoresCancellation = false
    private var storedInFlight = 0
    private var storedMaxInFlight = 0

    /// Batch sizes to report through `onProgress` before returning, so a test
    /// can drive the progress count without a network.
    private var storedProgressSteps: [Int] = []

    init(candidate: ProxyCandidate = .fake(), error: Error? = nil) {
        self.storedCandidate = candidate
        self.storedError = error
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedReleased
    }

    func setError(_ error: Error?) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func setProgressSteps(_ steps: [Int]) {
        lock.lock()
        storedProgressSteps = steps
        lock.unlock()
    }

    /// The most searches that were ever inside this finder at once.
    ///
    /// The measurement that matters for proxy etiquette: probing touches other
    /// operators' single-user machines, so two searches overlapping is a real
    /// cost even when it is brief and even when both eventually succeed.
    var maxInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedMaxInFlight
    }

    /// Makes the next search park until ``release()``, for the states that only
    /// exist *during* one.
    ///
    /// - Parameter ignoringCancellation: keep parking even once cancelled, which
    ///   is how a real probe behaves — it holds its socket until the round trip
    ///   winds down rather than vanishing the instant `cancel()` is called. A
    ///   fake that exits immediately on cancellation cannot show an overlap,
    ///   because there is nothing left to overlap *with*.
    func holdUntilReleased(ignoringCancellation: Bool = false) {
        lock.lock()
        storedHoldUntilReleased = true
        storedReleased = false
        storedIgnoresCancellation = ignoringCancellation
        lock.unlock()
    }

    func release() {
        lock.lock()
        storedReleased = true
        lock.unlock()
    }

    func fastestProxy(onProgress: @escaping @Sendable (Int) -> Void) async throws -> ProxyCandidate
    {
        lock.lock()
        storedCallCount += 1
        storedInFlight += 1
        storedMaxInFlight = max(storedMaxInFlight, storedInFlight)
        let error = storedError
        let candidate = storedCandidate
        let holds = storedHoldUntilReleased
        let ignoresCancellation = storedIgnoresCancellation
        let steps = storedProgressSteps
        lock.unlock()

        defer {
            lock.lock()
            storedInFlight -= 1
            lock.unlock()
        }

        var probed = 0
        for step in steps {
            probed += step
            onProgress(probed)
        }

        if holds {
            while !isReleased, ignoresCancellation || !Task.isCancelled {
                await Task.yield()
            }
            try Task.checkCancellation()
        }

        if let error { throw error }
        return candidate
    }
}

extension ProxyCandidate {
    static func fake(
        name: String = "Test Proxy",
        host: String = "192.0.2.50",
        port: UInt16 = 8100,
        distanceKilometres: Double? = 12,
        latencyMilliseconds: Int? = 34
    ) -> ProxyCandidate {
        ProxyCandidate(
            name: name,
            host: host,
            port: port,
            distanceKilometres: distanceKilometres,
            latencyMilliseconds: latencyMilliseconds)
    }
}
