// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The session pane's link button: what it says in each state, and what
/// "reconnect" actually reconnects to.
///
/// Two halves, and the second is the one that matters on air: a button labelled
/// "Reconnect to VK1RGI" must place a call to VK1RGI and not to whichever
/// channel happens to be selected by the time it is pressed.
@MainActor
final class SessionLinkControlTests: XCTestCase {
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")

    private var allStar: NodeSettings { SessionHarness.goodSettings }
    private var other: NodeSettings { SessionHarness.otherSettings }

    // MARK: - What the button says

    func testConnectedOffersDisconnect() throws {
        let control = try XCTUnwrap(
            SessionLinkControl(connection: .connected, lastConnectedName: "Repeater"))

        XCTAssertEqual(control.title, "Disconnect")
        XCTAssertTrue(control.isEnabled)
        XCTAssertTrue(control.isDestructive)
    }

    /// A connect that is going nowhere is abandonable, and this is the only
    /// control that offers it — the form's button is inert while busy.
    func testConnectingOffersCancelRatherThanDisconnect() throws {
        let control = try XCTUnwrap(
            SessionLinkControl(connection: .connecting, lastConnectedName: nil))

        XCTAssertEqual(control.title, "Cancel")
        XCTAssertTrue(control.isEnabled)
    }

    /// The one state with nothing left to ask for.
    func testDisconnectingIsShownButDisabled() throws {
        let control = try XCTUnwrap(
            SessionLinkControl(connection: .disconnecting, lastConnectedName: "Repeater"))

        XCTAssertEqual(control.title, "Disconnecting…")
        XCTAssertFalse(control.isEnabled)
    }

    /// The label names the place, because a button that keys a transmitter
    /// should not be ambiguous about which one.
    func testDisconnectedOffersReconnectNamingTheChannel() throws {
        let control = try XCTUnwrap(
            SessionLinkControl(connection: .disconnected, lastConnectedName: "VK1RGI"))

        XCTAssertEqual(control.title, "Reconnect to VK1RGI")
        XCTAssertTrue(control.isEnabled)
        XCTAssertFalse(control.isDestructive, "reconnecting is not the destructive action")
    }

    /// Before the first call there is nothing to go back to, and a dead button
    /// only invites pressing it. The connect form is where a first call starts.
    func testNothingIsShownWithNowhereToGoBackTo() {
        XCTAssertNil(SessionLinkControl(connection: .disconnected, lastConnectedName: nil))
        XCTAssertNil(SessionLinkControl(connection: .disconnected, lastConnectedName: ""))
    }

    // MARK: - What it reconnects to

    func testNoLastChannelUntilACallIsAnswered() async {
        let harness = SessionHarness()
        XCTAssertNil(harness.session.lastConnectedChannel)

        harness.session.settings = allStar
        await harness.session.connect()

        XCTAssertEqual(harness.session.lastConnectedChannel?.id, allStar.id)
    }

    /// Reconnect must not offer to return to somewhere that refused us — the
    /// button would then mean "retry the thing that failed", which is a
    /// different offer and one the form is better placed to make.
    func testAFailedConnectLeavesNoLastChannel() async {
        let harness = SessionHarness()
        harness.session.settings = allStar
        harness.client.connectError = SessionHarness.ConnectFailed()

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertNil(harness.session.lastConnectedChannel)
    }

    func testDisconnectingKeepsTheLastChannelSoItCanBeReturnedTo() async {
        let harness = SessionHarness()
        harness.session.settings = allStar
        await harness.session.connect()

        await harness.session.disconnect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.lastConnectedChannel?.id, allStar.id)
    }

    /// The whole point of storing the channel rather than trusting the draft:
    /// selecting another channel while disconnected is allowed, and Reconnect
    /// still means the place the operator was just talking to.
    func testReconnectingReturnsToTheLastChannelAfterAnotherWasSelected() async {
        let harness = SessionHarness(
            settings: nil,
            channels: [allStar, other],
            selectedID: allStar.id,
            secrets: [allStar.secretAccount(for: vk1xyz): "hunter2"])
        await harness.session.connect()
        await harness.session.disconnect()

        harness.session.select(other.id)
        XCTAssertEqual(harness.session.settings.id, other.id, "precondition")

        XCTAssertTrue(harness.session.restoreLastConnectedChannel())

        XCTAssertEqual(harness.session.settings.id, allStar.id)
        XCTAssertEqual(
            harness.session.channels.selectedID, allStar.id,
            "the list's selection follows the draft, or the two disagree on screen")
        XCTAssertEqual(harness.session.secret, "hunter2", "and its secret comes back with it")
    }

    /// A channel deleted after the call can still be reconnected to: an unsaved
    /// draft is a supported state, and refusing the call because a list entry
    /// went away would be a worse answer than placing it.
    func testReconnectingWorksAfterTheChannelWasDeleted() async {
        let harness = SessionHarness(
            settings: nil,
            channels: [allStar, other],
            selectedID: allStar.id,
            secrets: [allStar.secretAccount(for: vk1xyz): "hunter2"])
        await harness.session.connect()
        await harness.session.disconnect()

        harness.session.select(other.id)
        harness.session.deleteChannel(allStar.id)

        XCTAssertTrue(harness.session.restoreLastConnectedChannel())

        XCTAssertEqual(harness.session.settings.id, allStar.id)
        XCTAssertEqual(harness.session.secret, "hunter2")
        XCTAssertFalse(harness.session.channels.channels.contains { $0.id == allStar.id })
    }

    func testRestoringIsRefusedWithNoLastChannelAndWhileALinkIsUp() async {
        let harness = SessionHarness()
        XCTAssertFalse(
            harness.session.restoreLastConnectedChannel(), "nowhere to go back to yet")

        harness.session.settings = allStar
        await harness.session.connect()

        XCTAssertFalse(
            harness.session.restoreLastConnectedChannel(),
            "changing the draft under a live link is what `select(_:)` refuses too")
    }

    /// And the round trip: restore, connect, and the call goes to the channel on
    /// the label rather than to the one that was selected.
    func testReconnectPlacesTheCallToTheChannelOnTheLabel() async {
        let harness = SessionHarness(
            settings: nil,
            channels: [allStar, other],
            selectedID: allStar.id,
            secrets: [allStar.secretAccount(for: vk1xyz): "hunter2"])
        await harness.session.connect()
        await harness.session.disconnect()
        harness.session.select(other.id)

        harness.session.restoreLastConnectedChannel()
        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.session.settings.id, allStar.id)
        XCTAssertEqual(harness.settingsSeen.last?.host, allStar.host)
    }
}
