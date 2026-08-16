// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

@MainActor
final class ProxyPickerTests: XCTestCase {

    // MARK: - Finding one

    /// The whole point: what the finder returns reaches the caller, so the
    /// connect form can be filled in from it.
    func testASuccessfulSearchHandsTheProxyToTheCaller() async {
        let finder = FakeProxyFinder(
            candidate: .fake(name: "Sydney", host: "203.0.113.7", port: 8100))
        let picker = ProxyPicker(finder: finder)

        var applied: ProxyCandidate?
        picker.find { applied = $0 }

        await waitUntil("the search finishes") { !picker.isSearching }

        XCTAssertEqual(applied?.host, "203.0.113.7")
        XCTAssertEqual(applied?.port, 8100)
        XCTAssertEqual(picker.chosen, applied)
        XCTAssertNil(picker.failure)
    }

    func testProgressIsReportedWhileProbing() async {
        let finder = FakeProxyFinder()
        finder.setProgressSteps([5, 5])
        let picker = ProxyPicker(finder: finder)

        picker.find { _ in }
        await waitUntil("the search finishes") { !picker.isSearching }

        // Ten across two batches — the running total, not the batch size.
        await waitUntil("the probed count catches up") { picker.probedCount == 10 }
    }

    func testTheSpinnerIsUpWhileTheSearchRuns() async {
        let finder = FakeProxyFinder()
        finder.holdUntilReleased()
        let picker = ProxyPicker(finder: finder)

        picker.find { _ in }
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

        picker.find { _ in }
        await waitUntil("the search finishes") { !picker.isSearching }

        XCTAssertNotNil(picker.failure)
        XCTAssertTrue(
            picker.failure?.contains("contended") == true,
            "the operator should be told this is contention, not a fault")
        XCTAssertNil(picker.chosen)
    }

    func testAFailedSearchDoesNotApplyAnything() async {
        let finder = FakeProxyFinder(error: ProxyFinderError.noneAnswered(probed: 15))
        let picker = ProxyPicker(finder: finder)

        var applied: ProxyCandidate?
        picker.find { applied = $0 }
        await waitUntil("the search finishes") { !picker.isSearching }

        XCTAssertNil(applied, "nothing answered, so there is nothing to fill the field with")
    }

    /// A retry after a failure clears the old complaint — otherwise the second
    /// search runs under the first one's error text.
    func testRetryingClearsThePreviousFailure() async {
        let finder = FakeProxyFinder(error: ProxyFinderError.noneAvailable)
        let picker = ProxyPicker(finder: finder)

        picker.find { _ in }
        await waitUntil("the first search fails") { picker.failure != nil }

        finder.setError(nil)
        picker.find { _ in }
        await waitUntil("the second search finishes") { !picker.isSearching }

        XCTAssertNil(picker.failure)
        XCTAssertNotNil(picker.chosen)
        XCTAssertEqual(finder.callCount, 2)
    }

    // MARK: - Cancelling and superseding

    func testCancellingStopsTheSpinner() async {
        let finder = FakeProxyFinder()
        finder.holdUntilReleased()
        let picker = ProxyPicker(finder: finder)

        picker.find { _ in }
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

        picker.find { _ in }
        await waitUntil("the first search starts") { picker.isSearching }

        // Replaces the first, which is still parked.
        picker.find { _ in }
        XCTAssertTrue(picker.isSearching)

        // Let both run out. The spinner must still belong to the second.
        finder.release()
        await waitUntil("the second search finishes") { !picker.isSearching }
        XCTAssertNotNil(picker.chosen)
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

        picker.find { _ in }
        await waitUntil("the first search is in flight") { finder.callCount == 1 }

        picker.find { _ in }

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

    // MARK: - Sourcing one at the moment it is needed

    /// The point of `sourceProxyIfNeeded`: an operator who has just made an
    /// EchoLink channel and pressed Refresh or Connect gets a proxy, rather
    /// than a message naming a field they have no way to fill in well.
    func testAnEmptyProxyIsFilledInBeforeTheCallerProceeds() async {
        let finder = FakeProxyFinder(
            candidate: .fake(name: "Sydney", host: "203.0.113.7", port: 8100))
        let picker = ProxyPicker(finder: finder)
        var settings = echoLinkSettings(host: "")

        let mayProceed = await picker.sourceProxyIfNeeded(for: settings) { candidate in
            settings.host = candidate.host
            settings.port = candidate.port
        }

        XCTAssertTrue(mayProceed)
        XCTAssertEqual(settings.host, "203.0.113.7")
        XCTAssertEqual(settings.port, 8100)
    }

    /// A proxy the operator typed, or one the app already found, is theirs.
    /// Repointing it under a channel they had working would be the worse
    /// surprise, so a set field is left alone and nothing is probed at all.
    func testAProxyThatIsAlreadySetIsLeftAlone() async {
        let finder = FakeProxyFinder()
        let picker = ProxyPicker(finder: finder)
        var settings = echoLinkSettings(host: "proxy.example.org")

        let mayProceed = await picker.sourceProxyIfNeeded(for: settings) { candidate in
            settings.host = candidate.host
        }

        XCTAssertTrue(mayProceed)
        XCTAssertEqual(settings.host, "proxy.example.org")
        XCTAssertEqual(finder.callCount, 0, "nothing was needed, so nobody's machine was probed")
    }

    /// Whitespace is an empty field with a space in it, not a host name.
    func testAProxyFieldOfWhitespaceCountsAsEmpty() async {
        let finder = FakeProxyFinder(candidate: .fake(host: "203.0.113.7"))
        let picker = ProxyPicker(finder: finder)
        var settings = echoLinkSettings(host: "   ")

        _ = await picker.sourceProxyIfNeeded(for: settings) { settings.host = $0.host }

        XCTAssertEqual(settings.host, "203.0.113.7")
    }

    /// The other two modes reach their destination directly. A proxy search
    /// before an M17 connect would be a second or two of probing strangers'
    /// machines for a field that mode does not have.
    func testAModeWithoutAProxyNeverSearches() async {
        let finder = FakeProxyFinder()
        let picker = ProxyPicker(finder: finder)
        var settings = echoLinkSettings(host: "")
        settings.mode = .m17

        let mayProceed = await picker.sourceProxyIfNeeded(for: settings) { _ in
            XCTFail("an M17 channel has no proxy to fill in")
        }

        XCTAssertTrue(mayProceed)
        XCTAssertEqual(finder.callCount, 0)
    }

    /// Every public proxy being busy has to stop the caller. Falling through
    /// would put the operator in front of "enter the proxy's host name" — a
    /// field they were never meant to fill in — instead of the contention that
    /// actually happened.
    func testTheCallerIsStoppedWhenNoProxyCouldBeFound() async {
        let finder = FakeProxyFinder(error: ProxyFinderError.noneAvailable)
        let picker = ProxyPicker(finder: finder)
        var settings = echoLinkSettings(host: "")

        let mayProceed = await picker.sourceProxyIfNeeded(for: settings) { _ in
            XCTFail("nothing answered, so there is nothing to fill the field with")
        }

        XCTAssertFalse(mayProceed)
        XCTAssertEqual(settings.host, "")
        XCTAssertNotNil(picker.failure, "the reason has to be on the picker for the view to show")
    }

    /// The awaited path shares the button's search rather than starting a
    /// second one — same spinner, same probe count, and one set of probes.
    func testTheAwaitedSearchIsTheSameSearchTheSpinnerShows() async {
        let finder = FakeProxyFinder(candidate: .fake(host: "203.0.113.7"))
        finder.holdUntilReleased()
        let picker = ProxyPicker(finder: finder)
        var settings = echoLinkSettings(host: "")

        let sourcing = Task { @MainActor in
            await picker.sourceProxyIfNeeded(for: settings) { settings.host = $0.host }
        }

        await waitUntil("the search starts") { picker.isSearching }
        finder.release()

        let mayProceed = await sourcing.value
        XCTAssertTrue(mayProceed)
        XCTAssertFalse(picker.isSearching, "the spinner comes down with the search it belongs to")
        XCTAssertEqual(settings.host, "203.0.113.7")
        XCTAssertEqual(picker.chosen?.host, "203.0.113.7")
        XCTAssertEqual(finder.callCount, 1)
    }

    private func echoLinkSettings(host: String) -> NodeSettings {
        NodeSettings(
            mode: .echoLink,
            host: host,
            port: 8100,
            peer: "13.57.14.183",
            directoryServer: "192.0.2.1")
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
