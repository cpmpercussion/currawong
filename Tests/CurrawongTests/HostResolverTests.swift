// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// A resolver that asks nothing. AU-5's rule for sockets applies just as well
/// to DNS: a test that depends on a name existing depends on the network.
final class FakeHostResolver: HostResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAnswers: [String: String]
    private var storedError: Error?
    private var storedLookups: [String] = []

    init(answers: [String: String] = [:], error: Error? = nil) {
        self.storedAnswers = answers
        self.storedError = error
    }

    /// Every host this resolver was asked about, in order.
    var lookups: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedLookups
    }

    func ipv4Address(for host: String) async throws -> String {
        lock.lock()
        storedLookups.append(host)
        let error = storedError
        let answer = storedAnswers[host]
        lock.unlock()

        if let error { throw error }
        // Unmapped names pass through as-is, so a test that does not care about
        // resolution does not have to set anything up.
        return answer ?? host
    }
}

final class HostResolverTests: XCTestCase {

    /// A channel saved before any of this existed holds a dotted quad, and must
    /// keep working without a lookup.
    func testAnAddressIsReturnedWithoutResolving() async throws {
        let resolver = SystemHostResolver()

        let resolved = try await resolver.ipv4Address(for: "129.213.119.249")

        XCTAssertEqual(resolved, "129.213.119.249")
    }

    func testSurroundingSpaceIsIgnored() async throws {
        let resolver = SystemHostResolver()

        let resolved = try await resolver.ipv4Address(for: "  129.213.119.249 ")

        XCTAssertEqual(resolved, "129.213.119.249")
    }

    // No test here resolves a real name. AU-5 keeps sockets out of the suite and
    // the same reasoning covers DNS: a test that needs a name to exist needs the
    // network, and one that needs a name *not* to exist needs it just as much —
    // an unresolvable lookup with no DNS to ask is a timeout, not a quick error.
    // The lookup itself is exercised on air; what is testable here is the
    // short-circuit, and the words a failure leaves behind.

    func testEveryFailureHasWordsForTheOperator() {
        let failures: [HostResolverError] = [
            .noIPv4Address(host: "v6only.example.org"),
            .lookupFailed(host: "nope.invalid", detail: "nodename nor servname provided"),
        ]

        for failure in failures {
            XCTAssertFalse(failure.description.isEmpty)
            XCTAssertTrue(
                failure.description.contains("v6only.example.org")
                    || failure.description.contains("nope.invalid"),
                "a resolution failure has to name the host: \(failure.description)")
        }
    }

    // MARK: - The default

    /// `servers` rather than a regional name, and a name rather than an address.
    /// The addresses behind it are cloud-hosted and change; that is the whole
    /// reason this resolves rather than shipping a number.
    func testTheDefaultDirectoryServerIsThePoolName() {
        XCTAssertEqual(NodeSettings.defaultDirectoryServer, "servers.echolink.org")
        XCTAssertFalse(
            NodeSettings.isDottedQuad(NodeSettings.defaultDirectoryServer),
            "the default must be a name — an address baked in here is a defect with a delay on it")
        XCTAssertTrue(NodeSettings.isPlausibleHostName(NodeSettings.defaultDirectoryServer))
    }

    /// The rule that keeps a dropped octet from being mistaken for a host name
    /// and posted off to a resolver.
    func testAnAllNumericNameIsNotAHostName() {
        XCTAssertFalse(NodeSettings.isPlausibleHostName("192.0.2"))
        XCTAssertFalse(NodeSettings.isPlausibleHostName("129.213.119.249"))
        XCTAssertTrue(NodeSettings.isPlausibleHostName("naeast.echolink.org"))
    }
}

// MARK: - The connect path

@MainActor
final class RadioSessionResolutionTests: XCTestCase {

    private func echoLinkChannel(directoryServer: String) -> NodeSettings {
        var settings = SessionHarness.echoLinkSettings
        settings.directoryServer = directoryServer
        return settings
    }

    /// The point of the whole exercise: the operator types a name, and the
    /// library — which resolves nothing — is handed four octets.
    func testTheDirectoryServerIsResolvedBeforeTheLinkIsBuilt() async {
        let resolver = FakeHostResolver(answers: ["servers.echolink.org": "129.213.119.249"])
        let harness = SessionHarness(resolver: resolver)

        harness.session.settings = echoLinkChannel(directoryServer: "servers.echolink.org")
        harness.session.secret = "hunter2"
        await harness.session.connect()

        XCTAssertEqual(resolver.lookups, ["servers.echolink.org"])
        XCTAssertEqual(harness.settingsSeen.last?.directoryServer, "129.213.119.249")
    }

    /// The channel keeps the *name*. An address cached in a saved channel goes
    /// stale silently — these are cloud-hosted and do move — so what is
    /// persisted has to be the thing that stays true.
    func testTheSavedChannelKeepsTheNameRatherThanTheAddress() async {
        let resolver = FakeHostResolver(answers: ["servers.echolink.org": "129.213.119.249"])
        let harness = SessionHarness(resolver: resolver)

        harness.session.settings = echoLinkChannel(directoryServer: "servers.echolink.org")
        harness.session.secret = "hunter2"
        await harness.session.connect()

        XCTAssertEqual(harness.session.settings.directoryServer, "servers.echolink.org")
        XCTAssertEqual(
            harness.session.channels.selected?.directoryServer, "servers.echolink.org")
    }

    /// An empty directory server means "do not log in to the directory", which
    /// is a supported way to run. Nothing should be looked up for it.
    func testAnEmptyDirectoryServerResolvesNothing() async {
        let resolver = FakeHostResolver()
        let harness = SessionHarness(resolver: resolver)

        harness.session.settings = echoLinkChannel(directoryServer: "")
        harness.session.secret = "hunter2"
        await harness.session.connect()

        XCTAssertEqual(resolver.lookups, [])
        XCTAssertEqual(harness.linksMade, 1, "it should still connect")
    }

    /// Only EchoLink has a directory server. An AllStar connection must not pay
    /// for a lookup it has no use for.
    func testAnAllStarConnectionResolvesNothing() async {
        let resolver = FakeHostResolver()
        let harness = SessionHarness(resolver: resolver)

        await harness.connect()

        XCTAssertEqual(resolver.lookups, [])
    }

    /// A name that does not resolve stops the connection, with the failure
    /// named — rather than proceeding to a proxy `OPEN` built from nothing.
    func testAFailedLookupStopsTheConnectionAndSaysSo() async {
        let resolver = FakeHostResolver(
            error: HostResolverError.lookupFailed(host: "typo.echolink.org", detail: "no such host"))
        let harness = SessionHarness(resolver: resolver)

        harness.session.settings = echoLinkChannel(directoryServer: "typo.echolink.org")
        harness.session.secret = "hunter2"
        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.linksMade, 0, "no link should be built from an unresolved server")
        XCTAssertNotNil(harness.session.alert)
        XCTAssertTrue(
            harness.session.alert?.message.contains("typo.echolink.org") == true,
            "the operator has to be told which name failed")
    }
}
