// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import Currawong

// MARK: - Directory

/// A ``ReflectorDirectory`` that downloads nothing.
///
/// Same shape and same reasons as ``FakeStationDirectory``: the browser's state
/// machine — loading, failing, filtering, superseding — is worth testing, and
/// none of it should need the internet.
final class FakeReflectorDirectory: ReflectorDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReflectors: [M17Reflector]
    private var storedError: Error?
    private var storedFetchCount = 0
    private var storedHoldUntilReleased = false
    private var storedReleased = false

    init(reflectors: [M17Reflector] = [], error: Error? = nil) {
        self.storedReflectors = reflectors
        self.storedError = error
    }

    func reflectors() async throws -> [M17Reflector] {
        lock.lock()
        storedFetchCount += 1
        let error = storedError
        let reflectors = storedReflectors
        let holds = storedHoldUntilReleased
        lock.unlock()

        // Polling rather than a continuation, for the reason `FakeStationDirectory`
        // gives: this has to survive cancellation, and an unresumed continuation
        // is a hang rather than a failure.
        if holds {
            while !isReleased, !Task.isCancelled {
                await Task.yield()
            }
            try Task.checkCancellation()
        }

        if let error { throw error }
        return reflectors
    }

    // MARK: Test surface

    var fetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFetchCount
    }

    var error: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }
        set {
            lock.lock()
            storedError = newValue
            lock.unlock()
        }
    }

    var reflectorsToReturn: [M17Reflector] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedReflectors
        }
        set {
            lock.lock()
            storedReflectors = newValue
            lock.unlock()
        }
    }

    var holdUntilReleased: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHoldUntilReleased
        }
        set {
            lock.lock()
            storedHoldUntilReleased = newValue
            lock.unlock()
        }
    }

    private var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedReleased
    }

    func release() {
        lock.lock()
        storedReleased = true
        lock.unlock()
    }

    /// Distinctive wording, so a test can prove the operator sees the real
    /// reason rather than a generic apology.
    struct ListUnreachable: Error, Equatable, CustomStringConvertible {
        var description: String { "the reflector list could not be downloaded" }
    }
}

// MARK: - Reflectors

extension M17Reflector {
    /// A reflector with everything filled in, so a test can vary the one field
    /// it cares about.
    static func fake(
        designator: String,
        name: String? = nil,
        host: String = "reflector.example.org",
        port: UInt16 = 17000,
        sponsor: String? = "VK1XYZ",
        country: String? = "AU",
        modules: [ReflectorModule] = [ReflectorModule(letter: "A", note: nil)],
        isMultiprotocol: Bool = false
    ) -> M17Reflector {
        M17Reflector(
            designator: designator,
            name: name,
            host: host,
            port: port,
            sponsor: sponsor,
            country: country,
            modules: modules,
            isMultiprotocol: isMultiprotocol)
    }
}
