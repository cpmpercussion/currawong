// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// Turning an AllStarLink node number into an address.
///
/// The samples are trimmed from a real response (node 2000, fetched
/// 2026-08-16) rather than invented, including the API's own inconsistent
/// spelling — `Status` capitalised, `node_frequency` underscored — because
/// tidying them in the fixture is how a parser comes to expect a payload
/// nobody sends.
final class NodeLookupTests: XCTestCase {

    // MARK: - Parsing

    func testAnAddressIsReadOutOfARealResponse() throws {
        let registration = try AllStarLinkNodeLookup.parse(Self.node2000, node: "2000")

        XCTAssertEqual(registration.node, "2000")
        XCTAssertEqual(registration.host, "18.224.69.177")
        XCTAssertEqual(registration.port, 4569)
        XCTAssertEqual(registration.callsign, "WB6NIL")
        XCTAssertEqual(registration.description, "ASL Public Hub")
        XCTAssertTrue(registration.isActive)
        XCTAssertEqual(registration.summary, "WB6NIL · ASL Public Hub · 18.224.69.177")
    }

    /// The directory answers `404` with `[]` for a number it does not know,
    /// which is an ordinary answer and not a fault. Handled at the parse layer
    /// too, in case the status code ever changes.
    func testAnEmptyArrayIsNotAFault() {
        XCTAssertThrowsError(
            try AllStarLinkNodeLookup.parse(Data("[]".utf8), node: "999999")
        ) { error in
            XCTAssertEqual(error as? NodeLookupError, .notListed(node: "999999"))
        }
    }

    /// A node can be listed with no address: private ones, and ones that have
    /// never registered. That is a different problem from "no such node" and
    /// gets a different sentence, because the fix is different — ask the owner
    /// rather than check the number.
    func testAListedNodeWithNoAddressIsDistinguished() {
        let json = Data(#"{"node":{"Status":"Active","ipaddr":null,"port":4569}}"#.utf8)

        XCTAssertThrowsError(try AllStarLinkNodeLookup.parse(json, node: "1234")) { error in
            XCTAssertEqual(error as? NodeLookupError, .notRegistered(node: "1234"))
        }
    }

    func testAnEmptyAddressCountsAsNoAddress() {
        let json = Data(#"{"node":{"Status":"Active","ipaddr":"   ","port":4569}}"#.utf8)

        XCTAssertThrowsError(try AllStarLinkNodeLookup.parse(json, node: "1234")) { error in
            XCTAssertEqual(error as? NodeLookupError, .notRegistered(node: "1234"))
        }
    }

    /// Missing port falls back to 4569 rather than to zero, which would be
    /// dialled and fail somewhere much less obvious.
    func testAMissingPortFallsBackToTheRegisteredOne() throws {
        let json = Data(#"{"node":{"Status":"Active","ipaddr":"203.0.113.1"}}"#.utf8)

        let registration = try AllStarLinkNodeLookup.parse(json, node: "1234")
        XCTAssertEqual(registration.port, 4569)
    }

    /// A node on a non-standard port is exactly the case a lookup should catch,
    /// since it is the one an operator would never guess.
    func testANonStandardPortIsCarriedThrough() throws {
        let json = Data(#"{"node":{"Status":"Active","ipaddr":"203.0.113.1","port":4570}}"#.utf8)

        XCTAssertEqual(try AllStarLinkNodeLookup.parse(json, node: "1234").port, 4570)
    }

    /// Anything other than an explicit "Active" is not treated as active. The
    /// vocabulary has only ever been seen with one value in it, and guessing at
    /// the rest would put a green tick on a node that is not there.
    func testOnlyAnExplicitActiveStatusCountsAsActive() throws {
        for status in ["\"Update\"", "\"Inactive\"", "null"] {
            let json = Data(
                #"{"node":{"Status":\#(status),"ipaddr":"203.0.113.1","port":4569}}"#.utf8)
            XCTAssertFalse(
                try AllStarLinkNodeLookup.parse(json, node: "1234").isActive,
                "\(status) is not Active")
        }

        let active = Data(#"{"node":{"Status":"active","ipaddr":"203.0.113.1"}}"#.utf8)
        XCTAssertTrue(
            try AllStarLinkNodeLookup.parse(active, node: "1234").isActive,
            "case is not the distinction being drawn")
    }

    func testBlankMetadataIsAbsentRatherThanEmpty() throws {
        let json = Data(
            #"{"node":{"Status":"Active","ipaddr":"203.0.113.1","callsign":"","node_frequency":"  "}}"#
                .utf8)

        let registration = try AllStarLinkNodeLookup.parse(json, node: "1234")
        XCTAssertNil(registration.callsign)
        XCTAssertNil(registration.description)
        XCTAssertEqual(registration.summary, "203.0.113.1", "no empty separators")
    }

    func testSomethingThatIsNotAStatsResponseIsMalformed() {
        XCTAssertThrowsError(
            try AllStarLinkNodeLookup.parse(Data("<html>nope</html>".utf8), node: "1234")
        ) { error in
            guard case .malformed = error as? NodeLookupError else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: - The fetch around the parse

    private static let endpoint = URL(string: "https://example.org/api/stats/")!

    private static func response(_ status: Int, _ url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testALookupAsksForTheNodeItWasGiven() async throws {
        let asked = Asked()
        let lookup = AllStarLinkNodeLookup(endpoint: Self.endpoint) { url in
            await asked.record(url)
            return (Self.node2000, Self.response(200, url))
        }

        _ = try await lookup.registration(forNode: "2000")

        let url = await asked.url
        XCTAssertEqual(url?.absoluteString, "https://example.org/api/stats/2000")
    }

    /// The node number is free text until it is validated, so it is
    /// percent-encoded rather than interpolated — otherwise a stray slash
    /// builds a URL pointing somewhere else entirely.
    func testAnAwkwardNodeNumberCannotRewriteTheURL() async {
        let asked = Asked()
        let lookup = AllStarLinkNodeLookup(endpoint: Self.endpoint) { url in
            await asked.record(url)
            return (Data("[]".utf8), Self.response(404, url))
        }

        _ = try? await lookup.registration(forNode: "../../evil")

        let url = await asked.url
        XCTAssertNotNil(url)
        XCTAssertTrue(
            url?.absoluteString.hasPrefix("https://example.org/api/stats/") == true,
            "got \(url?.absoluteString ?? "nothing")")
    }

    func testAnEmptyNodeNumberIsRefusedWithoutAskingAnybody() async {
        let asked = Asked()
        let lookup = AllStarLinkNodeLookup(endpoint: Self.endpoint) { url in
            await asked.record(url)
            return (Self.node2000, Self.response(200, url))
        }

        do {
            _ = try await lookup.registration(forNode: "   ")
            XCTFail("expected it to be refused")
        } catch {
            XCTAssertEqual(error as? NodeLookupError, .missingNode)
        }

        let url = await asked.url
        XCTAssertNil(url, "nothing should have been fetched")
    }

    func testA404IsReportedAsNotListed() async {
        let lookup = AllStarLinkNodeLookup(endpoint: Self.endpoint) { url in
            (Data("[]".utf8), Self.response(404, url))
        }

        do {
            _ = try await lookup.registration(forNode: "999999")
            XCTFail("expected the 404 to be reported")
        } catch {
            XCTAssertEqual(error as? NodeLookupError, .notListed(node: "999999"))
        }
    }

    func testAServerErrorIsReportedAsUnreachable() async {
        let lookup = AllStarLinkNodeLookup(endpoint: Self.endpoint) { url in
            (Data(), Self.response(503, url))
        }

        do {
            _ = try await lookup.registration(forNode: "2000")
            XCTFail("expected the 503 to be reported")
        } catch {
            XCTAssertEqual(error as? NodeLookupError, .unreachable(detail: "the server answered 503"))
        }
    }

    func testCancellationIsNotDressedUpAsAFailure() async {
        let lookup = AllStarLinkNodeLookup(endpoint: Self.endpoint) { _ in
            throw CancellationError()
        }

        do {
            _ = try await lookup.registration(forNode: "2000")
            XCTFail("expected the cancellation to propagate")
        } catch is CancellationError {
            // As intended.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    /// The published endpoint, pinned — it is the one thing here no offline
    /// test can check.
    func testThePublishedEndpointIsTheStatsAPI() {
        XCTAssertEqual(
            AllStarLinkNodeLookup.endpoint.absoluteString,
            "https://stats.allstarlink.org/api/stats/")
    }

    // MARK: - The node's own page

    /// The counterpart to an M17 reflector's dashboard link. Pinned for the
    /// same reason the endpoint above is: no offline test can tell that the URL
    /// shape is still the one AllStarLink serves.
    func testANodeLinksToItsPageOnTheStatsSite() throws {
        let registration = NodeRegistration(
            node: "2000", host: "18.224.69.177", port: 4569, callsign: "WB6NIL",
            description: nil, isActive: true)

        XCTAssertEqual(
            registration.dashboard?.absoluteString,
            "https://stats.allstarlink.org/nodeinfo.cgi?node=2000")
    }

    /// The node number is free text the operator typed, and it goes into a URL.
    /// Anything that is not digits gets no link at all rather than a spliced
    /// one — the same refusal ``testAnAwkwardNodeNumberCannotRewriteTheURL``
    /// makes on the way out to the API.
    func testOnlyANumberGetsAPage() {
        for awkward in ["", "  ", "20 00", "2000/../evil", "2000?x=y", "two thousand", "2000#top",
                        "٢٠٠٠"] {
            let registration = NodeRegistration(
                node: awkward, host: "10.0.0.1", port: 4569, callsign: nil,
                description: nil, isActive: true)
            XCTAssertNil(
                registration.dashboard,
                "\(awkward) must not be spliced into a URL the operator can tap")
        }

        // Whitespace either side is the operator's typing, not a different node.
        let padded = NodeRegistration(
            node: " 2000 ", host: "10.0.0.1", port: 4569, callsign: nil,
            description: nil, isActive: true)
        XCTAssertEqual(
            padded.dashboard?.absoluteString,
            "https://stats.allstarlink.org/nodeinfo.cgi?node=2000")
    }

    // MARK: - Helpers

    private actor Asked {
        private(set) var url: URL?
        func record(_ url: URL) { self.url = url }
    }

    /// Trimmed from the real response for node 2000.
    private static let node2000 = Data(
        """
        {
          "stats": { "id": 1, "node": 2000 },
          "node": {
            "Node_ID": 3108,
            "User_ID": "WB6NIL",
            "Status": "Active",
            "name": 2000,
            "ipaddr": "18.224.69.177",
            "ip6address": null,
            "port": 4569,
            "node_frequency": "ASL Public Hub",
            "node_tone": "",
            "callsign": "WB6NIL",
            "access_telephoneportal": "1",
            "access_webtransceiver": "1"
          },
          "keyups": [],
          "time": 1.6
        }
        """.utf8)
}

/// The button's state machine.
@MainActor
final class NodeLocatorTests: XCTestCase {
    private struct StubLookup: NodeLookup {
        var result: Result<NodeRegistration, any Error>
        func registration(forNode node: String) async throws -> NodeRegistration {
            try result.get()
        }
    }

    private static let found = NodeRegistration(
        node: "2000", host: "18.224.69.177", port: 4569, callsign: "WB6NIL",
        description: "ASL Public Hub", isActive: true)

    func testASuccessfulLookupHandsTheAnswerOut() async {
        let locator = NodeLocator(lookup: StubLookup(result: .success(Self.found)))

        var applied: NodeRegistration?
        locator.find(node: "2000") { applied = $0 }
        await waitUntil("the lookup finishes") { !locator.isSearching }

        XCTAssertEqual(applied, Self.found)
        XCTAssertEqual(locator.found, Self.found)
        XCTAssertNil(locator.failure)
    }

    /// The complaint has to reach the operator in the lookup's own words: "no
    /// such node" and "listed but not registered" need different actions.
    func testAFailureIsReportedInItsOwnWords() async {
        let locator = NodeLocator(
            lookup: StubLookup(result: .failure(NodeLookupError.notListed(node: "1"))))

        var applied: NodeRegistration?
        locator.find(node: "1") { applied = $0 }
        await waitUntil("the failure lands") { locator.failure != nil }

        XCTAssertNil(applied, "nothing should have been written to the form")
        XCTAssertEqual(locator.failure, NodeLookupError.notListed(node: "1").description)
        XCTAssertFalse(locator.isSearching)
    }

    /// A stale summary sitting under a node number the operator has typed over
    /// is worse than no summary: it looks like an answer to the new question.
    func testClearForgetsTheLastAnswer() async {
        let locator = NodeLocator(lookup: StubLookup(result: .success(Self.found)))
        locator.find(node: "2000") { _ in }
        await waitUntil("the lookup finishes") { locator.found != nil }

        locator.clear()

        XCTAssertNil(locator.found)
        XCTAssertNil(locator.failure)
        XCTAssertFalse(locator.isSearching)
    }

    func testEveryFailureHasWordsForTheOperator() {
        for error: NodeLookupError in [
            .missingNode, .notListed(node: "1"), .notRegistered(node: "1"),
            .unreachable(detail: "offline"), .malformed(detail: "bad"),
        ] {
            XCTAssertFalse(error.description.isEmpty, "\(error) needs something to display")
        }
    }
}
