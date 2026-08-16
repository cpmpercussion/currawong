// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The M17 reflector chooser.
///
/// Where the EchoLink browser exists because an address cannot be known without
/// it, this one exists because a hundred and twenty-five reflectors across
/// twenty countries cannot be remembered. The state machine is the same shape,
/// and these tests cover the places where it deliberately differs.
@MainActor
final class ReflectorBrowserTests: XCTestCase {

    // MARK: - Fetching

    func testAFetchFillsTheListAndStampsIt() async {
        let directory = FakeReflectorDirectory(reflectors: [.fake(designator: "M17-AUS")])
        let browser = ReflectorBrowser(directory: directory)

        XCTAssertFalse(browser.hasList)

        browser.load()
        await waitUntil("the list arrives") { !browser.reflectors.isEmpty }

        XCTAssertEqual(browser.reflectors.map(\.designator), ["M17-AUS"])
        XCTAssertNotNil(browser.fetchedAt)
        XCTAssertTrue(browser.hasList)
        XCTAssertNil(browser.failure)
        XCTAssertFalse(browser.isLoading)
    }

    /// The operator has to be told what went wrong in the fetch's own words —
    /// "could not be downloaded" is actionable, a blank list is not.
    func testAFailureIsReportedInItsOwnWords() async {
        let directory = FakeReflectorDirectory(
            error: FakeReflectorDirectory.ListUnreachable())
        let browser = ReflectorBrowser(directory: directory)

        browser.load()
        await waitUntil("the failure lands") { browser.failure != nil }

        XCTAssertEqual(browser.failure, "the reflector list could not be downloaded")
        XCTAssertFalse(browser.isLoading)
    }

    /// A list that is served but empty is a problem at the other end, and
    /// saying nothing would leave the operator looking at a blank pane
    /// wondering whether the fetch happened.
    func testAnEmptyListSaysSo() async {
        let browser = ReflectorBrowser(directory: FakeReflectorDirectory(reflectors: []))

        browser.load()
        await waitUntil("the fetch finishes") { browser.fetchedAt != nil }

        XCTAssertEqual(browser.failure, ReflectorDirectoryError.empty.description)
    }

    /// **The difference from the station browser.** That one must never fetch
    /// by itself, because a listing seizes a public proxy that serves one user
    /// at a time. This is a static file on a CDN, so the pane loads it on first
    /// appearance — but only once, not on every switch back to the pane.
    func testLoadIfNeededFetchesOnceAndThenLeavesItAlone() async {
        let directory = FakeReflectorDirectory(reflectors: [.fake(designator: "M17-AUS")])
        let browser = ReflectorBrowser(directory: directory)

        browser.loadIfNeeded()
        await waitUntil("the list arrives") { browser.hasList }
        XCTAssertEqual(directory.fetchCount, 1)

        browser.loadIfNeeded()
        browser.loadIfNeeded()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(directory.fetchCount, 1, "the pane reappearing must not re-download")

        // Refresh is the operator saying they want a new one, and it always
        // goes.
        browser.load()
        await waitUntil("the refresh finishes") { directory.fetchCount == 2 }
    }

    /// `loadIfNeeded` must not stack a second fetch on top of one already in
    /// flight — two panes appearing in the same frame would otherwise download
    /// the file twice.
    func testLoadIfNeededDoesNotStackOnAFetchInFlight() async {
        let directory = FakeReflectorDirectory(reflectors: [.fake(designator: "M17-AUS")])
        directory.holdUntilReleased = true
        let browser = ReflectorBrowser(directory: directory)

        browser.loadIfNeeded()
        browser.loadIfNeeded()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(directory.fetchCount, 1)

        directory.release()
        await waitUntil("the fetch finishes") { !browser.isLoading }
    }

    /// The same ordering hazard `StationBrowser` has: `load` cancels the task
    /// in flight and *then* sets `isLoading` back to true, and the cancelled
    /// task notices afterwards. Clearing the flag unconditionally would turn
    /// the new fetch's spinner off while it is still running.
    func testASupersededFetchDoesNotStopTheNewFetchesSpinner() async {
        let directory = FakeReflectorDirectory(reflectors: [.fake(designator: "M17-AUS")])
        directory.holdUntilReleased = true
        let browser = ReflectorBrowser(directory: directory)

        browser.load()
        browser.load()

        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(
            browser.isLoading,
            "the second fetch is still running, so the spinner belongs to it")

        directory.release()
        await waitUntil("the second fetch finishes") { !browser.isLoading }
        XCTAssertEqual(browser.reflectors.map(\.designator), ["M17-AUS"])
    }

    func testCancelStopsTheSpinner() async {
        let directory = FakeReflectorDirectory(reflectors: [.fake(designator: "M17-AUS")])
        directory.holdUntilReleased = true
        let browser = ReflectorBrowser(directory: directory)

        browser.load()
        await waitUntil("the fetch starts") { browser.isLoading }

        browser.cancel()
        XCTAssertFalse(browser.isLoading)
    }

    // MARK: - Filtering

    private func browserWithList() async -> ReflectorBrowser {
        let directory = FakeReflectorDirectory(reflectors: [
            .fake(designator: "M17-AUS", host: "m17-aus.example.org", sponsor: "VK3ABC",
                country: "AU"),
            .fake(designator: "M17-GBR", host: "m17-gbr.example.org", sponsor: "G0XYZ",
                country: "GB"),
            .fake(designator: "URF018", name: "REF018", host: "ref018.example.br",
                sponsor: "PY2PE", country: "BR", isMultiprotocol: true),
        ])
        let browser = ReflectorBrowser(directory: directory)
        browser.load()
        await waitUntil("the list arrives") { !browser.reflectors.isEmpty }
        return browser
    }

    func testAnEmptySearchShowsEverythingInTheListedOrder() async {
        let browser = await browserWithList()
        XCTAssertEqual(
            browser.visibleReflectors.map(\.designator), ["M17-AUS", "M17-GBR", "URF018"])
    }

    /// Searching has to match everything visible on the row. An operator
    /// looking for the Australian reflector types `AU`, and one looking for a
    /// friend's reflector types their callsign.
    func testSearchMatchesEveryFieldOnTheRow() async {
        let browser = await browserWithList()

        browser.search = "aus"
        XCTAssertEqual(browser.visibleReflectors.map(\.designator), ["M17-AUS"])

        browser.search = "GB"
        XCTAssertEqual(browser.visibleReflectors.map(\.designator), ["M17-GBR"])

        browser.search = "py2pe"
        XCTAssertEqual(browser.visibleReflectors.map(\.designator), ["URF018"])

        browser.search = "REF018"
        XCTAssertEqual(browser.visibleReflectors.map(\.designator), ["URF018"])

        browser.search = "example.br"
        XCTAssertEqual(browser.visibleReflectors.map(\.designator), ["URF018"])

        browser.search = "  "
        XCTAssertEqual(browser.visibleReflectors.count, 3, "whitespace is not a search")

        browser.search = "nothing like this"
        XCTAssertTrue(browser.visibleReflectors.isEmpty)
    }

    // MARK: - Turning a reflector into somewhere to go

    /// The module is the choice. A channel built without one would connect to a
    /// reflector and land nowhere.
    func testAChannelCarriesTheReflectorAndTheChosenModule() {
        let reflector = M17Reflector.fake(
            designator: "M17-AUS", host: "m17-aus.example.org", port: 17001)

        var template = NodeSettings(mode: .echoLink)
        template.transmitTimeout = 42

        let channel = reflector.channel(module: "C", basedOn: template)

        XCTAssertEqual(channel.mode, .m17, "whatever the template was, this is an M17 channel")
        XCTAssertEqual(channel.host, "m17-aus.example.org")
        XCTAssertEqual(channel.port, 17001)
        XCTAssertEqual(channel.module, "C")
        XCTAssertEqual(channel.name, "M17-AUS C")

        // The part the reflector cannot supply comes from the template — what
        // the operator has already configured and must not retype. The callsign
        // is no longer among these: it is app-wide now, and not a channel field
        // at all.
        XCTAssertEqual(channel.transmitTimeout, 42)

        // A new channel, not an edit of the one it was based on.
        XCTAssertNotEqual(channel.id, template.id)
    }

    /// Two modules on one reflector are two different places, and saving both
    /// must give two channels rather than one that overwrites the other.
    func testTwoModulesOnOneReflectorAreTwoChannels() {
        let reflector = M17Reflector.fake(designator: "M17-AUS")
        let template = NodeSettings(mode: .m17)

        let a = reflector.channel(module: "A", basedOn: template)
        let b = reflector.channel(module: "B", basedOn: template)

        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.name, "M17-AUS A")
        XCTAssertEqual(b.name, "M17-AUS B")
    }

    // MARK: - Words

    func testEveryFailureHasWordsForTheOperator() {
        for error: ReflectorDirectoryError in [
            .unreachable(detail: "offline"), .malformed(detail: "unexpected token"), .empty,
        ] {
            XCTAssertFalse(error.description.isEmpty, "\(error) needs something to display")
        }
    }
}
