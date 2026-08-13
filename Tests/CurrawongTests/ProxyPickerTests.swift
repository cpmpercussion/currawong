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
