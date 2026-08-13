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

    /// Makes the next search park until ``release()``, for the states that only
    /// exist *during* one.
    func holdUntilReleased() {
        lock.lock()
        storedHoldUntilReleased = true
        storedReleased = false
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
        let error = storedError
        let candidate = storedCandidate
        let holds = storedHoldUntilReleased
        let steps = storedProgressSteps
        lock.unlock()

        var probed = 0
        for step in steps {
            probed += step
            onProgress(probed)
        }

        if holds {
            while !isReleased, !Task.isCancelled {
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
