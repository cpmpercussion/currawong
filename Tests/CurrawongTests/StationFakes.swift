// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import Currawong

// MARK: - Directory

/// A ``StationDirectory`` that fetches nothing.
///
/// The real one opens a proxy session, logs in to a directory server and reads
/// six thousand entries. This one answers from an array, which is what lets the
/// browser's state machine — loading, failing, filtering, ordering — be tested
/// on a machine with no proxy, no account and no radio licence.
///
/// Records the arguments it was called with, because "the browser passed the
/// operator's own settings through rather than something it invented" is a
/// thing worth asserting.
final class FakeStationDirectory: StationDirectory, @unchecked Sendable {
    struct Fetch: Equatable {
        var settings: NodeSettings
        var identity: OperatorIdentity
        var accountPassword: String
    }

    private let lock = NSLock()
    private var storedStations: [DirectoryStation]
    private var storedError: Error?
    private var storedFetches: [Fetch] = []
    private var storedHoldUntilReleased = false
    private var storedReleased = false

    init(stations: [DirectoryStation] = [], error: Error? = nil) {
        self.storedStations = stations
        self.storedError = error
    }

    func stations(
        for settings: NodeSettings, identity: OperatorIdentity, accountPassword: String
    ) async throws -> [DirectoryStation] {
        lock.lock()
        storedFetches.append(
            Fetch(settings: settings, identity: identity, accountPassword: accountPassword))
        let error = storedError
        let stations = storedStations
        let holds = storedHoldUntilReleased
        lock.unlock()

        // A fetch that does not return until a test says so, for the states that
        // only exist *during* one. Polling rather than a continuation on
        // purpose: this has to survive being cancelled, and a continuation that
        // is never resumed because the awaiting task was cancelled is a hang.
        if holds {
            while !isReleased, !Task.isCancelled {
                await Task.yield()
            }
            try Task.checkCancellation()
        }

        if let error { throw error }
        return stations
    }

    // MARK: Test surface

    /// What the next fetch will throw, if anything.
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

    var fetches: [Fetch] {
        lock.lock()
        defer { lock.unlock() }
        return storedFetches
    }

    /// Whether a fetch parks until ``release()`` instead of answering at once.
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

    /// Lets every parked fetch finish.
    func release() {
        lock.lock()
        storedReleased = true
        lock.unlock()
    }

    /// An error whose `description` is distinctive, so a test can prove the
    /// underlying words reached the operator rather than being replaced by a
    /// generic apology.
    struct DirectoryUnreachable: Error, Equatable, CustomStringConvertible {
        var description: String { "the directory server did not answer" }
    }
}

// MARK: - Stations

extension DirectoryStation {
    /// A listing entry with everything filled in, so a test can vary the one
    /// field it cares about.
    static func fake(
        callsign: String,
        location: String = "",
        nodeNumber: Int? = nil,
        address: String = "192.0.2.1",
        isConnectable: Bool = true,
        status: String? = "ON"
    ) -> DirectoryStation {
        DirectoryStation(
            callsign: callsign,
            location: location,
            nodeNumber: nodeNumber,
            address: address,
            isConnectable: isConnectable,
            status: status)
    }
}
