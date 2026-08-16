// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The EchoLink station browser (EL-11).
///
/// The browser exists because **nothing in the library resolves a callsign to
/// an address** — the proxy carries four raw octets — so the only way an
/// operator gets a node's address is by looking it up. These tests cover the
/// state machine around that lookup: what it refuses to attempt, what it does
/// with an answer, and how six thousand rows are made findable.
///
/// ``FakeStationDirectory`` stands in for the real fetch, which would open a
/// proxy session and log in to a directory server.
@MainActor
final class StationBrowserTests: XCTestCase {

    private func echoLinkSettings() -> NodeSettings {
        NodeSettings(
            mode: .echoLink,
            host: "proxy.example.org",
            port: 8100,
            peer: "13.57.14.183",
            directoryServer: "192.0.2.1")
    }

    /// The operator, which is app-wide now rather than a field of the channel.
    private let identity = OperatorIdentity(callsign: "VK1XYZ")

    // MARK: - What is missing

    /// Checked in the app rather than left to the library so the operator is
    /// told *which field* is empty, instead of watching a spinner end in a
    /// protocol error that names none of them.
    func testWhatIsMissingNamesTheFieldTheOperatorHasToFill() {
        let good = echoLinkSettings()
        XCTAssertNil(StationBrowser.whatIsMissing(in: good, identity: identity, accountPassword: "pw"))

        var notEchoLink = good
        notEchoLink.mode = .allStarLink
        XCTAssertEqual(
            StationBrowser.whatIsMissing(in: notEchoLink, identity: identity, accountPassword: "pw"), .notEchoLink)

        var noProxy = good
        noProxy.host = "   "
        XCTAssertEqual(
            StationBrowser.whatIsMissing(in: noProxy, identity: identity, accountPassword: "pw"), .missingProxy)

        var noDirectory = good
        noDirectory.directoryServer = " "
        XCTAssertEqual(
            StationBrowser.whatIsMissing(in: noDirectory, identity: identity, accountPassword: "pw"),
            .missingDirectoryServer)

        // The account password is the one that is genuinely secret, and the
        // directory server will not list stations for an account it has not
        // authenticated — so an anonymous browse is not a thing that exists.
        XCTAssertEqual(
            StationBrowser.whatIsMissing(in: good, identity: identity, accountPassword: ""),
            .missingAccountPassword)
    }

    /// The complaint has to be the *first* thing wrong, in the order the
    /// operator would fill the form in — telling somebody with an empty form
    /// about the last field would be unhelpful.
    func testTheFirstMissingFieldIsTheOneReported() {
        var empty = echoLinkSettings()
        empty.host = ""
        empty.directoryServer = ""

        XCTAssertEqual(StationBrowser.whatIsMissing(in: empty, identity: identity, accountPassword: ""), .missingProxy)
    }

    func testEveryComplaintHasWordsForTheOperator() {
        for error in [
            StationDirectoryError.notEchoLink, .missingProxy, .missingDirectoryServer,
            .missingAccountPassword,
        ] {
            XCTAssertFalse(error.description.isEmpty, "\(error) needs something to display")
        }
    }

    /// A fetch that cannot work is not attempted: the browser complains without
    /// opening a proxy session. Public proxies are single-user, so a pointless
    /// session is one nobody else can use.
    func testAnIncompleteChannelIsRefusedWithoutTouchingTheDirectory() async {
        let directory = FakeStationDirectory(stations: [.fake(callsign: "*ECHOTEST*")])
        let browser = StationBrowser(directory: directory)
        var settings = echoLinkSettings()
        settings.directoryServer = ""

        browser.load(for: settings, identity: identity, accountPassword: "pw")

        XCTAssertTrue(directory.fetches.isEmpty, "nothing should have been fetched")
        XCTAssertFalse(browser.isLoading)
        XCTAssertEqual(browser.failure, StationDirectoryError.missingDirectoryServer.description)
        XCTAssertTrue(browser.stations.isEmpty)
    }

    // MARK: - Loading

    func testASuccessfulLoadPopulatesTheStationsAndSaysWhenItWasFetched() async {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FakeStationDirectory(stations: [
            .fake(callsign: "VK1ABC", location: "Canberra", nodeNumber: 12345),
            .fake(callsign: "VK2DEF", location: "Sydney", nodeNumber: 23456),
        ])
        let browser = StationBrowser(directory: directory, now: { fetchedAt })

        browser.load(for: echoLinkSettings(), identity: identity, accountPassword: "pw")
        await waitUntil("the listing arrives") { !browser.stations.isEmpty }

        XCTAssertEqual(browser.stations.map(\.callsign), ["VK1ABC", "VK2DEF"])
        // A listing goes stale — stations come and go, addresses change — so
        // the browser records when it was taken rather than presenting
        // yesterday's list as fact.
        XCTAssertEqual(browser.fetchedAt, fetchedAt)
        XCTAssertNil(browser.failure)
        await waitUntil("the spinner stops") { !browser.isLoading }

        // The operator's own settings went to the directory, not something the
        // browser invented.
        XCTAssertEqual(directory.fetches.count, 1)
        XCTAssertEqual(directory.fetches.first?.accountPassword, "pw")
        XCTAssertEqual(directory.fetches.first?.settings.host, "proxy.example.org")
    }

    /// A failed fetch has to stop the spinner as well as explain itself.
    /// An operator staring at a spinner that never stops has no way to tell a
    /// slow directory from a broken one.
    func testAThrowingDirectorySetsTheFailureAndStopsLoading() async {
        let directory = FakeStationDirectory(
            error: FakeStationDirectory.DirectoryUnreachable())
        let browser = StationBrowser(directory: directory)

        browser.load(for: echoLinkSettings(), identity: identity, accountPassword: "pw")
        await waitUntil("the failure is reported") { browser.failure != nil }

        XCTAssertEqual(browser.failure, "the directory server did not answer")
        await waitUntil("the spinner stops") { !browser.isLoading }
        XCTAssertTrue(browser.stations.isEmpty)
        XCTAssertNil(browser.fetchedAt, "nothing was fetched, so there is no timestamp")
    }

    /// An empty listing is not an error, but it is not success either: the
    /// operator needs to be told, or an empty list looks like a still-loading
    /// one.
    func testAnEmptyListingIsReportedRatherThanShownAsNothing() async {
        let browser = StationBrowser(directory: FakeStationDirectory(stations: []))

        browser.load(for: echoLinkSettings(), identity: identity, accountPassword: "pw")
        await waitUntil("the empty listing is reported") { browser.failure != nil }

        XCTAssertEqual(browser.failure, "The directory server listed no stations.")
    }

    /// A second fetch replaces the first — the operator changed something and
    /// wants the new answer, not both answers interleaved.
    func testASecondLoadClearsThePreviousFailure() async {
        let directory = FakeStationDirectory(
            stations: [.fake(callsign: "VK1ABC")],
            error: FakeStationDirectory.DirectoryUnreachable())
        let browser = StationBrowser(directory: directory)

        browser.load(for: echoLinkSettings(), identity: identity, accountPassword: "pw")
        await waitUntil("the first fetch fails") { browser.failure != nil }

        directory.error = nil
        browser.load(for: echoLinkSettings(), identity: identity, accountPassword: "pw")
        await waitUntil("the second fetch succeeds") { !browser.stations.isEmpty }

        XCTAssertNil(browser.failure)
    }

    func testCancellingStopsTheSpinner() async {
        let browser = StationBrowser(directory: FakeStationDirectory(stations: []))

        browser.load(for: echoLinkSettings(), identity: identity, accountPassword: "pw")
        browser.cancel()

        XCTAssertFalse(browser.isLoading)
    }

    /// A superseded fetch must not stop the spinner belonging to the fetch that
    /// replaced it.
    ///
    /// The ordering this pins is the awkward one: `load` cancels the task in
    /// flight and *then* sets `isLoading` back to true, and the cancelled task
    /// only notices afterwards. Clearing the flag unconditionally on the way
    /// out of a cancelled fetch therefore turns the new fetch's spinner off
    /// while it is still running, which reads as "finished, and found nothing".
    func testASupersededFetchDoesNotStopTheNewFetchesSpinner() async {
        let directory = FakeStationDirectory(stations: [.fake(callsign: "VK1ABC")])
        directory.holdUntilReleased = true
        let browser = StationBrowser(directory: directory)

        browser.load(for: echoLinkSettings(), identity: identity, accountPassword: "pw")
        browser.load(for: echoLinkSettings(), identity: identity, accountPassword: "pw")

        // Let the cancelled first task run to its exit.
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(
            browser.isLoading,
            "the second fetch is still running, so the spinner belongs to it")

        directory.release()
        await waitUntil("the second fetch finishes") { !browser.isLoading }
        XCTAssertEqual(browser.stations.map(\.callsign), ["VK1ABC"])
    }

    // MARK: - Filtering and ordering

    private func browserWithListing() async -> StationBrowser {
        let directory = FakeStationDirectory(stations: [
            .fake(callsign: "VK1ABC", location: "Canberra ACT", nodeNumber: 12345),
            .fake(callsign: "VK2DEF", location: "Sydney NSW", nodeNumber: 98765),
            .fake(callsign: "*ECHOTEST*", location: "Conference", nodeNumber: 9999),
            .fake(callsign: "ZL1GHI", location: "Auckland", nodeNumber: 34512),
        ])
        let browser = StationBrowser(directory: directory)
        browser.load(for: echoLinkSettings(), identity: identity, accountPassword: "pw")
        await waitUntil("the listing arrives") { !browser.stations.isEmpty }
        return browser
    }

    /// **The test services come first.** `*ECHOTEST*` echoes audio back, so one
    /// operator alone can prove the whole path works without troubling anybody
    /// — worth surfacing at the top of six thousand rows rather than leaving
    /// somebody to scroll for it.
    func testTestServicesAreListedFirst() async {
        let browser = await self.browserWithListing()

        XCTAssertEqual(browser.visibleStations.first?.callsign, "*ECHOTEST*")
        // A stable partition, not a sort: everything else keeps the directory's
        // own order, because re-ordering six thousand rows on every keystroke
        // is felt.
        XCTAssertEqual(
            browser.visibleStations.map(\.callsign),
            ["*ECHOTEST*", "VK1ABC", "VK2DEF", "ZL1GHI"])
    }

    func testAStationKnowsWhetherItIsATestService() {
        XCTAssertTrue(DirectoryStation.fake(callsign: "*ECHOTEST*").isTestService)
        XCTAssertTrue(DirectoryStation.fake(callsign: "*echotest*").isTestService)
        XCTAssertFalse(
            DirectoryStation.fake(callsign: "VK1TEST").isTestService,
            "an ordinary callsign containing TEST is somebody's station, not a service")
        XCTAssertFalse(DirectoryStation.fake(callsign: "*CQ*").isTestService)
    }

    func testSearchingMatchesTheCallsign() async {
        let browser = await self.browserWithListing()

        browser.search = "vk1"

        XCTAssertEqual(browser.visibleStations.map(\.callsign), ["VK1ABC"])
    }

    /// Searching by place is how an operator finds a node they have heard of
    /// but cannot spell, which is most of them.
    func testSearchingMatchesTheLocation() async {
        let browser = await self.browserWithListing()

        browser.search = " sydney "

        XCTAssertEqual(browser.visibleStations.map(\.callsign), ["VK2DEF"])
    }

    /// Node numbers are matched as substrings, because that is how a partly
    /// remembered number gets typed.
    func testSearchingMatchesTheNodeNumber() async {
        let browser = await self.browserWithListing()

        browser.search = "345"

        XCTAssertEqual(browser.visibleStations.map(\.callsign), ["VK1ABC", "ZL1GHI"])
    }

    /// A search that matches a test service still puts it first; a search that
    /// does not still filters it out.
    func testSearchingAndTheTestServiceOrderingApplyTogether() async {
        let browser = await self.browserWithListing()

        browser.search = "e"
        XCTAssertEqual(browser.visibleStations.first?.callsign, "*ECHOTEST*")

        browser.search = "zl"
        XCTAssertEqual(browser.visibleStations.map(\.callsign), ["ZL1GHI"])
    }

    func testAnEmptySearchShowsEverything() async {
        let browser = await self.browserWithListing()

        browser.search = "   "

        XCTAssertEqual(browser.visibleStations.count, 4)
    }

    // MARK: - Turning a station into a channel

    /// A station supplies the address and the callsign; the parts it cannot
    /// know — which proxy, which directory server, who *we* are — come from the
    /// channel the operator already configured, so nothing is typed twice.
    func testAStationBecomesAChannelWithoutLosingTheOperatorsOwnSettings() {
        let template = echoLinkSettings()
        let station = DirectoryStation.fake(
            callsign: "*ECHOTEST*", location: "Conference", address: "13.57.14.183")

        let channel = station.channel(basedOn: template)

        XCTAssertEqual(channel.mode, .echoLink)
        XCTAssertEqual(channel.name, "*ECHOTEST*")
        XCTAssertEqual(channel.node, "*ECHOTEST*")
        XCTAssertEqual(channel.peer, "13.57.14.183")
        XCTAssertEqual(channel.host, template.host, "the proxy is the operator's")
        XCTAssertEqual(channel.directoryServer, template.directoryServer)
        // A new channel, not the template edited — otherwise picking a station
        // from the browser would silently re-point the channel it was launched
        // from.
        XCTAssertNotEqual(channel.id, template.id)
    }

    /// And it validates, which is the point: a channel built from the browser
    /// must be connectable without further typing.
    func testAChannelBuiltFromAStationValidates() throws {
        let channel = DirectoryStation
            .fake(callsign: "*ECHOTEST*", address: "13.57.14.183")
            .channel(basedOn: echoLinkSettings())

        XCTAssertEqual(try channel.validated().peer, "13.57.14.183")
    }

    // MARK: - Which listings can become a channel

    func testAStationWithARealAddressIsDialable() {
        XCTAssertTrue(DirectoryStation.fake(callsign: "VK1RBM", address: "203.0.113.9")
            .hasDialableAddress)
    }

    /// The two addresses a listing uses for "registered, but not reachable".
    /// Both are four valid octets, so `validated()` accepts them and the failure
    /// would otherwise surface inside the proxy long after the save.
    func testTheNowhereAddressesAreNotDialable() {
        for address in ["0.0.0.0", "127.0.0.1"] {
            XCTAssertFalse(
                DirectoryStation.fake(callsign: "VK1XYZ", address: address).hasDialableAddress,
                "\(address) is not somewhere the proxy can be asked to open")
        }
    }

    func testAnEmptyOrMalformedAddressIsNotDialable() {
        for address in ["", "not-an-address", "203.0.113", "203.0.113.999"] {
            XCTAssertFalse(
                DirectoryStation.fake(callsign: "VK1XYZ", address: address).hasDialableAddress,
                "\(address) is not four octets")
        }
    }

    /// The case that rules out using the library's `isConnectable` for this:
    /// a conference is listed without a node number, which makes `isConnectable`
    /// false, and `*ECHOTEST*` is the first station an operator wants. Saving it
    /// has to stay possible.
    func testAConferenceWithNoNodeNumberIsStillDialable() {
        let echotest = DirectoryStation.fake(
            callsign: "*ECHOTEST*",
            nodeNumber: nil,
            address: "13.57.14.183",
            isConnectable: false)

        XCTAssertFalse(echotest.isConnectable, "the listing carries no node number")
        XCTAssertTrue(echotest.hasDialableAddress, "but it has an address, which is all a channel needs")
    }

    /// A busy station is dialable — `BUSY` is a fact about right now, not about
    /// whether the entry can become a channel worth keeping.
    func testABusyStationIsStillDialable() {
        XCTAssertTrue(
            DirectoryStation
                .fake(callsign: "VK1RBM", address: "203.0.113.9", status: "BUSY")
                .hasDialableAddress)
    }
}
