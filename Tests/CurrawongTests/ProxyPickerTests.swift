// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

@MainActor
final class ProxyPickerTests: XCTestCase {

    // MARK: - Finding one

    /// The whole point: what the finder returns becomes the sitting's lease, so
    /// the next connect or directory read goes through it.
    func testASuccessfulSearchBecomesTheLease() async {
        let finder = FakeProxyFinder(
            candidate: .fake(name: "Sydney", host: "203.0.113.7", port: 8100))
        let picker = ProxyPicker(finder: finder)

        picker.findAnother()

        await waitUntil("the search finishes") { !picker.isSearching }

        XCTAssertEqual(picker.lease?.host, "203.0.113.7")
        XCTAssertEqual(picker.lease?.port, 8100)
        XCTAssertNil(picker.failure)
    }

    /// A public proxy's route carries the protocol literal, which is not
    /// something the operator is ever asked for.
    func testAPublicProxyRouteCarriesThePublicPassword() {
        let route = ProxyCandidate.fake(host: "203.0.113.7", port: 8100).route

        XCTAssertEqual(route.host, "203.0.113.7")
        XCTAssertEqual(route.port, 8100)
        XCTAssertEqual(route.password, "PUBLIC")
        XCTAssertFalse(route.isPrivate)
    }

    func testProgressIsReportedWhileProbing() async {
        let finder = FakeProxyFinder()
        finder.setProgressSteps([5, 5])
        let picker = ProxyPicker(finder: finder)

        picker.findAnother()
        await waitUntil("the search finishes") { !picker.isSearching }

        // Ten across two batches — the running total, not the batch size.
        await waitUntil("the probed count catches up") { picker.probedCount == 10 }
    }

    func testTheSpinnerIsUpWhileTheSearchRuns() async {
        let finder = FakeProxyFinder()
        finder.holdUntilReleased()
        let picker = ProxyPicker(finder: finder)

        picker.findAnother()
        await waitUntil("the search starts") { picker.isSearching }

        finder.release()
        await waitUntil("the search finishes") { !picker.isSearching }
    }

    // MARK: - Finding nothing

    /// Every public proxy being busy is an ordinary outcome. It has to leave
    /// words behind and stop the spinner, and it must not look like a crash.
    func testNoProxyAvailableBecomesWordsRatherThanSilence() async {
        let finder = FakeProxyFinder(error: ProxyFinderError.noneAvailable)
        let picker = ProxyPicker(finder: finder)

        picker.findAnother()
        await waitUntil("the search finishes") { !picker.isSearching }

        XCTAssertNotNil(picker.failure)
        XCTAssertTrue(
            picker.failure?.contains("contended") == true,
            "the operator should be told this is contention, not a fault")
        XCTAssertNil(picker.lease)
    }

    func testAFailedSearchLeavesNoLease() async {
        let finder = FakeProxyFinder(error: ProxyFinderError.noneAnswered(probed: 15))
        let picker = ProxyPicker(finder: finder)

        picker.findAnother()
        await waitUntil("the search finishes") { !picker.isSearching }

        XCTAssertNil(picker.lease, "nothing answered, so there is nothing to go through")
    }

    /// A retry after a failure clears the old complaint — otherwise the second
    /// search runs under the first one's error text.
    func testRetryingClearsThePreviousFailure() async {
        let finder = FakeProxyFinder(error: ProxyFinderError.noneAvailable)
        let picker = ProxyPicker(finder: finder)

        picker.findAnother()
        await waitUntil("the first search fails") { picker.failure != nil }

        finder.setError(nil)
        picker.findAnother()
        await waitUntil("the second search finishes") { !picker.isSearching }

        XCTAssertNil(picker.failure)
        XCTAssertNotNil(picker.lease)
        XCTAssertEqual(finder.callCount, 2)
    }

    // MARK: - Cancelling and superseding

    func testCancellingStopsTheSpinner() async {
        let finder = FakeProxyFinder()
        finder.holdUntilReleased()
        let picker = ProxyPicker(finder: finder)

        picker.findAnother()
        await waitUntil("the search starts") { picker.isSearching }

        picker.cancel()
        XCTAssertFalse(picker.isSearching)
    }

    /// The same hazard `StationBrowser` has a guard for: a cancelled search
    /// observes its cancellation *after* the search that replaced it has
    /// already put the spinner back up, so an unguarded `defer` would clear the
    /// new search's spinner.
    func testASupersededSearchDoesNotStopTheNewSearchesSpinner() async {
        let finder = FakeProxyFinder()
        finder.holdUntilReleased()
        let picker = ProxyPicker(finder: finder)

        picker.findAnother()
        await waitUntil("the first search starts") { picker.isSearching }

        // Replaces the first, which is still parked.
        picker.findAnother()
        XCTAssertTrue(picker.isSearching)

        // Let both run out. The spinner must still belong to the second.
        finder.release()
        await waitUntil("the second search finishes") { !picker.isSearching }
        XCTAssertNotNil(picker.lease)
    }

    /// Probing touches other operators' single-user machines, so a superseded
    /// search must be *finished*, not merely cancelled, before the next one
    /// opens anything. Otherwise the two overlap for a round trip and the old
    /// search can be probing the proxy the new one is about to pick — the
    /// winner presenting as busy, from our own app.
    func testTheSupersededSearchIsFinishedBeforeTheNextOneStarts() async {
        let finder = FakeProxyFinder()
        // Ignores cancellation, as a real probe does — it holds its socket
        // until the round trip winds down. That is the window an overlap would
        // happen in, so it is the window the test has to reproduce.
        finder.holdUntilReleased(ignoringCancellation: true)
        let picker = ProxyPicker(finder: finder)

        picker.findAnother()
        await waitUntil("the first search is in flight") { finder.callCount == 1 }

        picker.findAnother()

        // Long enough that the second search's task has certainly been
        // scheduled. Without this the assertion would hold whether or not the
        // picker waits, because `find` returns before its task starts.
        try? await Task.sleep(nanoseconds: 50_000_000)

        finder.release()
        await waitUntil("the second search finishes") { !picker.isSearching }

        XCTAssertEqual(finder.callCount, 2, "both searches should have run")
        XCTAssertEqual(
            finder.maxInFlight, 1,
            "two searches probed at once — a superseded search can be probing the proxy the "
                + "new one is about to pick")
    }

    // MARK: - Resolving one at the moment it is needed

    /// The point of `route`: an operator who has just made an EchoLink channel
    /// and pressed Refresh or Connect gets a proxy, rather than a message naming
    /// a field they have no way to fill in well.
    func testAPublicProxyIsFoundWhenThereIsNothingElseToUse() async {
        let finder = FakeProxyFinder(
            candidate: .fake(name: "Sydney", host: "203.0.113.7", port: 8100))
        let picker = ProxyPicker(finder: finder)

        let route = await picker.route(privateProxy: .none, privatePassword: "")

        XCTAssertEqual(route?.host, "203.0.113.7")
        XCTAssertEqual(route?.port, 8100)
        XCTAssertEqual(route?.password, "PUBLIC")
        XCTAssertEqual(route?.isPrivate, false)
    }

    /// The operator's own proxy beats a stranger's, and nothing is probed at all
    /// — probing when there is already an answer is touching somebody else's
    /// single-user machine for nothing.
    func testAPrivateProxyWinsAndNothingIsProbed() async {
        let finder = FakeProxyFinder()
        let picker = ProxyPicker(finder: finder)
        let own = EchoLinkProxySettings(host: "shackpi", port: 8100)

        let route = await picker.route(privateProxy: own, privatePassword: "s3cret")

        XCTAssertEqual(route?.host, "shackpi")
        XCTAssertEqual(route?.password, "s3cret")
        XCTAssertEqual(route?.isPrivate, true)
        XCTAssertEqual(finder.callCount, 0, "nothing was needed, so nobody's machine was probed")
        XCTAssertNil(picker.lease, "a private proxy is not a lease and must not become one")
    }

    /// Whitespace is an empty field with a space in it, not a host name.
    func testAPrivateProxyOfWhitespaceCountsAsAbsent() async {
        let finder = FakeProxyFinder(candidate: .fake(host: "203.0.113.7"))
        let picker = ProxyPicker(finder: finder)

        let route = await picker.route(
            privateProxy: EchoLinkProxySettings(host: "   "), privatePassword: "")

        XCTAssertEqual(route?.host, "203.0.113.7")
    }

    /// **The lease.** A directory refresh and the connect that follows it are one
    /// sitting, and probing again would take a second stranger's machine to do
    /// one operator's work.
    func testASecondResolutionReusesTheLeaseRatherThanProbingAgain() async {
        let finder = FakeProxyFinder(candidate: .fake(host: "203.0.113.7"))
        let picker = ProxyPicker(finder: finder)

        let first = await picker.route(privateProxy: .none, privatePassword: "")
        let second = await picker.route(privateProxy: .none, privatePassword: "")

        XCTAssertEqual(first, second)
        XCTAssertEqual(finder.callCount, 1, "one sitting, one proxy, one set of probes")
    }

    /// And the other half of it: the sitting ends, the machine goes back, and the
    /// next one probes afresh rather than returning to a proxy somebody else may
    /// have taken. This is the fault APP-13 exists to fix, in miniature.
    func testReleasingTheLeaseMakesTheNextResolutionProbeAgain() async {
        let finder = FakeProxyFinder(candidate: .fake(host: "203.0.113.7"))
        let picker = ProxyPicker(finder: finder)

        _ = await picker.route(privateProxy: .none, privatePassword: "")
        picker.releaseLease()
        XCTAssertNil(picker.lease)

        _ = await picker.route(privateProxy: .none, privatePassword: "")

        XCTAssertEqual(finder.callCount, 2)
    }

    /// Releasing gives up a *borrowed* proxy. The operator's own is a setting and
    /// is not the picker's to drop.
    func testReleasingTheLeaseDoesNotTouchThePrivateProxy() async {
        let finder = FakeProxyFinder()
        let picker = ProxyPicker(finder: finder)
        let own = EchoLinkProxySettings(host: "shackpi")

        picker.releaseLease()
        let route = await picker.route(privateProxy: own, privatePassword: "s3cret")

        XCTAssertEqual(route?.host, "shackpi")
        XCTAssertEqual(finder.callCount, 0)
    }

    /// Every public proxy being busy has to stop the caller. Falling through
    /// would put the operator in front of a message about an empty field instead
    /// of the contention that actually happened.
    func testNoRouteWhenNoProxyCouldBeFound() async {
        let finder = FakeProxyFinder(error: ProxyFinderError.noneAvailable)
        let picker = ProxyPicker(finder: finder)

        let route = await picker.route(privateProxy: .none, privatePassword: "")

        XCTAssertNil(route)
        XCTAssertNotNil(picker.failure, "the reason has to be on the picker for the view to show")
    }

    /// The awaited path shares the button's search rather than starting a
    /// second one — same spinner, same probe count, and one set of probes.
    func testTheAwaitedSearchIsTheSameSearchTheSpinnerShows() async {
        let finder = FakeProxyFinder(candidate: .fake(host: "203.0.113.7"))
        finder.holdUntilReleased()
        let picker = ProxyPicker(finder: finder)

        let resolving = Task { @MainActor in
            await picker.route(privateProxy: .none, privatePassword: "")
        }

        await waitUntil("the search starts") { picker.isSearching }
        finder.release()

        let route = await resolving.value
        XCTAssertEqual(route?.host, "203.0.113.7")
        XCTAssertFalse(picker.isSearching, "the spinner comes down with the search it belongs to")
        XCTAssertEqual(picker.lease?.host, "203.0.113.7")
        XCTAssertEqual(finder.callCount, 1)
    }

    /// "Find another" is for a proxy that has gone away mid-sitting: it drops the
    /// lease first, so it probes rather than handing back the machine that is no
    /// longer answering.
    func testFindAnotherDropsTheLeaseAndProbesAgain() async {
        let finder = FakeProxyFinder(candidate: .fake(host: "203.0.113.7"))
        let picker = ProxyPicker(finder: finder)

        _ = await picker.route(privateProxy: .none, privatePassword: "")
        finder.setCandidate(.fake(host: "198.51.100.4"))

        picker.findAnother()
        await waitUntil("the second search finishes") { !picker.isSearching }

        XCTAssertEqual(picker.lease?.host, "198.51.100.4")
        XCTAssertEqual(finder.callCount, 2)
    }

    // MARK: - What the operator reads

    func testTheSummaryNamesWhoHowFarAndHowQuick() {
        let candidate = ProxyCandidate.fake(
            name: "Sydney", distanceKilometres: 464.6, latencyMilliseconds: 38)

        XCTAssertEqual(candidate.summary, "Sydney · 465 km · 38 ms")
    }

    /// A listing with no distance still has to read as a sentence.
    func testTheSummarySkipsWhatTheListingDidNotGive() {
        let candidate = ProxyCandidate.fake(
            name: "Santiago", distanceKilometres: nil, latencyMilliseconds: 210)

        XCTAssertEqual(candidate.summary, "Santiago · 210 ms")
    }

    func testEveryFailureHasWordsForTheOperator() {
        let failures: [ProxyFinderError] = [
            .noneAvailable,
            .noneAnswered(probed: 15),
            .listUnavailable(detail: "the request timed out"),
        ]

        for failure in failures {
            XCTAssertFalse(
                failure.description.isEmpty, "\(failure) needs something the operator can read")
        }
    }

    /// Singular and plural, because "Tried 1 proxies" is the kind of thing that
    /// makes an operator distrust the rest of the screen.
    func testTheProbedCountReadsAsEnglish() {
        XCTAssertTrue(ProxyFinderError.noneAnswered(probed: 1).description.contains("1 proxy"))
        XCTAssertTrue(ProxyFinderError.noneAnswered(probed: 15).description.contains("15 proxies"))
    }
}
